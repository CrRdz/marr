import AppKit
import OSLog
import RiveRuntime
import SwiftUI

/// Stable business phases. Their visual presentation is intentionally shared across five moods.
/// Earlier study phases remain compatible with callers without expanding the visual vocabulary.
/// The animation never decides whether an operation succeeded.
enum MarrCompanionPhase: Int, CaseIterable, Sendable {
    case idle, selecting, selected, annotating, sending, recognizing
    case translating, rendering, success, error, comparing, pinned, responding
    case curious, thinking, delighted, shy, sleepy, surprised, playful, greeting
    case scanText, translateFlow, alignLayout, compareSides, focusText
    case languageSwitch, translationReveal, retryTranslation

    static let workflowPhases: [Self] = [
        .idle, .selecting, .selected, .annotating, .sending, .recognizing,
        .translating, .rendering, .success, .error, .comparing, .pinned, .responding
    ]
    static let personalityPhases: [Self] = [
        .curious, .thinking, .delighted, .shy, .sleepy, .surprised, .playful, .greeting
    ]
    static let translationStudyPhases: [Self] = [
        .scanText, .translateFlow, .alignLayout, .compareSides, .focusText,
        .languageSwitch, .translationReveal, .retryTranslation
    ]

    var mood: MarrCompanionMood {
        switch self {
        case .idle, .sleepy: .waiting
        case .selecting, .selected, .annotating, .comparing, .pinned,
             .curious, .shy, .playful, .compareSides, .focusText: .observing
        case .sending, .recognizing, .translating, .rendering, .responding,
             .thinking, .scanText, .translateFlow, .alignLayout, .languageSwitch, .retryTranslation: .processing
        case .success, .delighted, .greeting, .translationReveal: .settled
        case .error, .surprised: .attention
        }
    }

    var scanStrength: Float { self == .recognizing || self == .scanText ? 1 : 0 }

    var title: String {
        switch self {
        case .idle: "Ready to capture"
        case .selecting: "Selecting area…"
        case .selected: "Screenshot ready"
        case .annotating: "Annotating screenshot"
        case .sending: "Sending screenshot…"
        case .recognizing: "Recognizing text…"
        case .translating: "Translating…"
        case .rendering: "Laying out translation…"
        case .success: "Translation ready"
        case .error: "Needs attention"
        case .comparing: "Comparing original and translation"
        case .pinned: "Translation pinned"
        case .responding: "Preparing a response…"
        case .curious: "Curious peek"
        case .thinking: "Deep in thought"
        case .delighted: "Little celebration"
        case .shy: "Feeling shy"
        case .sleepy: "Sleepy drift"
        case .surprised: "A little surprise"
        case .playful: "Playful wobble"
        case .greeting: "Hello there"
        case .scanText: "Reading the screenshot"
        case .translateFlow: "Words crossing languages"
        case .alignLayout: "Putting the text in place"
        case .compareSides: "Checking both versions"
        case .focusText: "Focusing on a passage"
        case .languageSwitch: "Switching languages"
        case .translationReveal: "Revealing the translation"
        case .retryTranslation: "Giving it another try"
        }
    }

    static func capture(sending: Bool, selecting: Bool, annotating: Bool,
                        hasSelection: Bool, hasPinnedImages: Bool) -> Self {
        if sending { return .sending }
        if selecting { return .selecting }
        if annotating { return .annotating }
        return hasSelection || hasPinnedImages ? .selected : .idle
    }

    static func translationResult(comparing: Bool, pinned: Bool) -> Self {
        comparing ? .comparing : pinned ? .pinned : .success
    }
}

/// The native Rive `phase` input uses only these five stable values.
enum MarrCompanionMood: Int, CaseIterable, Sendable {
    case waiting, observing, processing, settled, attention

    var title: String {
        switch self {
        case .waiting: "Waiting"
        case .observing: "Observing"
        case .processing: "Processing"
        case .settled: "Complete"
        case .attention: "Needs attention"
        }
    }

    var representativePhase: MarrCompanionPhase {
        switch self {
        case .waiting: .idle
        case .observing: .selecting
        case .processing: .translating
        case .settled: .success
        case .attention: .error
        }
    }
}

/// Independent from activity: a selected tool can be idle, working, or complete.
enum MarrCompanionForm: Int, CaseIterable, Sendable {
    case orb, pen, translate, rectangle, arrow, number

    var title: String {
        switch self {
        case .orb: "Ready"
        case .pen: "Draw"
        case .translate: "Translate"
        case .rectangle: "Select"
        case .arrow: "Point"
        case .number: "Number"
        }
    }
}

/// One decoded file/texture and worker; each visible companion owns its own state machine.
@MainActor
private enum MarrCompanionResource {
    static let file: Task<RiveRuntime.File, Error> = Task {
        let worker = try await Worker()
        return try await RiveRuntime.File(source: .local("MarrCompanion", .main), worker: worker)
    }
}

@MainActor
final class MarrCompanionPlayer: ObservableObject {
    @Published private(set) var rive: Rive?
    private(set) var instance: ViewModelInstance?
    private(set) var phase: MarrCompanionPhase = .idle
    private(set) var reducesMotion = false
    private(set) var gaze: CGPoint = .zero
    private(set) var form: MarrCompanionForm?
    private var loadedToolArtboard = false
    private var isLoading = false
    private static let logger = Logger(subsystem: "Marr", category: "Companion")

    func load(phase: MarrCompanionPhase, reducesMotion: Bool, gaze: CGPoint = .zero,
              form: MarrCompanionForm? = nil) async {
        update(phase: phase, reducesMotion: reducesMotion, gaze: gaze, form: form)
        let needsToolArtboard = form != nil
        guard (rive == nil || loadedToolArtboard != needsToolArtboard), !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let file = try await MarrCompanionResource.file.value
            try Task.checkCancellation()
            let artboard = try await file.createArtboard(needsToolArtboard ? "Marr Tool" : "Marr Companion")
            let machine = try await artboard.createStateMachine("Companion")
            let binding = try await file.createViewModelInstance(.viewModelDefault(from: .artboardDefault(artboard)))
            try await machine.bindViewModelInstances(main: binding)
            let configuration = try await Rive(file: file, artboard: artboard, stateMachine: machine)
            try Task.checkCancellation()
            loadedToolArtboard = needsToolArtboard
            instance = binding
            rive = configuration
            applyState()
        } catch is CancellationError {
            // The screenshot may have been dismissed before its local asset finished loading.
        } catch {
            // Decorative animation must never block capture, translation, or retry controls.
            Self.logger.error("Could not load local companion: \(error.localizedDescription, privacy: .public)")
        }
    }

    func update(phase: MarrCompanionPhase, reducesMotion: Bool, gaze: CGPoint = .zero,
                form: MarrCompanionForm? = nil) {
        // Pointer movement must not animate a companion when Reduce Motion is enabled.
        let nextGaze = reducesMotion ? .zero : Self.clampedGaze(gaze)
        guard self.phase != phase || self.reducesMotion != reducesMotion || self.gaze != nextGaze || self.form != form else { return }
        self.phase = phase
        self.reducesMotion = reducesMotion
        self.gaze = nextGaze
        self.form = form
        applyState()
    }

    private static func clampedGaze(_ gaze: CGPoint) -> CGPoint {
        func component(_ value: CGFloat) -> CGFloat { value.isFinite ? min(1, max(-1, value)) : 0 }
        return CGPoint(x: component(gaze.x), y: component(gaze.y))
    }

    func applyPersonality(_ pose: MarrCompanionPersonality.Pose) {
        let pose = reducesMotion ? MarrCompanionPersonality.Pose.rest : pose
        instance?.setValue(of: NumberProperty(path: "bodyX"), to: Float(64 + pose.body.x))
        instance?.setValue(of: NumberProperty(path: "bodyY"), to: Float(64 + pose.body.y))
        instance?.setValue(of: NumberProperty(path: "bodyTilt"), to: Float(pose.tilt))
        instance?.setValue(of: NumberProperty(path: "eyeOpen"), to: Float(pose.eyeOpen))
    }

    private func applyState() {
        instance?.setValue(of: NumberProperty(path: "phase"), to: Float(phase.mood.rawValue))
        instance?.setValue(of: NumberProperty(path: "scan"), to: phase.scanStrength)
        instance?.setValue(of: NumberProperty(path: "tool"), to: Float(form?.rawValue ?? 0))
        instance?.setValue(of: NumberProperty(path: "gazeX"), to: Float(gaze.x * 10))
        instance?.setValue(of: NumberProperty(path: "gazeY"), to: Float(gaze.y * 8))
        // With motion disabled, resolve the new expression once, then keep the view paused.
        // This also gives a newly loaded, initially paused view a meaningful first frame.
        rive?.stateMachine.advance(by: 0)
        if reducesMotion {
            applyPersonality(.rest)
            rive?.stateMachine.advance(by: form == nil ? 0.85 : 1.7)
        }
    }
}

/// Decorative, local-only animation. Native controls and text retain their semantics.
struct MarrCompanion: View {
    let phase: MarrCompanionPhase
    var size: CGFloat = 32
    /// Direction to the relevant content, normalized to -1...1 in local screen coordinates.
    var gaze: CGPoint = .zero
    /// A value opts into the vector tool artboard; nil keeps the original companion.
    var form: MarrCompanionForm? = nil
    /// Opt in for composer mascots; content-directed companions keep their explicit gaze.
    var followsPointer = false
    @StateObject private var player = MarrCompanionPlayer()
    @Environment(\.accessibilityReduceMotion) private var systemReducesMotion
    @Environment(\.marrAccessibilityOverrides) private var overrides
    @State private var isWindowVisible = false
    @State private var isPresented = false

    private var reducesMotion: Bool { overrides?.reducesMotion ?? systemReducesMotion }

    var body: some View {
        ZStack {
            if let rive = player.rive {
                RiveUIViewRepresentable(rive: rive)
                    .frameRate(.fps(30))
                    .paused(reducesMotion || !isPresented || !isWindowVisible)
            } else {
                SwiftUI.Image("MarrStatusIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.08)
            }
        }
        .frame(width: size, height: size)
        .background(MarrAmbientWindowVisibilityObserver { isWindowVisible = $0 })
        .background {
            if followsPointer {
                MarrCompanionPointerObserver(enabled: isPresented && isWindowVisible && !reducesMotion) { pose in
                    player.update(phase: phase, reducesMotion: reducesMotion, gaze: pose.gaze, form: form)
                    player.applyPersonality(pose)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: form != nil) { await player.load(phase: phase, reducesMotion: reducesMotion, gaze: gaze, form: form) }
        .onAppear { isPresented = true }
        .onDisappear { isPresented = false }
        .onChange(of: phase) { _, value in player.update(phase: value, reducesMotion: reducesMotion, gaze: gaze, form: form) }
        .onChange(of: reducesMotion) { _, value in player.update(phase: phase, reducesMotion: value, gaze: gaze, form: form) }
        .onChange(of: form) { _, value in player.update(phase: phase, reducesMotion: reducesMotion, gaze: gaze, form: value) }
        .onChange(of: gaze) { _, value in player.update(phase: phase, reducesMotion: reducesMotion, gaze: value, form: form) }
    }
}

/// Sample screen coordinates without consuming events or requiring global input permission.
/// Keeping interpolation here avoids rerendering the chat transcript on every pointer move.
private struct MarrCompanionPointerObserver: NSViewRepresentable {
    let enabled: Bool
    let onPose: (MarrCompanionPersonality.Pose) -> Void

    func makeNSView(context: Context) -> MarrCompanionPointerView { MarrCompanionPointerView() }

    func updateNSView(_ view: MarrCompanionPointerView, context: Context) {
        view.onPose = onPose
        view.setEnabled(enabled)
    }

    static func dismantleNSView(_ view: MarrCompanionPointerView, coordinator: ()) {
        view.setEnabled(false)
        view.onPose = nil
    }
}

final class MarrCompanionPointerView: NSView {
    var onPose: ((MarrCompanionPersonality.Pose) -> Void)?
    private var timer: Timer?
    private var enabled = false
    private var personality = MarrCompanionPersonality()
    private var lastTick = ProcessInfo.processInfo.systemUptime

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshTimer()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        refreshTimer()
    }

    private func refreshTimer() {
        guard enabled, window != nil else {
            timer?.invalidate()
            timer = nil
            personality = MarrCompanionPersonality()
            onPose?(.rest)
            return
        }
        guard timer == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.samplePointer() }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// AppKit screen Y points up; the Rive artboard points down. Radial limiting
    /// keeps diagonal looks within the same safe eye radius as horizontal looks.
    static func target(pointer: CGPoint, center: CGPoint) -> CGPoint {
        let dx = (pointer.x - center.x) / 180
        let dy = (center.y - pointer.y) / 180
        guard dx.isFinite, dy.isFinite else { return .zero }
        let divisor = max(1, hypot(dx, dy))
        return CGPoint(x: dx / divisor, y: dy / divisor)
    }

    private func samplePointer() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let center = window.convertPoint(toScreen: convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil))
        let active = window.isVisible && !window.isMiniaturized
            && window.occlusionState.contains(.visible) && window.frame.contains(mouse)
        let target = active ? Self.target(pointer: mouse, center: center) : .zero
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.05, max(0.001, now - lastTick))
        lastTick = now
        let near = active && hypot(mouse.x - center.x, mouse.y - center.y) < 80
        onPose?(personality.advance(dt: dt, target: target, engaged: active, near: near))
    }

    deinit { timer?.invalidate() }
}

/// Eyes react first; a damped body follows. Time is local to the visible view,
/// so resuming after sleep never causes a large jump or a burst of old blinks.
struct MarrCompanionPersonality {
    struct Pose {
        var gaze: CGPoint = .zero
        var body: CGPoint = .zero
        var tilt: CGFloat = 0
        var eyeOpen: CGFloat = 1
        static let rest = Pose()
    }
    private(set) var pose = Pose.rest
    private var velocity = CGPoint.zero
    private var elapsed: Double = 0
    private var stillTime: Double = 0
    private var previousTarget = CGPoint.zero
    private var nextBlink: Double = 2.6
    private var blinkStart: Double?
    private var doubleBlink = false
    private var wasNear = false
    private var greeting: Double = 0

    mutating func advance(dt: Double, target: CGPoint, engaged: Bool, near: Bool,
                          blinkDelay: Double = Double.random(in: 3.2...6.8),
                          shouldDoubleBlink: Bool = Double.random(in: 0...1) < 0.2) -> Pose {
        elapsed += dt
        if hypot(target.x - previousTarget.x, target.y - previousTarget.y) > 0.025 {
            stillTime = 0
        } else { stillTime += dt }
        previousTarget = target
        if near && !wasNear { greeting = 1 }
        wasNear = near
        greeting = max(0, greeting - dt * 1.8)

        // Small exploratory glances after the pointer settles; never pin the
        // eyes at a saturated corner for the entire idle period.
        var aim = target
        if stillTime > 2.0 {
            let curiosity = min(1, (stillTime - 2) / 1.5)
            aim.x = aim.x * (1 - 0.22 * curiosity) + sin(elapsed * 1.3) * 0.22 * curiosity
            aim.y = aim.y * (1 - 0.15 * curiosity) + cos(elapsed * 0.9) * 0.12 * curiosity
        }
        if !engaged {
            aim = CGPoint(x: sin(elapsed * 0.8) * 0.32, y: sin(elapsed * 0.6) * 0.14)
        }
        let eyeBlend = 1 - exp(-dt * 15)
        pose.gaze.x += (aim.x - pose.gaze.x) * eyeBlend
        pose.gaze.y += (aim.y - pose.gaze.y) * eyeBlend
        let bodyTarget = CGPoint(x: aim.x * 4.5,
                                 y: aim.y * 2.5 + sin(elapsed * 2.1) * 2.3 - sin(greeting * .pi) * 4)
        velocity.x += ((bodyTarget.x - pose.body.x) * 65 - velocity.x * 12) * dt
        velocity.y += ((bodyTarget.y - pose.body.y) * 65 - velocity.y * 12) * dt
        pose.body.x += velocity.x * dt
        pose.body.y += velocity.y * dt
        let curiousTilt = stillTime > 1.5 ? sin(elapsed * 0.85) * 0.055 : 0
        pose.tilt += (aim.x * 0.085 + curiousTilt - pose.tilt) * (1 - exp(-dt * 5))

        if elapsed >= nextBlink && blinkStart == nil {
            blinkStart = elapsed
            doubleBlink = shouldDoubleBlink
        }
        pose.eyeOpen = 1 + sin(greeting * .pi) * 0.18
        if let start = blinkStart {
            let age = elapsed - start
            let duration = doubleBlink ? 0.48 : 0.22
            if age >= duration {
                blinkStart = nil
                nextBlink = elapsed + blinkDelay
            } else {
                let local = age > 0.26 ? age - 0.26 : age
                if local < 0.075 { pose.eyeOpen = 1 - 0.95 * local / 0.075 }
                else if local < 0.22 { pose.eyeOpen = 0.05 + 0.95 * (local - 0.075) / 0.145 }
            }
        }
        return pose
    }
}
