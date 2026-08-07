import AppKit
import Combine
import OSLog
import SwiftUI

private enum RecordingOverlayPhase: Equatable {
    case listening
    case preparing
    case recording
    case transcribing
    case failed
}

@MainActor
private final class RecordingWindowModel: ObservableObject {
    @Published var phase: RecordingOverlayPhase = .preparing
    @Published var elapsedSeconds = 0
    @Published var level: Float = 0
    @Published var silenceRemaining: TimeInterval?
    @Published var errorMessage = ""
    @Published var isPresented = false
    @Published var animationActive = false
    @Published var notchWidth: CGFloat = 172
}

@MainActor
final class RecordingWindowController {
    private static let panelSize = NSSize(width: 430, height: 122)

    private let logger = Logger(subsystem: "com.elisevoice.app", category: "overlay")
    private let model = RecordingWindowModel()
    private let panel: NSPanel
    private var delayedHide: Task<Void, Never>?
    private var preparingTicker: Task<Void, Never>?
    private var pendingHide: Task<Void, Never>?
    private var presentationGeneration = 0
    private var systemObservers: [NSObjectProtocol] = []

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // The window server hides the whole menu bar layer while another
        // application is full screen, and the overlay used to sit just above the
        // status bar. Screen saver level stays above full-screen windows.
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        // Elise is a regular application, so "Hide Others" and ⌘H used to hide
        // this panel for the rest of the session: dictation kept working from
        // the shortcut while the overlay never came back on screen.
        panel.canHide = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.contentView = NSHostingView(rootView: RecordingOverlayView(model: model))
        observeSystemChanges()
    }

    func render(_ state: DictationState) {
        delayedHide?.cancel()
        if case .preparing = state {} else { stopPreparingTicker() }

        switch state {
        case .preparing:
            model.phase = .preparing
            startPreparingTicker()
            show()
        case .ready:
            hide()
        case let .recording(elapsedSeconds):
            model.phase = .recording
            model.elapsedSeconds = elapsedSeconds
            show()
        case .transcribing:
            model.phase = .transcribing
            model.level = 0
            model.silenceRemaining = nil
            show()
        case let .failed(message, showsPanel):
            model.phase = .failed
            model.errorMessage = message
            guard showsPanel else {
                // A repeating automatic retry reports through the menu bar icon
                // only, instead of flashing the overlay on every attempt.
                hide()
                return
            }
            show()
            delayedHide = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(7))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    func updateAudio(level: Float, silenceRemaining: TimeInterval?) {
        model.level = level
        model.silenceRemaining = silenceRemaining
    }

    func showListeningBriefly() {
        delayedHide?.cancel()
        model.phase = .listening
        model.level = 0
        model.silenceRemaining = nil
        show()
        delayedHide = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    /// Loading Large v3 from a cold cache takes over a minute. Counting the
    /// seconds tells the user the app is working rather than hung, which is what
    /// a static label looked like.
    private func startPreparingTicker() {
        guard preparingTicker == nil else { return }
        model.elapsedSeconds = 0
        preparingTicker = Task { @MainActor [weak self] in
            var seconds = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                seconds += 1
                model.elapsedSeconds = seconds
            }
        }
    }

    private func stopPreparingTicker() {
        preparingTicker?.cancel()
        preparingTicker = nil
    }

    /// Every path is unconditional on purpose. The previous version returned
    /// early whenever the panel was already on screen, which left two ways for
    /// the overlay to disappear for the rest of the session: a show() arriving
    /// inside the 210 ms hide window never restored `isPresented`, so the panel
    /// stayed on screen fully transparent, and a panel pushed behind another
    /// window was never ordered front again.
    private func show() {
        pendingHide?.cancel()
        pendingHide = nil
        presentationGeneration &+= 1
        let generation = presentationGeneration

        positionPanel()
        model.animationActive = true
        orderPanelFront()

        guard !model.isPresented else { return }

        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.presentationGeneration == generation else { return }
            if !self.panel.isVisible {
                // Ordering a window front loses against a hidden application or
                // a space transition, and no state change would retry it.
                self.orderPanelFront()
                if !self.panel.isVisible {
                    self.logger.notice(
                        "Overlay stayed off screen (appHidden=\(NSApp.isHidden ? "yes" : "no", privacy: .public))"
                    )
                }
            }
            withAnimation(.spring(response: 0.48, dampingFraction: 0.76, blendDuration: 0.12)) {
                self.model.isPresented = true
            }
        }
    }

    private func hide() {
        presentationGeneration &+= 1
        let generation = presentationGeneration
        pendingHide?.cancel()
        pendingHide = nil

        guard panel.isVisible else {
            model.isPresented = false
            model.animationActive = false
            return
        }

        withAnimation(.easeIn(duration: 0.18)) {
            model.isPresented = false
        }

        pendingHide = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(210))
            guard let self, !Task.isCancelled,
                  self.presentationGeneration == generation else { return }
            self.pendingHide = nil
            self.panel.orderOut(nil)
            self.model.animationActive = false
        }
    }

    private func orderPanelFront() {
        if NSApp.isHidden {
            // A hidden application cannot put any window on screen, and the
            // panel is the only window this app ever shows.
            NSApp.unhideWithoutActivation()
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// Switching spaces, another application entering or leaving full screen and
    /// attaching a display all leave the overlay behind the active window while
    /// AppKit still reports it as visible. No dictation state change follows, so
    /// nothing else would order it front again.
    private func observeSystemChanges() {
        systemObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reassertPresentation() }
            }
        )
        systemObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reassertPresentation() }
            }
        )
    }

    private func reassertPresentation() {
        guard model.animationActive else { return }
        positionPanel()
        orderPanelFront()
    }

    private func positionPanel() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let screenFrame = screen.frame
        let notchWidth = physicalNotchWidth(on: screen)
        model.notchWidth = notchWidth

        let hasPhysicalNotch = screen.safeAreaInsets.top > 0
        let topEdge = hasPhysicalNotch
            ? screenFrame.maxY - screen.safeAreaInsets.top + 1
            : screen.visibleFrame.maxY - 6
        let origin = NSPoint(
            x: screenFrame.midX - Self.panelSize.width / 2,
            y: topEdge - Self.panelSize.height
        )
        panel.setFrame(NSRect(origin: origin, size: Self.panelSize), display: false)
    }

    private func physicalNotchWidth(on screen: NSScreen) -> CGFloat {
        guard
            let leftArea = screen.auxiliaryTopLeftArea,
            let rightArea = screen.auxiliaryTopRightArea
        else {
            return 118
        }

        let measuredWidth = rightArea.minX - leftArea.maxX
        return min(max(measuredWidth, 118), 220)
    }
}

private struct RecordingOverlayView: View {
    @ObservedObject var model: RecordingWindowModel

    var body: some View {
        Group {
            if model.animationActive {
                TimelineView(.animation(minimumInterval: animationInterval)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate

                    ZStack(alignment: .top) {
                        notchWake(time: time)

                        HStack(spacing: 11) {
                            ElisePortrait(
                                time: time,
                                level: model.level,
                                active: model.phase == .recording
                            )
                            .frame(width: 108, height: 108)
                            .offset(
                                x: model.isPresented ? 0 : 96,
                                y: model.isPresented ? 0 : -45
                            )
                            .opacity(model.isPresented ? 1 : 0)

                            voiceModule(time: time)
                                .frame(width: 208, height: 72)
                                .offset(
                                    x: model.isPresented ? 0 : -72,
                                    y: model.isPresented ? 0 : -40
                                )
                                .opacity(model.isPresented ? 1 : 0)
                        }
                        .padding(.top, 4)

                        if model.phase == .failed, model.isPresented {
                            errorPill
                                .offset(y: 91)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .frame(width: 430, height: 122, alignment: .top)
                    .compositingGroup()
                }
            } else {
                Color.clear.frame(width: 430, height: 122)
            }
        }
    }

    private var animationInterval: TimeInterval {
        switch model.phase {
        case .recording:
            1.0 / 30.0
        case .preparing, .transcribing:
            1.0 / 24.0
        case .listening, .failed:
            1.0 / 20.0
        }
    }

    private func notchWake(time: TimeInterval) -> some View {
        let breathing = 0.72 + (sin(time * 3.4) + 1) * 0.14
        let activeColor = model.phase == .failed
            ? Color.orange
            : Color(red: 0.23, green: 0.91, blue: 1)

        return ZStack(alignment: .top) {
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.96))
                .frame(
                    width: model.isPresented ? model.notchWidth + 12 : model.notchWidth * 0.72,
                    height: model.isPresented ? 7 : 2
                )
                .offset(y: -4)

            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.clear, activeColor.opacity(breathing), .white.opacity(0.85), activeColor.opacity(breathing), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(
                    width: model.isPresented ? model.notchWidth + 66 : 8,
                    height: model.phase == .recording ? 2.2 : 1.2
                )
                .blur(radius: model.phase == .recording ? 0.8 : 1.3)
                .shadow(color: activeColor.opacity(0.72), radius: 8)
                .offset(y: 1)

        }
    }

    private func voiceModule(time: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(statusLabel)
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .tracking(1.55)
                    .foregroundStyle(statusColor)
                    .shadow(color: .black.opacity(0.92), radius: 1.2, y: 0.6)

                Spacer(minLength: 5)

                if model.phase == .recording || model.phase == .preparing {
                    Text(formattedDuration(model.elapsedSeconds))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.94))
                        .shadow(color: .black.opacity(0.9), radius: 1.2, y: 0.6)
                }
            }
            .padding(.horizontal, 4)

            VoiceModulationView(
                level: model.level,
                time: time,
                phase: model.phase
            )
            .frame(height: 47)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
    }

    private var errorPill: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text(model.errorMessage)
                .lineLimit(1)
            Text("Menu Elise → ustawienia")
                .foregroundStyle(.cyan.opacity(0.72))
        }
        .font(.system(size: 10.5, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.88))
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(.white.opacity(0.1), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
    }

    private var statusLabel: String {
        switch model.phase {
        case .listening:
            "ELISE"
        case .preparing:
            "LOADING"
        case .recording:
            "RECORDING"
        case .transcribing:
            "TRANSCRIBING"
        case .failed:
            "PAUSED"
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .recording:
            Color(red: 0.2, green: 0.88, blue: 1)
        case .failed:
            .orange
        case .transcribing:
            .mint
        case .listening, .preparing:
            .white.opacity(0.75)
        }
    }

    private func formattedDuration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct ElisePortrait: View {
    let time: TimeInterval
    let level: Float
    let active: Bool

    private static let portrait: NSImage = {
        if let url = Bundle.main.url(forResource: "ElisePortraitTransparent-v5", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            return image
        }
        return NSApplication.shared.applicationIconImage
    }()

    var body: some View {
        let pulse = active ? 1 + CGFloat(level) * 0.035 : 1 + CGFloat((sin(time * 2.1) + 1) * 0.008)
        Image(nsImage: Self.portrait)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .foregroundStyle(
                LinearGradient(
                colors: [
                    Color(red: 0.70, green: 0.97, blue: 1.00),
                    Color(red: 0.10, green: 0.82, blue: 0.96),
                    Color(red: 0.00, green: 0.48, blue: 0.68)
                ],
                startPoint: .top,
                endPoint: .bottom
                )
            )
            .shadow(color: Color(red: 0.0, green: 0.16, blue: 0.23).opacity(0.78), radius: 0.85)
            .shadow(color: .cyan.opacity(active ? 0.66 : 0.34), radius: active ? 4 : 2)
            .scaleEffect(pulse, anchor: .center)
        .accessibilityHidden(true)
    }
}

private struct VoiceModulationView: View {
    let level: Float
    let time: TimeInterval
    let phase: RecordingOverlayPhase

    var body: some View {
        Canvas { context, size in
            let samples = 54
            let midpoint = size.height / 2
            let strength = visualStrength
            var upper = Path()
            var lower = Path()

            for index in 0..<samples {
                let progress = CGFloat(index) / CGFloat(samples - 1)
                let x = progress * size.width
                let envelope = pow(sin(progress * CGFloat.pi), 0.72)
                let carrier = sin(time * phaseSpeed + Double(index) * 0.72)
                let harmonic = sin(time * phaseSpeed * 0.57 - Double(index) * 0.31)
                let modulation = CGFloat(carrier * 0.62 + harmonic * 0.38)
                let amplitude = max(1.2, size.height * envelope * strength * 0.44)
                let y = midpoint + modulation * amplitude

                if index == 0 {
                    upper.move(to: CGPoint(x: x, y: y))
                    lower.move(to: CGPoint(x: x, y: midpoint - (y - midpoint) * 0.46))
                } else {
                    upper.addLine(to: CGPoint(x: x, y: y))
                    lower.addLine(to: CGPoint(x: x, y: midpoint - (y - midpoint) * 0.46))
                }
            }

            let gradient = Gradient(colors: [
                Color(red: 0, green: 0.35, blue: 0.56).opacity(0.75),
                Color(red: 0.02, green: 0.78, blue: 0.94),
                .white,
                Color(red: 0.02, green: 0.78, blue: 0.94),
                Color(red: 0, green: 0.35, blue: 0.56).opacity(0.75)
            ])
            let shading = GraphicsContext.Shading.linearGradient(
                gradient,
                startPoint: .zero,
                endPoint: CGPoint(x: size.width, y: 0)
            )

            let contrast = Color(red: 0.005, green: 0.12, blue: 0.2).opacity(0.82)
            context.stroke(upper, with: .color(contrast), style: StrokeStyle(lineWidth: 2.7, lineCap: .round, lineJoin: .round))
            context.stroke(lower, with: .color(contrast.opacity(0.58)), style: StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round))
            context.stroke(upper, with: shading, style: StrokeStyle(lineWidth: 1.45, lineCap: .round, lineJoin: .round))
            context.stroke(lower, with: shading, style: StrokeStyle(lineWidth: 0.75, lineCap: .round, lineJoin: .round))

        }
        .shadow(color: .cyan.opacity(0.42), radius: phase == .recording ? 4 : 2)
        .accessibilityHidden(true)
    }

    private var visualStrength: CGFloat {
        switch phase {
        case .recording:
            max(CGFloat(level), 0.12)
        case .transcribing:
            0.32
        case .listening:
            0.11
        case .preparing:
            0.2
        case .failed:
            0.06
        }
    }

    private var phaseSpeed: Double {
        switch phase {
        case .transcribing:
            8.8
        case .recording:
            6.7
        case .preparing:
            4.8
        case .listening, .failed:
            2.4
        }
    }
}
