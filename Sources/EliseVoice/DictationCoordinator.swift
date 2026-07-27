import AppKit
import Foundation
import EliseVoiceCore
import OSLog

enum DictationState: Equatable {
    case preparing
    case ready
    case recording(elapsedSeconds: Int)
    case transcribing
    case failed(String, showsPanel: Bool)

    /// Failures surface the panel by default. Repeated automatic retries pass
    /// `showsPanel: false` so a permanent problem does not flash the overlay
    /// every minute; the menu bar icon still reports it.
    static func failed(_ message: String) -> DictationState {
        .failed(message, showsPanel: true)
    }
}

@MainActor
final class DictationCoordinator {
    static let automaticSilenceStop = DictationPolicy.automaticSilenceStop

    private let logger = Logger(subsystem: "com.elisevoice.app", category: "lifecycle")
    private let audioCapture: AudioCaptureService
    private var transcriptionService: TranscriptionService
    private let onStateChange: (DictationState) -> Void
    private let onAudioLevelChange: (Float, TimeInterval?) -> Void

    private var modelIsReady = false
    private var systemAllowsAudio = true
    private var recordingMonitor: Task<Void, Never>?
    private var accessibilityMonitor: Task<Void, Never>?
    private var audioHealthMonitor: Task<Void, Never>?
    private var audioRecovery: Task<Void, Never>?
    private var failureRecovery: Task<Void, Never>?
    private var transcriptionWatchdog: Task<Void, Never>?
    private var preparationRetry: Task<Void, Never>?
    private var modelRebuild: Task<Void, Never>?
    private var preparationFailures = 0
    private var isPreparing = false
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var isStartingRecording = false
    private var insertionTarget: TextInsertionTarget?
    private var pendingDictationStart = false
    private var transcriptionGeneration: UInt64 = 0
    private var lastReportedDroppedBuffers: UInt64 = 0
    private var consecutiveAudioRecoveryFailures = 0

    private(set) var state: DictationState = .preparing {
        didSet { onStateChange(state) }
    }

    init(
        audioCapture: AudioCaptureService = AudioCaptureService(),
        transcriptionService: TranscriptionService = TranscriptionService(),
        onStateChange: @escaping (DictationState) -> Void,
        onAudioLevelChange: @escaping (Float, TimeInterval?) -> Void
    ) {
        self.audioCapture = audioCapture
        self.transcriptionService = transcriptionService
        self.onStateChange = onStateChange
        self.onAudioLevelChange = onAudioLevelChange

        audioCapture.configurationChangeHandler = { [weak self] in
            Task { @MainActor in
                self?.scheduleAudioRecovery(reason: "hardware configuration")
            }
        }
        installLifecycleObservers()
        startMemoryPressureMonitor()
    }

    func prepare() async {
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }

        preparationRetry?.cancel()
        preparationRetry = nil
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
            try await transcriptionService.prepare()
            modelIsReady = true
            preparationFailures = 0

            if accessibilityIsReady {
                await transitionToReady()
            } else {
                state = .failed("Włącz Elise Voice w Prywatność i ochrona → Dostępność")
                startAccessibilityMonitor()
            }
        } catch {
            logger.error("Preparation failed: \(error.localizedDescription, privacy: .public)")
            preparationFailures += 1
            let delay = ModelPreparationPolicy.retryDelay(
                afterFailureCount: preparationFailures
            )
            state = .failed(
                "Model nie jest gotowy — ponawiam za \(Int(delay)) s",
                showsPanel: preparationFailures <= 2
            )
            schedulePreparationRetry(after: delay)
        }
    }

    func toggleDictation() async {
        failureRecovery?.cancel()
        failureRecovery = nil
        switch state {
        case .ready:
            await startRecordingIfAuthorized()
        case .failed:
            if modelIsReady {
                await startRecordingIfAuthorized()
            } else {
                pendingDictationStart = true
                await prepare()
            }
        case .recording:
            await stopAndTranscribe()
        case .preparing:
            guard !isStartingRecording else { return }
            pendingDictationStart = true
        case .transcribing:
            pendingDictationStart = true
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
        preparationRetry?.cancel()
        preparationRetry = nil
        modelRebuild?.cancel()
        modelRebuild = nil
        transcriptionGeneration &+= 1
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        lifecycleObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        lifecycleObservers.removeAll()
        insertionTarget = nil
        pendingDictationStart = false
        audioCapture.cancelDictation()
        stopMicrophone()
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
            try ensureMicrophoneRunning()

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
            logger.error("Dictation could not start: \(error.localizedDescription, privacy: .public)")
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
            await transitionToReady()
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
            await transitionToReady()
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
                await transitionToReady()
                return
            }
            guard let target = insertionTarget else {
                throw TextInserterError.noFocusedTextField
            }
            try await TextInserter.paste(text, into: target)
            insertionTarget = nil
            await transitionToReady()
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
                        try ensureMicrophoneRunning()
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

    private func ensureMicrophoneRunning() throws {
        if !audioCapture.isMonitoring {
            try audioCapture.startMonitoring()
            startAudioHealthMonitor()
        }
        consecutiveAudioRecoveryFailures = 0
    }

    private func reconcileMicrophone() {
        guard systemAllowsAudio, case .recording = state else {
            stopMicrophone()
            return
        }
        do {
            try ensureMicrophoneRunning()
        } catch {
            logger.error("Microphone reconciliation failed: \(error.localizedDescription, privacy: .public)")
            consecutiveAudioRecoveryFailures += 1
            let delay = MicrophoneLifecyclePolicy.recoveryDelay(
                afterFailureCount: consecutiveAudioRecoveryFailures
            )
            presentRecoverableFailure(error.localizedDescription, delay: delay)
        }
    }

    private func transitionToReady() async {
        state = .ready
        reconcileMicrophone()
        await startPendingDictationIfRequested()
    }

    private func startPendingDictationIfRequested() async {
        guard pendingDictationStart,
              systemAllowsAudio,
              state == .ready,
              !isStartingRecording else {
            return
        }
        pendingDictationStart = false
        await startRecordingIfAuthorized()
    }

    private func stopMicrophone() {
        // The heartbeat only has something to watch while the stream runs, so it
        // is tied to the stream instead of to the process. Otherwise it woke the
        // app every two seconds around the clock just to re-check a flag.
        audioHealthMonitor?.cancel()
        audioHealthMonitor = nil
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
                self.scheduleModelRebuildAfterMemoryPressure()
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    /// Dropping the model leaves the app advertising a readiness it can no
    /// longer deliver immediately. Rebuild it quietly once the system has had
    /// time to recover, without showing the panel the user never asked for.
    private func scheduleModelRebuildAfterMemoryPressure() {
        modelRebuild?.cancel()
        modelRebuild = Task { @MainActor [weak self] in
            guard let self else { return }
            await transcriptionService.releaseModelForMemoryPressure()
            try? await Task.sleep(
                for: .seconds(ModelPreparationPolicy.memoryPressureRebuildDelay)
            )
            guard !Task.isCancelled, !modelIsReady, state == .ready else { return }
            modelRebuild = nil
            do {
                try await transcriptionService.prepare()
                modelIsReady = true
                logger.notice("Transcription model rebuilt after memory pressure")
            } catch {
                logger.error(
                    "Rebuild after memory pressure failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
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
        pendingDictationStart = false
        stopMicrophone()
    }

    private func resumeAfterSystem() {
        systemAllowsAudio = true
        scheduleAudioRecovery(reason: "system resume")
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Waking or unlocking is when connectivity and the disk cache come
            // back, so an earlier preparation failure is retried immediately
            // instead of waiting out the remaining backoff.
            if !modelIsReady {
                preparationFailures = 0
                await prepare()
                return
            }
            await startPendingDictationIfRequested()
        }
    }

    private func schedulePreparationRetry(after delay: TimeInterval) {
        preparationRetry?.cancel()
        preparationRetry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !modelIsReady else { return }
            preparationRetry = nil
            await prepare()
        }
    }

    private func startAccessibilityMonitor() {
        guard accessibilityMonitor == nil else { return }
        accessibilityMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }

                if TextInserter.isAuthorized {
                    accessibilityMonitor = nil
                    if modelIsReady {
                        await transitionToReady()
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
            guard modelIsReady, TextInserter.isAuthorized else { return }
            await transitionToReady()
        }
    }
}
