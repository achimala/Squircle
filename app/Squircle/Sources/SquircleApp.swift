import UIKit

@main
final class SquircleApp: UIResponder, UIApplicationDelegate {
    /// Process-relative start, for DEBUG launch instrumentation only.
    static let launchedAt = CACurrentMediaTime()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = Self.launchedAt
        PushCenter.shared.install()
        MediaAudio.install()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushCenter.shared.registered(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        #if DEBUG
        NSLog("SQUIRCLE-PUSH no device token: %@", error.localizedDescription)
        #endif
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
    /// Recordings of Squircle itself, from the message field's + menu.
    private(set) var recording: SelfRecording?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.backgroundColor = Theme.paper
        window.tintColor = Theme.accent
        let studio = StudioViewController(model: model)
        window.rootViewController = studio
        window.makeKeyAndVisible()
        self.window = window
        recording = SelfRecording(scene: scene, model: model)
        Task { await model.refresh() }
        let push = PushCenter.shared
        studio.onViewing = { push.viewing($0) }
        push.onOpen = { [weak studio] in studio?.open($0) }
        push.start(model: model)
        if let url = options.urlContexts.first?.url, let target = PushTarget(url: url) { push.open(target) }
        #if DEBUG
        // Verification only: the debug overlay over Squircle, scoped to the
        // app with this bundle ID, since it can't run injected in a simulator.
        if let bundleID = ProcessInfo.processInfo.environment["SQUIRCLE_OVERLAY_DEMO"], let configuration = model.configuration {
            Task { @MainActor in OverlayHost.shared.start(bundleID: bundleID, configuration: configuration) }
        }
        if let kind = ProcessInfo.processInfo.environment["SQUIRCLE_DEMO_ACTIVITY"] { push.demoActivity(kind) }
        // Verification only: `SQUIRCLE_JANK=1` blocks the main thread for
        // 250 ms every 1.5 s, so a performance recording has hitches to find.
        if ProcessInfo.processInfo.environment["SQUIRCLE_JANK"] == "1" {
            Task { @MainActor in
                while true {
                    try? await Task.sleep(for: .seconds(1.5))
                    Self.deliberateJank()
                }
            }
        }
        // Verification only: the notice shown once an update of this app is confirmed.
        if ProcessInfo.processInfo.environment["SQUIRCLE_DEMO_UPDATE"] == "1",
           let data = #"{"id":"demo","state":"succeeded","created_at":0,"output":{"version":"0.3.0","build_number":"26","ipa_path":"/x.ipa"}}"#.data(using: .utf8),
           let build = try? JSONDecoder().decode(AppBuild.self, from: data) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                UpdateCurtain.show(in: window, build: build) {}
            }
        }
        #endif
    }

    #if DEBUG
    @inline(never) private static func deliberateJank() {
        let end = CACurrentMediaTime() + 0.25
        var x = 0.0
        while CACurrentMediaTime() < end { x += sin(x + 1) }
        if x.isNaN { print(x) }
    }
    #endif

    func sceneDidBecomeActive(_ scene: UIScene) {
        model.startMetadataUpdates()
        Task { await model.refresh() }
        PushCenter.shared.becameActive()
    }
    func sceneWillResignActive(_ scene: UIScene) {
        model.stopMetadataUpdates()
        PushCenter.shared.resignedActive()
    }
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        if let url = contexts.first?.url, let target = PushTarget(url: url) { PushCenter.shared.open(target) }
    }
    func sceneDidEnterBackground(_ scene: UIScene) { model.enteredBackground() }
    /// The scene is gone for good: so is everything its model started.
    func sceneDidDisconnect(_ scene: UIScene) {
        recording?.end()
        model.close()
    }
    func sceneWillEnterForeground(_ scene: UIScene) { model.enteringForeground() }
}
