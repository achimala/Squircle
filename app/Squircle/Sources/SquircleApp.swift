import UIKit

@main
final class SquircleApp: UIResponder, UIApplicationDelegate {
    /// Process-relative start, for DEBUG launch instrumentation only.
    static let launchedAt = CACurrentMediaTime()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = Self.launchedAt
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Studio", sessionRole: session.role)
        configuration.delegateClass = StudioScene.self
        return configuration
    }
}

final class StudioScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let model = SquircleModel()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.backgroundColor = Theme.backdropBottom
        window.tintColor = Theme.accent
        window.rootViewController = StudioViewController(model: model)
        window.makeKeyAndVisible()
        self.window = window
        Task { await model.refresh() }
        #if DEBUG
        // Verification only: the debug overlay over Squircle, scoped to the
        // app with this bundle ID, since it can't run injected in a simulator.
        if let bundleID = ProcessInfo.processInfo.environment["SQUIRCLE_OVERLAY_DEMO"], let configuration = model.configuration {
            DispatchQueue.main.async { OverlayHost.shared.start(bundleID: bundleID, configuration: configuration) }
        }
        #endif
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        model.startMetadataUpdates()
        Task { await model.refresh() }
    }
    func sceneWillResignActive(_ scene: UIScene) { model.stopMetadataUpdates() }
}
