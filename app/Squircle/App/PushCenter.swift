import ActivityKit
import UIKit
import UserNotifications

/// Notifications and Live Activities in Squircle itself (never in the debug
/// overlay). Gives the Mac this phone's push tokens and what it is showing;
/// the Mac decides what to send. Taps open their target.
@MainActor
final class PushCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushCenter()
    typealias Agent = Activity<SquircleActivityAttributes>

    private weak var model: SquircleModel?
    /// Opens a tapped notification's target; one tapped before the window
    /// exists waits for it.
    var onOpen: ((PushTarget) -> Void)? { didSet { if let pendingOpen, let onOpen { self.pendingOpen = nil; onOpen(pendingOpen) } } }
    private var pendingOpen: PushTarget?
    /// The conversation on screen, if any, as StudioViewController reports it.
    private(set) var visibleThread: String?
    private var foreground = false
    private var deviceToken: String?
    private var startToken: String?
    private var watched = Set<String>()
    private var started = false
    private var presenceLoop: Task<Void, Never>?
    private let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"

    /// Before launch finishes, so a tap that launched the app is delivered.
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    func start(model: SquircleModel) {
        self.model = model
        guard !started else { return }
        started = true
        #if DEBUG
        let demo = ProcessInfo.processInfo.environment["SQUIRCLE_DEMO_ACTIVITY"] != nil
        #else
        let demo = false
        #endif
        if !demo { Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            UIApplication.shared.registerForRemoteNotifications()
        } }
        Task { [weak self] in
            for await data in Agent.pushToStartTokenUpdates {
                self?.startToken = data.hex
                await self?.register()
            }
        }
        Task { [weak self] in
            for await activity in Agent.activityUpdates {
                self?.watch(activity, fresh: true)
            }
        }
        for activity in Agent.activities { watch(activity, fresh: false) }
    }

    func registered(deviceToken data: Data) {
        deviceToken = data.hex
        Task { await register() }
    }

    /// The Mac learns this phone's tokens again whenever Squircle comes back,
    /// in case it was unreachable or restarted with a new data directory.
    private func register() async {
        guard let service = model?.service else { return }
        var body: [String: Any] = ["device_id": deviceID, "bundle_id": Bundle.main.bundleIdentifier ?? "",
                                   "environment": Self.environment]
        if let deviceToken { body["token"] = deviceToken }
        if let startToken { body["start_token"] = startToken }
        guard deviceToken != nil || startToken != nil else { return }
        do {
            try await service.push("devices", body)
            for activity in Agent.activities { if let token = activity.pushToken { await report(activity, token: token.hex) } }
        } catch { log("register failed: \(error.localizedDescription)") }
    }

    private func watch(_ activity: Agent, fresh: Bool) {
        guard watched.insert(activity.id).inserted else { return }
        let project = activity.attributes.projectID
        if fresh {
            // One per app: a push-to-start racing a local start keeps the newest.
            for other in Agent.activities where other.id != activity.id && other.attributes.projectID == project {
                Task { await other.end(nil, dismissalPolicy: .immediate) }
            }
        }
        Task { [weak self] in
            for await token in activity.pushTokenUpdates { await self?.report(activity, token: token.hex) }
        }
        Task { [weak self] in
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                await self?.report(activity, token: nil)
                self?.watched.remove(activity.id)
                break
            }
        }
    }

    private func report(_ activity: Agent, token: String?) async {
        guard let service = model?.service else { return }
        var body: [String: Any] = ["device_id": deviceID, "project_id": activity.attributes.projectID, "activity_id": activity.id]
        if let token { body["token"] = token }
        do { try await service.push("activities", body) }
        catch { log("activity report failed: \(error.localizedDescription)") }
    }

    // MARK: What the phone shows

    func viewing(_ thread: String?) {
        guard thread != visibleThread else { return }
        visibleThread = thread
        reportPresence()
    }

    func becameActive() {
        foreground = true
        reportPresence()
        Task { await register() }
        presenceLoop?.cancel()
        // The Mac forgets a report after five minutes, so a phone that died
        // with Squircle open doesn't silence that thread forever.
        presenceLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(240))
                guard !Task.isCancelled else { return }
                self?.reportPresence()
            }
        }
    }

    func resignedActive() {
        foreground = false
        presenceLoop?.cancel(); presenceLoop = nil
        reportPresence()
        startActivitiesForWork()
    }

    private func reportPresence() {
        guard let service = model?.service else { return }
        var body: [String: Any] = ["device_id": deviceID, "foreground": foreground]
        if foreground, let visibleThread { body["thread_id"] = visibleThread }
        Task { try? await service.push("presence", body) }
    }

    /// Leaving with an agent at work: its Live Activity starts now (still
    /// visible, so iOS allows it); the Mac keeps it current and ends it.
    private func startActivitiesForWork() {
        guard let model, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let running = Set(Agent.activities.filter { $0.activityState == .active }.map(\.attributes.projectID))
        for project in model.projects where !running.contains(project.id) {
            guard let agent = model.agentThreadID(for: project) else { continue }
            let sessions = model.sessions(for: project, includingAgent: true)
            let needsYou = sessions.contains { $0.phase == .needsYou }
            let agentWorking = sessions.contains { $0.id == agent && $0.phase == .working }
            let workers = sessions.filter { $0.id != agent && $0.phase == .working }.count
            guard agentWorking || workers > 0 || needsYou else { continue }
            let state = SquircleActivityAttributes.ContentState(
                status: needsYou ? "Needs you" : agentWorking ? "Working" : "Waiting on workers",
                workers: workers, needsYou: needsYou, working: agentWorking || workers > 0)
            do {
                _ = try Agent.request(attributes: .init(appName: project.name, projectID: project.id),
                                      content: .init(state: state, staleDate: .now.addingTimeInterval(15 * 60)),
                                      pushType: .token)
            } catch { log("Live Activity not started: \(error.localizedDescription)") }
        }
    }

    // MARK: Notifications

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let thread = (notification.request.content.userInfo["squircle"] as? [String: Any])?["thread"] as? String
        let shown = await MainActor.run { thread != nil && thread == visibleThread }
        return shown ? [] : [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let target = PushTarget(userInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run { open(target) }
    }

    func open(_ target: PushTarget) {
        if let onOpen { onOpen(target) } else { pendingOpen = target }
    }

    #if DEBUG
    /// Verification only: `SQUIRCLE_DEMO_ACTIVITY=working|needs|done` shows a
    /// sample Live Activity, since a simulator gets no pushes from the Mac.
    func demoActivity(_ kind: String) {
        let state = SquircleActivityAttributes.ContentState(
            status: kind == "needs" ? "Should I ship build 49 to TestFlight?" : kind == "done" ? "Done" : "Edited Theme.swift",
            workers: kind == "done" ? 0 : 2, needsYou: kind == "needs", working: kind != "done")
        do {
            _ = try Agent.request(attributes: .init(appName: "Letters Abroad", projectID: "demo"),
                                  content: .init(state: state, staleDate: nil), pushType: nil)
        } catch { log("demo activity: \(error)") }
    }
    #endif

    // MARK: Environment

    /// Which APNs this build's token belongs to: the provisioning profile's
    /// `aps-environment` (ad hoc and App Store builds say production).
    /// Simulator and Xcode-run builds use the sandbox.
    static let environment: String = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let value = entitlements["aps-environment"] as? String else { return "development" }
        return value == "production" ? "production" : "development"
    }()

    private func log(_ message: String) {
        #if DEBUG
        NSLog("SQUIRCLE-PUSH %@", message)
        #endif
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
