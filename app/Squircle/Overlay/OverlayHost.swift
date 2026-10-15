#if SQUIRCLE_OVERLAY || DEBUG
import UIKit

/// Entry point called from the framework's load-time constructor. The overlay
/// exists only in builds Squircle signs for your phone; an App Store build
/// carries no provisioning profile.
@_cdecl("squircle_overlay_start")
public func squircleOverlayStart() {
    let bundleID = Bundle.main.bundleIdentifier ?? ""
    guard AppConfiguration.Shared.teamID != nil, !bundleID.isEmpty, bundleID != "ai.dreamslate.Squircle" else { return }
    // Squircle's paired connection; without it the overlay stays off.
    guard let configuration = try? AppConfiguration.Shared.load() else { return }
    Task { @MainActor in OverlayHost.shared.start(bundleID: bundleID, configuration: configuration) }
}

/// Attaches one overlay window to the host app's foreground scene. The
/// model outlives scenes; everything tied to a scene (its window, the
/// conversations, the work started there) is that scene's lease, and only
/// the leased scene's lifecycle reaches the model.
@MainActor
final class OverlayHost {
    static let shared = OverlayHost()
    @MainActor
    private enum State {
        case unconfigured
        /// Configured, with no foreground scene to show on.
        case detached(SquircleModel)
        case attached(SceneLease)

        var model: SquircleModel? {
            switch self {
            case .unconfigured: nil
            case .detached(let model): model
            case .attached(let lease): lease.model
            }
        }
        func owns(_ scene: UIScene?) -> SceneLease? {
            guard case .attached(let lease) = self, let scene, lease.scene === scene else { return nil }
            return lease
        }
    }
    private var state = State.unconfigured
    private var observers: [NSObjectProtocol] = []

    func start(bundleID: String, configuration: AppConfiguration) {
        guard case .unconfigured = state else { return }
        state = .detached(SquircleModel(configuration: configuration, scopeBundleID: bundleID))
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ action: @escaping @MainActor (OverlayHost, UIScene?) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let scene = note.object as? UIScene
                MainActor.assumeIsolated { action(OverlayHost.shared, scene) }
            })
        }
        on(UIScene.didActivateNotification) { host, scene in host.activate(scene as? UIWindowScene) }
        on(UIScene.didDisconnectNotification) { host, scene in host.disconnected(scene) }
        on(UIScene.willDeactivateNotification) { host, scene in host.state.owns(scene)?.model.stopMetadataUpdates() }
        // The host app's lifecycle is the overlay's: hold T3's socket in the
        // background, reconnect on return.
        on(UIScene.didEnterBackgroundNotification) { host, scene in host.state.owns(scene)?.model.enteredBackground() }
        on(UIScene.willEnterForegroundNotification) { host, scene in host.state.owns(scene)?.model.enteringForeground() }
        activate(nil)
    }

    private func activate(_ scene: UIWindowScene?) {
        guard let model = state.model else { return }
        let scene = scene ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let scene, scene.activationState == .foregroundActive else { return }
        if let lease = state.owns(scene) { return lease.activate() }
        if case .attached(let old) = state { old.end() }
        let lease = SceneLease(scene: scene, model: model)
        state = .attached(lease)
        // A scene coming in after another went away: the model may still
        // think it is in the background.
        model.enteringForeground()
        lease.activate()
    }

    private func disconnected(_ scene: UIScene?) {
        guard let lease = state.owns(scene) else { return }
        lease.end()
        state = .detached(lease.model)
    }
}

/// The overlay on one scene: its window, its controller and the work it
/// started there. Ending it takes the window down and cancels that work.
@MainActor
private final class SceneLease {
    let model: SquircleModel
    private let window: OverlayWindow
    private let controller: OverlayController
    private var refresh: Task<Void, Never>?
    weak var scene: UIWindowScene?

    init(scene: UIWindowScene, model: SquircleModel) {
        self.model = model
        self.scene = scene
        window = OverlayWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        window.tintColor = Theme.accent
        controller = OverlayController(model: model)
        window.rootViewController = controller
        window.isHidden = false
    }

    /// Its scene came to the front.
    func activate() {
        model.startMetadataUpdates()
        refresh?.cancel()
        refresh = Task { [model] in await model.refresh() }
    }

    func end() {
        refresh?.cancel()
        refresh = nil
        model.stopMetadataUpdates()
        controller.tearDown()
        window.isHidden = true
        window.rootViewController = nil
    }
}

/// Touches that miss the overlay's glass reach the app beneath.
final class OverlayWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Every touch on the screen asks this window first: the jelly
        // glances at it, in the app or on itself.
        if event?.type == .touches { (rootViewController as? OverlayController)?.noticed(point) }
        let view = super.hitTest(point, with: event)
        return view === rootViewController?.view ? nil : view
    }
}
#endif
