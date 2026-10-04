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
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        model.startMetadataUpdates()
        Task { await model.refresh() }
    }
    func sceneWillResignActive(_ scene: UIScene) { model.stopMetadataUpdates() }
}
