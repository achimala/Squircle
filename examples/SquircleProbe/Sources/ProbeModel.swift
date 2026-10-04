import Combine
import Darwin
import Foundation

@MainActor
final class ProbeModel: ObservableObject {
    @Published var serverOrigin: String
    @Published var token = ""
    @Published var buildID: String
    @Published var logMessage = "Hello from Squircle Probe"
    @Published private(set) var status = "Configure the diagnostics connection."
    @Published private(set) var crashStatus = "Not enabled"
    @Published private(set) var pending: [DiagnosticEvent] = []
    @Published private(set) var sending = false
    @Published private(set) var uploaded = 0
    @Published private(set) var canCrash = false

    private var queue: PersistentEventQueue?
    private let transport = DiagnosticsTransport()
    private let crash = CrashCapture()
    private var sentLaunchFor: String?
    private var savedOrigin = ""
    private var savedToken = ""
    private var savedBuildID = ""

    init() {
        let defaults = UserDefaults.standard
        serverOrigin = defaults.string(forKey: "serverOrigin") ?? ""
        let embedded = Bundle.main.object(forInfoDictionaryKey: "SquircleBuildID") as? String ?? ""
        buildID = embedded.isEmpty ? defaults.string(forKey: "buildID") ?? "" : embedded
        do {
            token = try TokenStore.read()
            let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            queue = try PersistentEventQueue(file: folder.appendingPathComponent("SquircleProbe/events.json"))
            recoverCrash()
            refresh()
            if !serverOrigin.isEmpty && !token.isEmpty && !buildID.isEmpty { saveConfiguration() }
        } catch { status = error.localizedDescription }
    }

    func saveConfiguration() {
        do {
            _ = try DiagnosticsTransport.endpoint(serverOrigin)
            let cleanID = buildID.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanID.isEmpty, !cleanToken.isEmpty, !cleanToken.contains("\n"), !cleanToken.contains("\r") else {
                throw ProbeError("Build ID and a diagnostic bearer token are required.")
            }
            guard queue != nil else { throw ProbeError("Queue unavailable; no events will be discarded.") }
            try TokenStore.write(cleanToken)
            savedOrigin = serverOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
            savedToken = cleanToken
            savedBuildID = cleanID
            UserDefaults.standard.set(savedOrigin, forKey: "serverOrigin")
            UserDefaults.standard.set(savedBuildID, forKey: "buildID")
            recoverCrash()
            do {
                try crash.enable(buildID: savedBuildID)
                canCrash = true
                crashStatus = "PLCrashReporter ready"
            } catch {
                canCrash = false
                crashStatus = error.localizedDescription
            }
            status = "Configuration saved. Token is in Keychain."
            if sentLaunchFor != savedBuildID {
                try enqueue(.launch, message: "Squircle Probe launched")
                sentLaunchFor = savedBuildID
            }
            Task { await retry() }
        } catch { status = error.localizedDescription }
    }

    func sendLog() {
        do {
            guard !logMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProbeError("Enter a log message.") }
            try enqueue(.log, message: logMessage)
            Task { await retry() }
        } catch { status = error.localizedDescription }
    }

    func foreground() { Task { await retry() } }

    func retry() async {
        guard !sending, let queue else { return }
        guard !savedToken.isEmpty, !savedBuildID.isEmpty else { status = "Save a diagnostics connection before uploading."; return }
        sending = true
        defer { sending = false; refresh() }
        do {
            let endpoint = try DiagnosticsTransport.endpoint(savedOrigin)
            let credential = savedToken
            recoverCrash()
            while let event = queue.events.first {
                try await transport.send(event, to: endpoint, token: credential)
                try queue.acknowledge(event.id)
                uploaded += 1
                refresh()
            }
            status = "Server acknowledged all queued events."
        } catch { status = error.localizedDescription }
    }

    func deliberateCrash() {
        guard canCrash else { return }
        // PLCrashReporter owns signal handling and writes the report before termination.
        abort()
    }

    private func enqueue(_ kind: DiagnosticEvent.Kind, message: String) throws {
        guard let queue, !savedBuildID.isEmpty else { throw ProbeError("Save the build ID and connection first.") }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        try queue.append(DiagnosticEvent(buildID: savedBuildID, kind: kind, message: message,
                                         attributes: ["bundle_id": Bundle.main.bundleIdentifier ?? "", "app_version": version]))
        status = "Event saved on device."
        refresh()
    }

    private func recoverCrash() {
        guard let queue else { return }
        do {
            if try crash.recover(into: queue) { crashStatus = "Previous crash recovered into upload queue." }
        } catch { crashStatus = error.localizedDescription }
        refresh()
    }

    private func refresh() { pending = queue?.events ?? [] }
}
