import AppKit
import Foundation
import EliseVoiceCore
import OSLog

enum DictationState: Equatable {
    case preparing
    case ready
    case recording(elapsedSeconds: Int)
    case transcribing
    case failed(String)
}

@MainActor
final class DictationCoordinator {
    static let automaticSilenceStop = DictationPolicy.automaticSilenceStop
    static let voiceWakePreferenceKey = "voiceWakeEnabled"

    private let logger = Logger(subsystem: "com.elisevoice.app", category: "lifecycle")
    private let audioCapture: AudioCaptureService
    private var transcriptionService: TranscriptionService
    private let wakeWordDetector: WakeWordDetector
    private let personalWakeWordVerifier: PersonalWakeWordVerifier
    private let onStateChange: (DictationState) -> Void
    private let onAudioLevelChange: (Float, TimeInterval?) -> Void

    private var modelIsReady = false
    private var wakeWordIsReady = false
    private var personalWakeVerifierIsReady = false
    private var systemAllowsAudio = true
    private var recordingMonitor: Task<Void, Never>?
    private var accessibilityMonitor: Task<Void, Never>?
    private var audioHealthMonitor: Task<Void, Never>?
    private var audioRecovery: Task<Void, Never>?
    private var failureRecovery: Task<Void, Never>?
    private var transcriptionWatchdog: Task<Void, Never>?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var isStartingRecording = false
    private var isVerifyingWakeWord = false
    private var wakeVerificationGeneration: UInt64 = 0
    private var insertionTarget: TextInsertionTarget?
    private var transcriptionGeneration: UInt64 = 0
    private var lastReportedDroppedBuffers: UInt64 = 0
    private var consecutiveAudioRecoveryFailures = 0

    private(set) var voiceWakeEnabled: Bool
    private(set) var state: DictationState = .preparing {
        didSet { onStateChange(state) }
    }

    init(
        audioCapture: AudioCaptureService = AudioCaptureService(),
        transcriptionService: TranscriptionService = TranscriptionService(),
        wakeWordDetector: WakeWordDetector = WakeWordDetector(),
        personalWakeWordVerifier: PersonalWakeWordVerifier = PersonalWakeWordVerifier(),
        onStateChange: @escaping (DictationState) -> Void,
        onAudioLevelChange: @escaping (Float, TimeInterval?) -> Void
    ) {
        self.audioCapture = audioCapture
        self.transcriptionService = transcriptionService
        self.wakeWordDetector = wakeWordDetector
        self.personalWakeWordVerifier = personalWakeWordVerifier
        self.onStateChange = onStateChange
        self.onAudioLevelChange = onAudioLevelChange

        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.voiceWakePreferenceKey) == nil {
            defaults.set(true, forKey: Self.voiceWakePreferenceKey)
        }
        voiceWakeEnabled = defaults.bool(forKey: Self.voiceWakePreferenceKey)

        audioCapture.configurationChangeHandler = { [weak self] in
            Task { @MainActor in
                self?.scheduleAudioRecovery(reason: "hardware configuration")
            }
        }
        installLifecycleObservers()
        startAudioHealthMonitor()
        startMemoryPressureMonitor()
    }

    func prepare() async {
        failureRecovery?.cancel()
        failureRecovery = nil
        state = .preparing
        stopMicrophone()

        guard await audioCapture.requestPermission() else {
            state = .failed("Włącz Elise Voice w Prywatność i ochrona → Mikrofon")
            return
        }

        let accessibilityIsReady = TextInserter.requestAccessibilityPermission()

        do {
            try ModelStorage.removeLegacyWakeWordModels()
            try await transcriptionService.prepare()
            modelIsReady = true
            try wakeWordDetector.prepare { [weak self] in
                Task { @MainActor in
                    await self?.handleWakeWordDetection()
                }
            }
            wakeWordIsReady = true
            do {
                personalWakeVerifierIsReady = try await personalWakeWordVerifier.prepare()
            } catch {
                personalWakeVerifierIsReady = false
                logger.error(
                    "Personal wake verifier unavailable; using generic verifier: \(error.localizedDescription, privacy: .public)"
                )
            }

            if accessibilityIsReady {
                state = .ready
                reconcileMicrophone()
            } else {
                state = .failed("Włącz Elise Voice w Prywatność i ochrona → Dostępność")
                startAccessibilityMonitor()
            }
        } catch {
            logger.error("Preparation failed: \(error.localizedDescription, privacy: .public)")
            state = .failed("Nie udało się przygotować modelu: \(error.localizedDescription)")
        }
    }

    func setVoiceWakeEnabled(_ enabled: Bool) {
        guard voiceWakeEnabled != enabled else { return }
        wakeVerificationGeneration &+= 1
        isVerifyingWakeWord = false
        voiceWakeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.voiceWakePreferenceKey)
        logger.info("Voice wake changed: \(enabled)")
        reconcileMicrophone()
    }

    func toggleDictation() async {
        failureRecovery?.cancel()
        failureRecovery = nil
        switch state {
        case .ready:
            wakeVerificationGeneration &+= 1
            isVerifyingWakeWord = false
            await startRecordingIfAuthorized()
        case .failed:
            if modelIsReady, wakeWordIsReady {
                await startRecordingIfAuthorized()
            } else {
                await prepare()
            }
        case .recording:
            await stopAndTranscribe()
        case .preparing, .transcribing:
            break
        }
    }

    func cancel() {
        recordingMonitor?.cancel()
        recordingMonitor = nil
        accessibilityMonitor?.cancel()
        accessibilityMonitor = nil
        audioHealthMonitor?.cancel()
        audioHealthMonitor = nil
        audioRecovery?.cancel()
        audioRecovery = nil
        failureRecovery?.cancel()
        failureRecovery = nil
        transcriptionWatchdog?.cancel()
        transcriptionWatchdog = nil
        transcriptionGeneration &+= 1
        wakeVerificationGeneration &+= 1
        isVerifyingWakeWord = false
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        lifecycleObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        lifecycleObservers.removeAll()
        insertionTarget = nil
        audioCapture.cancelDictation()
        stopMicrophone()
    }

    private func handleWakeWordDetection() async {
        guard voiceWakeEnabled, state == .ready,
              !isStartingRecording, !isVerifyingWakeWord else { return }

        isVerifyingWakeWord = true
        wakeVerificationGeneration &+= 1
        let generation = wakeVerificationGeneration
        audioCapture.setWakeWordAnalysisEnabled(false)

        // Capture the end of the spoken name before taking the rolling snapshot.
        try? await Task.sleep(for: .milliseconds(420))
        guard generation == wakeVerificationGeneration,
              isVerifyingWakeWord, voiceWakeEnabled,
              systemAllowsAudio, state == .ready else { return }

        do {
            if !modelIsReady {
                try await transcriptionService.prepare()
                modelIsReady = true
            }
            let samples = audioCapture.recentMonitoringAudio(duration: 2.4)
            let personalizedAccepted = personalWakeVerifierIsReady
                ? try await personalWakeWordVerifier.verify(samples: samples)
                : false
            let accepted: Bool
            if personalizedAccepted {
                accepted = true
            } else {
                accepted = try await transcriptionService.verifyWakeWord(samples: samples)
            }
            guard generation == wakeVerificationGeneration,
                  isVerifyingWakeWord, voiceWakeEnabled,
                  systemAllowsAudio, state == .ready else { return }
            isVerifyingWakeWord = false

            if accepted {
                await startRecordingIfAuthorized()
            } else {
                logger.notice("Wake-word candidate rejected by second-stage verifier")
                audioCapture.setWakeWordAnalysisEnabled(true)
            }
        } catch {
            guard generation == wakeVerificationGeneration else { return }
            isVerifyingWakeWord = false
            logger.error(
                "Wake-word verification failed safely: \(error.localizedDescription, privacy: .public)"
            )
            audioCapture.setWakeWordAnalysisEnabled(true)
        }
    }

    private func startRecordingIfAuthorized() async {
        guard !isStartingRecording else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }

        guard TextInserter.isAuthorized else {
            _ = TextInserter.requestAccessibilityPermission()
            state = .failed("Włącz Elise Voice w Prywatność i ochrona → Dostępność")
            startAccessibilityMonitor()
            return
        }

        accessibilityMonitor?.cancel()
        accessibilityMonitor = nil

        do {
            if !modelIsReady {
                state = .preparing
                try await transcriptionService.prepare()
                modelIsReady = true
            }
            insertionTarget = try TextInserter.captureTarget()
            let microphoneWasAlreadyRunning = audioCapture.isMonitoring
            try ensureMicrophoneRunning(includeWakeWord: voiceWakeEnabled)
            audioCapture.setWakeWordAnalysisEnabled(false)

            if !microphoneWasAlreadyRunning {
                // Give the input stream a few quiet buffers to establish its
                // ambient floor before the speaker plays the ready cue.
                try? await Task.sleep(for: .milliseconds(240))
            }

            // Recording starts after the cue. The user can speak immediately
            // when the short confirmation sound ends.
            await ReadyCuePlayer.play()
            try audioCapture.beginDictation()
            state = .recording(elapsedSeconds: 0)
            startRecordingMonitor()
        } catch {
            insertionTarget = nil
            presentRecoverableFailure(error.localizedDescription)
        }
    }

    private func stopAndTranscribe(
        cancelMonitor: Bool = true,
        trimTrailingSilence: Bool = false
    ) async {
        if cancelMonitor { recordingMonitor?.cancel() }
        recordingMonitor = nil

        let capture: CapturedDictation
        do {
            capture = try audioCapture.finishDictation(
                trimmingTrailingSilence: trimTrailingSilence
            )
        } catch AudioCaptureError.recordingTooShort {
            insertionTarget = nil
            onAudioLevelChange(0, nil)
            state = .ready
            reconcileMicrophone()
            return
        } catch {
            insertionTarget = nil
            stopMicrophone()
            presentRecoverableFailure(error.localizedDescription)
            return
        }

        stopMicrophone()
        onAudioLevelChange(0, nil)
        guard capture.containsSpeech else {
            insertionTarget = nil
            state = .ready
            reconcileMicrophone()
            return
        }
        state = .transcribing
        transcriptionGeneration &+= 1
        let generation = transcriptionGeneration
        startTranscriptionWatchdog(
            generation: generation,
            audioDuration: Double(capture.samples.count) / Double(AudioCaptureService.sampleRate)
        )

        var transcript: String?
        do {
            let text = try await transcribeWithSingleRecovery(
                samples: capture.samples,
                generation: generation
            )
            guard transcriptionGeneration == generation else { return }
            transcriptionWatchdog?.cancel()
            transcriptionWatchdog = nil
            transcript = text
            guard TranscriptFormatter.isMeaningful(text) else {
                insertionTarget = nil
                state = .ready
                reconcileMicrophone()
                return
            }
            guard let target = insertionTarget else {
                throw TextInserterError.noFocusedTextField
            }
            try await TextInserter.paste(text, into: target)
            insertionTarget = nil
            state = .ready
            reconcileMicrophone()
        } catch {
            guard transcriptionGeneration == generation else { return }
            transcriptionWatchdog?.cancel()
            transcriptionWatchdog = nil
            if let transcript {
                try? TextInserter.copyPermanentlyToClipboard(transcript)
            }
            insertionTarget = nil
            presentRecoverableFailure(error.localizedDescription)
        }
    }

    private func startRecordingMonitor() {
        recordingMonitor?.cancel()
        recordingMonitor = Task { @MainActor [weak self] in
            var lastRenderedSecond = -1
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self else { return }

                if !audioCapture.isMonitoring {
                    do {
                        try ensureMicrophoneRunning(includeWakeWord: false)
                    } catch {
                        recordingMonitor = nil
                        await stopAndTranscribe(cancelMonitor: false)
                        return
                    }
                }

                let metrics = audioCapture.recordingMetrics()
                let elapsedSecond = Int(metrics.duration)
                if elapsedSecond != lastRenderedSecond {
                    lastRenderedSecond = elapsedSecond
                    state = .recording(elapsedSeconds: elapsedSecond)
                }

                let remainingSilence = max(
                    Self.automaticSilenceStop - metrics.silenceDuration,
                    0
                )
                onAudioLevelChange(metrics.level, remainingSilence)

                if DictationPolicy.reachedMaximumDuration(metrics.duration) {
                    logger.notice("Maximum recording duration reached")
                    recordingMonitor = nil
                    await stopAndTranscribe(cancelMonitor: false)
                    return
                }
                if DictationPolicy.shouldStop(afterSilence: metrics.silenceDuration) {
                    recordingMonitor = nil
                    await stopAndTranscribe(
                        cancelMonitor: false,
                        trimTrailingSilence: true
                    )
                    return
                }
            }
        }
    }

    private func ensureMicrophoneRunning(includeWakeWord: Bool) throws {
        let desiredDetector = includeWakeWord ? wakeWordDetector : nil
        if audioCapture.isMonitoring,
           audioCapture.hasWakeWordDetectorAttached != includeWakeWord {
            audioCapture.stopMonitoring()
        }
        if !audioCapture.isMonitoring {
            try audioCapture.startMonitoring(wakeWordDetector: desiredDetector)
        }
        consecutiveAudioRecoveryFailures = 0
        audioCapture.setWakeWordAnalysisEnabled(
            includeWakeWord && state == .ready && !isVerifyingWakeWord
        )
    }

    private func reconcileMicrophone() {
        let isReady = state == .ready
        let isRecording: Bool
        if case .recording = state { isRecording = true } else { isRecording = false }
        let activity = MicrophoneLifecyclePolicy.desiredActivity(
            systemAllowsAudio: systemAllowsAudio,
            appIsReady: isReady,
            appIsRecording: isRecording,
            voiceWakeEnabled: voiceWakeEnabled
        )

        guard activity != .inactive else {
            stopMicrophone()
            return
        }
        do {
            try ensureMicrophoneRunning(includeWakeWord: activity == .wakeWord)
        } catch {
            logger.error("Microphone reconciliation failed: \(error.localizedDescription, privacy: .public)")
            consecutiveAudioRecoveryFailures += 1
            let delay = MicrophoneLifecyclePolicy.recoveryDelay(
                afterFailureCount: consecutiveAudioRecoveryFailures
            )
            presentRecoverableFailure(error.localizedDescription, delay: delay)
        }
    }

    private func stopMicrophone() {
        audioCapture.stopMonitoring()
    }

    private func scheduleAudioRecovery(reason: String) {
        audioRecovery?.cancel()
        audioRecovery = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            logger.notice("Recovering audio stream after \(reason, privacy: .public)")
            stopMicrophone()
            reconcileMicrophone()
        }
    }

    private func startAudioHealthMonitor() {
        guard audioHealthMonitor == nil else { return }
        audioHealthMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                guard audioCapture.isMonitoring else { continue }
                let droppedBuffers = audioCapture.droppedBufferCount()
                if droppedBuffers > lastReportedDroppedBuffers {
                    let delta = droppedBuffers - lastReportedDroppedBuffers
                    lastReportedDroppedBuffers = droppedBuffers
                    logger.notice("Dropped audio buffers: \(delta, privacy: .public)")
                    PerformanceDiagnostics.signposter.emitEvent(
                        "Dropped audio buffers",
                        "count=\(delta, privacy: .public)"
                    )
                }
                if !audioCapture.isStreamHealthy() {
                    scheduleAudioRecovery(reason: "heartbeat timeout")
                }
            }
        }
    }

    private func startMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: .critical,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state == .ready else { return }
                self.modelIsReady = false
                Task {
                    await self.transcriptionService.releaseModelForMemoryPressure()
                }
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private func installLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let suspendNames: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification
        ]
        for name in suspendNames {
            lifecycleObservers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspendForSystem() }
            })
        }

        let resumeNames: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]
        for name in resumeNames {
            lifecycleObservers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeAfterSystem() }
            })
        }
    }

    private func suspendForSystem() {
        systemAllowsAudio = false
        wakeVerificationGeneration &+= 1
        isVerifyingWakeWord = false
        audioRecovery?.cancel()
        audioRecovery = nil
        if case .recording = state {
            recordingMonitor?.cancel()
            recordingMonitor = nil
            audioCapture.cancelDictation()
            insertionTarget = nil
            onAudioLevelChange(0, nil)
            state = .ready
        }
        stopMicrophone()
    }

    private func resumeAfterSystem() {
        systemAllowsAudio = true
        scheduleAudioRecovery(reason: "system resume")
    }

    private func startAccessibilityMonitor() {
        guard accessibilityMonitor == nil else { return }
        accessibilityMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }

                if TextInserter.isAuthorized {
                    accessibilityMonitor = nil
                    if modelIsReady, wakeWordIsReady {
                        state = .ready
                        reconcileMicrophone()
                    }
                    return
                }
            }
        }
    }

    private func transcribeWithSingleRecovery(
        samples: [Float],
        generation: UInt64
    ) async throws -> String {
        do {
            return try await transcriptionService.transcribe(samples: samples)
        } catch {
            guard transcriptionGeneration == generation else {
                throw TranscriptionError.cancelled
            }
            logger.error(
                "Transcription failed; rebuilding local model once: \(error.localizedDescription, privacy: .public)"
            )
            let replacement = TranscriptionService()
            try await replacement.prepare()
            guard transcriptionGeneration == generation else {
                throw TranscriptionError.cancelled
            }
            transcriptionService = replacement
            return try await replacement.transcribe(samples: samples)
        }
    }

    private func startTranscriptionWatchdog(
        generation: UInt64,
        audioDuration: TimeInterval
    ) {
        transcriptionWatchdog?.cancel()
        let timeout = DictationPolicy.transcriptionTimeout(forAudioDuration: audioDuration)
        transcriptionWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self,
                  transcriptionGeneration == generation,
                  state == .transcribing else { return }

            logger.fault(
                "Transcription watchdog fired after \(timeout, privacy: .public) seconds"
            )
            transcriptionGeneration &+= 1
            insertionTarget = nil
            state = .preparing

            let replacement = TranscriptionService()
            do {
                try await replacement.prepare()
                transcriptionService = replacement
                modelIsReady = true
                presentRecoverableFailure("Transkrypcja została bezpiecznie zrestartowana")
            } catch {
                modelIsReady = false
                state = .failed("Nie udało się ponownie przygotować modelu")
            }
        }
    }

    private func presentRecoverableFailure(
        _ message: String,
        delay: TimeInterval = 3
    ) {
        failureRecovery?.cancel()
        state = .failed(message)
        stopMicrophone()
        failureRecovery = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            failureRecovery = nil
            guard modelIsReady, wakeWordIsReady, TextInserter.isAuthorized else { return }
            state = .ready
            reconcileMicrophone()
        }
    }
}
