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
    private let crash: any CrashReporting
    private let defaults: UserDefaults
    private var sentLaunchFor: String?
    private var savedOrigin = ""
    private var savedToken = ""
    private var savedBuildID = ""

    init(defaults: UserDefaults = .standard, embeddedBuildID: String? = nil,
         queueFile: URL? = nil, crash: (any CrashReporting)? = nil,
         readToken: () throws -> String = TokenStore.read) {
        self.defaults = defaults
        self.crash = crash ?? CrashCapture()
        serverOrigin = defaults.string(forKey: "serverOrigin") ?? ""
        let embedded = embeddedBuildID ?? Bundle.main.object(forInfoDictionaryKey: "SquircleBuildID") as? String ?? ""
        buildID = embedded.isEmpty ? defaults.string(forKey: "buildID") ?? "" : embedded
        do {
            let file: URL
            if let queueFile {
                file = queueFile
            } else {
                let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                file = folder.appendingPathComponent("SquircleProbe/events.json")
            }
            queue = try PersistentEventQueue(file: file)
            savedBuildID = buildID.trimmingCharacters(in: .whitespacesAndNewlines)
            // Recovery precedes capture; neither depends on credentials, HTTPS
            // setup, or Keychain availability.
            if savedBuildID.isEmpty { prepareCrashCapture() } else { saveBuildIdentity() }
        } catch { status = error.localizedDescription }
        do {
            token = try readToken()
            if !serverOrigin.isEmpty && !token.isEmpty && !buildID.isEmpty { saveConfiguration() }
        } catch { status = error.localizedDescription }
    }

    func saveBuildIdentity() {
        do {
            guard queue != nil else { throw ProbeError("Queue unavailable; no events will be discarded.") }
            let cleanID = buildID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanID.isEmpty else { throw ProbeError("Enter the build ID before enabling capture.") }
            savedBuildID = cleanID
            defaults.set(cleanID, forKey: "buildID")
            prepareCrashCapture()
            if sentLaunchFor != cleanID {
                try enqueue(.launch, message: "Squircle Probe launched")
                sentLaunchFor = cleanID
            }
            status = "Build identity saved. Events remain on device until the connection is configured."
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
            defaults.set(savedOrigin, forKey: "serverOrigin")
            saveBuildIdentity()
            status = "Configuration saved. Token is in Keychain."
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
        prepareCrashCapture()
        guard !savedToken.isEmpty, !savedBuildID.isEmpty else { status = "Save a diagnostics connection before uploading."; return }
        sending = true
        defer { sending = false; refresh() }
        do {
            let endpoint = try DiagnosticsTransport.endpoint(savedOrigin)
            let credential = savedToken
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
        guard let queue, !savedBuildID.isEmpty else { throw ProbeError("Save the build ID first.") }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        try queue.append(DiagnosticEvent(buildID: savedBuildID, kind: kind, message: message,
                                         attributes: ["bundle_id": Bundle.main.bundleIdentifier ?? "", "app_version": version]))
        status = "Event saved on device."
        refresh()
    }

    private func prepareCrashCapture() {
        guard let queue else { return }
        do {
            let recovered = try crash.recover(into: queue)
            let identity = savedBuildID
            guard !identity.isEmpty else {
                crashStatus = recovered ? "Previous crash queued. Enter a build ID to enable capture." : "Enter a build ID to enable crash capture."
                canCrash = false
                refresh()
                return
            }
            try crash.enable(buildID: identity)
            canCrash = true
            crashStatus = recovered ? "Previous crash queued. PLCrashReporter ready." : "PLCrashReporter ready"
        } catch {
            canCrash = false
            crashStatus = error.localizedDescription
        }
        refresh()
    }

    private func refresh() { pending = queue?.events ?? [] }
}
