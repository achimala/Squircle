#if !SQUIRCLE_OVERLAY
import UIKit

/// Screen and performance recordings of Squircle itself, from the message
/// field's + menu: the same recorders and session the debug overlay uses on
/// other apps. The scene owns it, so a recording runs on across every push
/// and pop; its stop control is a window of its own above the app's, left
/// out of the recording as the overlay is. Stopped, the recording goes into
/// the field of the conversation on screen (or the one it started in).
@MainActor
final class SelfRecording {
    private let model: SquircleModel
    private let capture = CaptureSession()
    private let window: ControlWindow
    private let control: StopControl
    /// The conversation whose + menu started it: the field it lands in when
    /// none is on screen at the stop.
    private var origin: ConversationID?

    init(scene: UIWindowScene, model: SquircleModel) {
        self.model = model
        window = ControlWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        control = StopControl()
        let root = ControlController(control: control)
        window.rootViewController = root
        window.control = control
        control.onTap = { [weak self] in self?.stop() }
        capture.onLimit = { [weak self] in self?.stop() }
        capture.onStopping = { [weak self] in self?.render() }
        render()
        #if DEBUG
        recordIfAsked()
        #endif
    }

    #if DEBUG
    /// Verification only: `SQUIRCLE_SELF_RECORD=performance|screen` starts
    /// that recording, as the + menu would, once a conversation is open, and
    /// stops it `SQUIRCLE_SELF_RECORD_SECONDS` (default 20) later, as the
    /// stop control would (pair with `SQUIRCLE_NAV_LOOP`).
    private func recordIfAsked() {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment["SQUIRCLE_SELF_RECORD"] else { return }
        let seconds = environment["SQUIRCLE_SELF_RECORD_SECONDS"].flatMap(Double.init) ?? 20
        Task { [weak self] in
            while self?.model.open == nil { try? await Task.sleep(for: .milliseconds(100)) }
            self?.start(mode == "screen" ? .screen : .performance)
            try? await Task.sleep(for: .seconds(seconds))
            self?.stop()
        }
    }
    #endif

    /// Whether `project` is the app that is running: Squircle records
    /// itself only in its own conversations.
    nonisolated static func records(_ project: AppProject) -> Bool {
        guard let bundleID = project.bundleID, !bundleID.isEmpty else { return false }
        return bundleID == Bundle.main.bundleIdentifier
    }

    /// The + menu's recordings, unavailable while one runs.
    var menu: [UIMenuElement] {
        let busy: UIMenuElement.Attributes = capture.recording == nil ? [] : .disabled
        return [UIAction(title: "Record Screen", image: UIImage(systemName: "record.circle"), attributes: busy) { [weak self] _ in self?.start(.screen) },
                UIAction(title: "Record Performance", image: UIImage(systemName: "waveform.path.ecg"), attributes: busy) { [weak self] _ in self?.start(.performance) }]
    }

    private func start(_ kind: CaptureSession.Kind) {
        let open = model.open
        guard capture.start(kind, below: window) else { return }
        origin = open
        Theme.openHaptic()
        window.windowScene?.windows.forEach { $0.endEditing(true) }
        render()
    }

    private func stop() {
        guard let recording = capture.recording, !capture.isStopping else { return }
        Theme.openHaptic()
        let poster = recording.kind == .screen ? HostCapture.image(below: window) : nil
        Task { [weak self] in
            guard let self else { return }
            let attachment = await capture.stop(snapshot: poster)
            render()
            guard let attachment else { return }
            model.attach(attachment, to: model.open ?? origin)
        }
    }

    /// The scene is going away: so is a recording in progress, and its file.
    func end() {
        capture.cancel()
        render()
        window.isHidden = true
    }

    /// The control shows exactly while a recording runs or finishes.
    private func render() {
        guard let recording = capture.recording else {
            window.isHidden = true
            return
        }
        if capture.isStopping {
            control.show("Finishing recording", started: nil)
        } else {
            control.show(recording.kind == .screen ? "Recording screen" : "Recording performance", started: recording.started)
        }
        window.isHidden = false
    }
}

/// Touches that miss the stop control reach the app beneath.
private final class ControlWindow: UIWindow {
    weak var control: UIView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let control, !control.isHidden, control.frame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

private final class ControlController: UIViewController {
    let control: StopControl
    init(control: StopControl) {
        self.control = control
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.addSubview(control)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        control.place()
    }
}

/// The recording state: a glass capsule with the pulsing recording dot, what
/// is being recorded and the elapsed time, below the toolbar buttons. Tapping
/// it stops.
private final class StopControl: UIView {
    private let glass = Theme.glassSurface(cornerRadius: 22, interactive: true)
    private let capsule = LiveCapsule()
    var onTap: (() -> Void)?

    init() {
        super.init(frame: .zero)
        capsule.isUserInteractionEnabled = false
        glass.contentView.addSubview(capsule)
        addSubview(glass)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Stop recording"
        accessibilityIdentifier = "recording.stop"
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { onTap?() }

    func show(_ headline: String, started: Date?) {
        capsule.showsTime = started != nil
        capsule.configure(headline: headline, started: started, tone: .recording)
        accessibilityValue = headline
        place()
    }

    /// Centred, one toolbar row below the safe area's top edge.
    func place() {
        guard let container = superview else { return }
        let height: CGFloat = 44
        let width = capsule.preferredWidth(limit: container.bounds.width - 2 * Theme.Space.margin, height: height)
        frame = CGRect(x: ((container.bounds.width - width) / 2).rounded(), y: container.safeAreaInsets.top + height + Theme.Space.row,
                       width: width, height: height)
        glass.frame = bounds
        capsule.frame = bounds
    }
}
#endif
