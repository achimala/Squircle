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

    /// What the phone shows, as the Mac should know it: the scene's state
    /// and, while it is active, the conversation navigation reports.
    enum Presence: Equatable {
        case background
        case foreground(thread: String?)
    }
    /// The conversation on screen, if any, as StudioViewController reports it.
    private var visibleThread: String? { didSet { if visibleThread != oldValue { presenceChanged() } } }
    private var sceneActive = false { didSet { if sceneActive != oldValue { presenceChanged() } } }
    var presence: Presence { sceneActive ? .foreground(thread: visibleThread) : .background }
    /// Reports go out one at a time, newest last, so an older one never lands
    /// after a newer one.
    private let presenceReports = AsyncStream.makeStream(of: Presence.self, bufferingPolicy: .bufferingNewest(1))
    /// Repeats the report while in the foreground: the Mac forgets one after
    /// five minutes, so a phone that died with Squircle open doesn't silence
    /// that thread forever.
    private var presenceLease: Task<Void, Never>?

    private struct Tokens: Equatable {
        var device: String?
        var start: String?
    }
    /// This phone's push tokens and whether the Mac has them.
    private enum Registration {
        case unsent
        case sending(Tokens)
        case acknowledged(Tokens)
    }
    private var tokens = Tokens()
    private var registration = Registration.unsent
    private var watched = Set<String>()
    private var started = false
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
        Task { [weak self, reports = presenceReports.stream] in
            for await presence in reports { await self?.send(presence) }
        }
        Task { [weak self] in
            for await data in Agent.pushToStartTokenUpdates {
                self?.tokens.start = data.hex
                await self?.register()
            }
        }
        Task { [weak self] in
            for await activity in Agent.activityUpdates {
                self?.watch(activity, fresh: true)
            }
        }
        for activity in Agent.activities { watch(activity, fresh: false) }
        presenceReports.continuation.yield(presence)
    }

    func registered(deviceToken data: Data) {
        tokens.device = data.hex
        Task { await register() }
    }

    /// Sends tokens the Mac doesn't have yet; `again` sends them anyway, as
    /// whenever Squircle comes back, in case the Mac was unreachable or
    /// restarted with a new data directory.
    private func register(again: Bool = false) async {
        guard let service = model?.service, tokens != Tokens() else { return }
        let tokens = tokens
        switch registration {
        case .sending(let sent) where sent == tokens: return
        case .acknowledged(let sent) where sent == tokens && !again: return
        default: break
        }
        var body: [String: Any] = ["device_id": deviceID, "bundle_id": Bundle.main.bundleIdentifier ?? "",
                                   "environment": Self.environment]
        if let token = tokens.device { body["token"] = token }
        if let token = tokens.start { body["start_token"] = token }
        registration = .sending(tokens)
        do {
            try await service.push("devices", body)
            if case .sending(let sent) = registration, sent == tokens { registration = .acknowledged(tokens) }
            for activity in Agent.activities { if let token = activity.pushToken { await report(activity, token: token.hex) } }
        } catch {
            if case .sending(let sent) = registration, sent == tokens { registration = .unsent }
            log("register failed: \(error.localizedDescription)")
        }
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
        visibleThread = thread
    }

    func becameActive() {
        sceneActive = true
        Task { await register(again: true) }
    }

    func resignedActive() {
        sceneActive = false
        startActivitiesForWork()
    }

    private func presenceChanged() {
        presenceReports.continuation.yield(presence)
        presenceLease?.cancel()
        presenceLease = nil
        guard case .foreground = presence else { return }
        presenceLease = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(240))
                guard !Task.isCancelled, let self else { return }
                presenceReports.continuation.yield(presence)
            }
        }
    }

    private func send(_ presence: Presence) async {
        guard let service = model?.service else { return }
        var body: [String: Any] = ["device_id": deviceID, "foreground": false]
        if case .foreground(let thread) = presence {
            body["foreground"] = true
            if let thread { body["thread_id"] = thread }
        }
        do { try await service.push("presence", body) }
        catch { log("presence report failed: \(error.localizedDescription)") }
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
        let shown = await MainActor.run { thread != nil && presence == .foreground(thread: thread) }
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
