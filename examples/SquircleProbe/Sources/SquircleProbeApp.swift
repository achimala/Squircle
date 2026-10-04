import SwiftUI

@main
struct SquircleProbeApp: App {
    @StateObject private var model = ProbeModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ProbeView(model: model)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.foreground() }
                }
        }
    }
}

struct ProbeView: View {
    @ObservedObject var model: ProbeModel
    @State private var confirmCrash = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Build → install → report", systemImage: "square.stack.3d.up.fill")
                        .font(.headline)
                    Text("A small probe for your remote iOS development loop.")
                        .foregroundStyle(.secondary)
                }
                Section("Build identity") {
                    TextField("Build ID from Squircle", text: $model.buildID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("buildID")
                    Button("Save build ID & enable capture", action: model.saveBuildIdentity)
                        .disabled(model.sending)
                    Text("Capture starts automatically when this build embeds its ID. Upload settings can be added later.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Diagnostics connection") {
                    TextField("HTTPS server origin", text: $model.serverOrigin)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("serverOrigin")
                    SecureField("Diagnostic token (not agent key)", text: $model.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("diagnosticToken")
                    Button("Save & report launch", action: model.saveConfiguration)
                        .disabled(model.sending)
                }
                Section("Live diagnostics") {
                    TextField("Log message", text: $model.logMessage, axis: .vertical)
                        .accessibilityIdentifier("logMessage")
                    Button("Send log", action: model.sendLog)
                    Button("Retry queued events") { Task { await model.retry() } }
                        .disabled(model.sending)
                    LabeledContent("Queued", value: "\(model.pending.count)")
                    LabeledContent("Acknowledged this session", value: "\(model.uploaded)")
                    if model.sending { ProgressView("Uploading…") }
                    Text(model.status).font(.footnote).textSelection(.enabled)
                        .accessibilityIdentifier("uploadStatus")
                }
                Section("Crash recovery") {
                    Text(model.crashStatus).font(.footnote)
                    Button("Crash this probe", role: .destructive) { confirmCrash = true }
                        .disabled(!model.canCrash || model.sending)
                    Text("Open the app again manually after the crash. The saved report uploads on relaunch; stop the debugger first.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !model.pending.isEmpty {
                    Section("Waiting for acknowledgement") {
                        ForEach(model.pending) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.kind.rawValue.capitalized).font(.headline)
                                Text(event.buildID).font(.caption.monospaced())
                                Text(event.message).lineLimit(2).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Squircle Probe")
            .confirmationDialog("Crash Squircle Probe now?", isPresented: $confirmCrash, titleVisibility: .visible) {
                Button("Crash now", role: .destructive, action: model.deliberateCrash)
            } message: {
                Text("This intentionally terminates only this app. Relaunch it to recover the crash report.")
            }
        }
    }
}
