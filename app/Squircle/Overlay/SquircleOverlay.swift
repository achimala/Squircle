import Combine
import UIKit

/// Entry point called from the framework's load-time constructor. The overlay
/// exists only in builds Squircle signs for your phone; an App Store build
/// carries no provisioning profile.
@_cdecl("squircle_overlay_start")
public func squircleOverlayStart() {
    let bundleID = Bundle.main.bundleIdentifier ?? ""
    guard AppConfiguration.Shared.teamID != nil, !bundleID.isEmpty, bundleID != "ai.dreamslate.Squircle" else { return }
    DispatchQueue.main.async { MainActor.assumeIsolated { OverlayHost.shared.start(bundleID: bundleID) } }
}

/// Attaches one overlay window to the host app's foreground scene.
@MainActor
final class OverlayHost {
    static let shared = OverlayHost()
    private var model: SquircleModel?
    private var window: OverlayWindow?
    private var observers: [NSObjectProtocol] = []

    func start(bundleID: String) {
        guard model == nil else { return }
        // Squircle's paired connection; without it the overlay stays off.
        guard let configuration = try? AppConfiguration.Shared.load() else { return }
        model = SquircleModel(configuration: configuration, scopeBundleID: bundleID)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { OverlayHost.shared.activate(note.object as? UIWindowScene) }
        })
        observers.append(center.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { OverlayHost.shared.model?.stopMetadataUpdates() }
        })
        activate(nil)
    }

    private func activate(_ scene: UIWindowScene?) {
        guard let model else { return }
        let scene = scene ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let scene, scene.activationState == .foregroundActive else { return }
        if window?.windowScene !== scene {
            let window = OverlayWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.backgroundColor = .clear
            window.tintColor = Theme.accent
            window.rootViewController = OverlayController(model: model)
            window.isHidden = false
            self.window = window
        }
        model.startMetadataUpdates()
        Task { await model.refresh() }
    }
}

/// Touches that miss the overlay's own controls reach the app beneath.
final class OverlayWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        return view === rootViewController?.view ? nil : view
    }
}

/// A small glass capsule in a corner showing this app's agent work. Tapping it
/// grows Squircle's own app view out of it: threads, new thread, builds and
/// the live simulator, all scoped to this app.
@MainActor
final class OverlayController: UIViewController {
    private let model: SquircleModel
    private let bubble = Theme.glassSurface(cornerRadius: 22, interactive: true)
    private let dot = UIView()
    private let icon = UIImageView(image: UIImage(systemName: "app.dashed"))
    private let text = Theme.label("", Theme.font(.footnote, 13, .semibold))
    private let panel = UIView()
    private var studio: StudioViewController?
    private let spring = SpringDriver(value: 0)
    private var subscriptions = Set<AnyCancellable>()
    /// Bubble position as its center, kept against the nearest side.
    private var anchor: CGPoint?
    private var dragOrigin = CGPoint.zero
    private weak var previousKey: UIWindow?

    init(model: SquircleModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { spring.value > 0 ? .portrait : .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        panel.clipsToBounds = true
        panel.layer.cornerCurve = .continuous
        panel.isHidden = true
        view.addSubview(panel)
        view.addSubview(bubble)
        bubble.accessibilityIdentifier = "overlay.bubble"
        bubble.isAccessibilityElement = true
        bubble.accessibilityTraits = .button
        dot.layer.cornerRadius = 4
        icon.tintColor = .label
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        text.lineBreakMode = .byTruncatingTail
        [icon, dot, text].forEach(bubble.contentView.addSubview)
        bubble.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(open)))
        bubble.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
        spring.onChange = { [weak self] _ in self?.applyProgress() }
        spring.onRest = { [weak self] value in self?.rested(at: value) }
        model.objectWillChange.receive(on: DispatchQueue.main)
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &subscriptions)
        render()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        panel.bounds = CGRect(origin: .zero, size: view.bounds.size)
        studio?.view.frame = panel.bounds
        layoutBubble()
    }

    // MARK: Status

    /// This app's threads that are running or waiting on you.
    private var active: [ChatSession] {
        guard let project = model.projects.first else { return [] }
        return model.sessions(for: project).filter { $0.phase != .idle }
    }

    private func render() {
        let active = self.active
        let waiting = active.first { $0.phase == .needsYou }
        let shown = waiting ?? active.first
        let title = shown.flatMap { session in model.projects.first.map { session.displayTitle(in: $0) } }
        let label = title.map { active.count > 1 ? "\($0) +\(active.count - 1)" : $0 }
        if text.text != label {
            text.text = label
            layoutBubble()
        }
        dot.isHidden = shown == nil
        dot.backgroundColor = waiting != nil ? Theme.warning : Theme.accent
        if shown != nil, waiting == nil, dot.layer.animation(forKey: "pulse") == nil, !Motion.reduced {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1; pulse.toValue = 0.3
            pulse.duration = 0.9; pulse.autoreverses = true; pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.layer.add(pulse, forKey: "pulse")
        } else if shown == nil || waiting != nil {
            dot.layer.removeAnimation(forKey: "pulse")
        }
        icon.tintColor = model.configuration == nil ? .tertiaryLabel : .label
        bubble.accessibilityLabel = "Squircle"
        bubble.accessibilityValue = label ?? (model.connected ? "Idle" : model.status)
    }

    private var bubbleSize: CGSize {
        guard let label = text.text, !label.isEmpty else { return CGSize(width: 44, height: 44) }
        let width = min(view.bounds.width * 0.6, 60 + ceil(text.intrinsicContentSize.width))
        return CGSize(width: width, height: 44)
    }

    private func layoutBubble() {
        let size = bubbleSize
        let safe = view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: 10, dy: 6)
        guard safe.width > size.width else { return }
        var center = anchor ?? CGPoint(x: safe.maxX - size.width / 2, y: safe.maxY - 90)
        // Keep to whichever side it was left on, fully on screen.
        center.x = center.x < view.bounds.midX ? safe.minX + size.width / 2 : safe.maxX - size.width / 2
        center.y = center.y.clamped(safe.minY + size.height / 2, safe.maxY - size.height / 2)
        anchor = center
        bubble.bounds = CGRect(origin: .zero, size: size)
        bubble.center = center
        icon.frame = CGRect(x: 11, y: 11, width: 22, height: 22)
        dot.frame = CGRect(x: 30, y: 8, width: 8, height: 8)
        text.frame = CGRect(x: 42, y: 0, width: max(0, size.width - 54), height: size.height)
        text.isHidden = size.width <= 44
        if spring.value > 0 { applyProgress() }
    }

    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began: dragOrigin = bubble.center
        case .changed:
            let t = gesture.translation(in: view)
            bubble.center = CGPoint(x: dragOrigin.x + t.x, y: dragOrigin.y + t.y)
        case .ended, .cancelled:
            let v = gesture.velocity(in: view)
            anchor = CGPoint(x: bubble.center.x + v.x * 0.15, y: bubble.center.y + v.y * 0.15)
            UIView.animate(springDuration: 0.45, bounce: 0.2, initialSpringVelocity: 0, delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) { self.layoutBubble() }
        default: break
        }
    }

    // MARK: Expand

    @objc private func open() {
        Theme.openHaptic()
        if studio == nil {
            let studio = StudioViewController(model: model)
            studio.onClose = { [weak self] in self?.close() }
            addChild(studio)
            studio.view.frame = panel.bounds
            panel.addSubview(studio.view)
            studio.didMove(toParent: self)
            self.studio = studio
        }
        panel.isHidden = false
        previousKey = view.window?.windowScene?.keyWindow
        view.window?.makeKey()
        setNeedsUpdateOfSupportedInterfaceOrientations()
        spring.animate(to: 1)
    }

    private func close() {
        view.endEditing(true)
        spring.animate(to: 0)
    }

    private func rested(at value: CGFloat) {
        guard value <= 0 else { return }
        panel.isHidden = true
        previousKey?.makeKey()
        setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    /// The panel grows out of the bubble and shrinks back into it.
    private func applyProgress() {
        let p = spring.value
        let bounds = view.bounds
        let from = bubble.frame
        let scale = CGFloat.lerp(from.width / max(1, bounds.width), 1, p)
        panel.center = CGPoint(x: .lerp(from.midX, bounds.midX, p), y: .lerp(from.midY, bounds.midY, p))
        panel.transform = CGAffineTransform(scaleX: scale, y: .lerp(from.height / max(1, bounds.height), 1, p))
        panel.layer.cornerRadius = .lerp(22 / max(0.001, scale), 0, p)
        panel.alpha = (p * 2.5).clamped()
        bubble.alpha = (1 - p * 2.5).clamped()
        bubble.isUserInteractionEnabled = p < 0.5
        panel.isUserInteractionEnabled = p > 0.5
    }
}
