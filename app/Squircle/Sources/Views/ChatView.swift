import SwiftUI

struct ChatView: View {
    @ObservedObject var model: SquircleModel
    @State private var draft = ""
    @State private var showingSessions = false
    @FocusState private var composerFocused: Bool

    private var selectedTitle: String {
        model.sessions.first(where: { $0.id == model.selectedSessionID })?.title ?? "A place to make things"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                if !model.isConfigured {
                    ConnectionUnavailableView()
                } else {
                    conversation
                    if let error = model.error {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "wifi.exclamationmark")
                            Text(error).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button("Retry") { Task { await model.refresh() } }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(SquircleStyle.secondary)
                        .padding(.horizontal, 22).padding(.vertical, 12)
                    }
                    ForEach(model.approvals) { approval in
                        ApprovalCard(approval: approval) { allowed in
                            Task { await model.resolveApproval(approval, approved: allowed) }
                        }
                        .padding(.horizontal, 20).padding(.bottom, 12)
                    }
                    composer
                }
            }
            .background(SquircleStyle.background)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingSessions) {
                SessionPicker(model: model)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(SquircleStyle.background)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            SquircleMark()
            VStack(alignment: .leading, spacing: 4) {
                Text("Squircle").font(.system(size: 20, weight: .semibold, design: .rounded))
                HStack(spacing: 5) {
                    Circle().fill(model.connected ? SquircleStyle.green : SquircleStyle.secondary).frame(width: 4, height: 4)
                    Text(model.connected ? "Hermes · Your Mac" : "Hermes · Mac unavailable")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(SquircleStyle.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button { showingSessions = true } label: {
                Image(systemName: "rectangle.stack").font(.system(size: 18, weight: .regular)).frame(width: 38, height: 38)
            }
            .accessibilityLabel("Conversations")
            Button {
                Task { await model.createSession() }
            } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 18, weight: .regular)).frame(width: 38, height: 38)
            }
            .disabled(!model.isConfigured || model.isRunning)
            .accessibilityLabel("New conversation")
        }
        .foregroundStyle(SquircleStyle.foreground)
        .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 18)
        .overlay(alignment: .bottom) { Rectangle().fill(SquircleStyle.line).frame(height: 1).padding(.horizontal, 22) }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if model.messages.isEmpty {
                    welcome
                } else {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        HStack {
                            Eyebrow(text: selectedTitle)
                            Spacer()
                        }.padding(.top, 23)
                        ForEach(model.messages) { message in
                            MessageRow(message: message)
                        }
                        if model.isRunning && !model.messages.contains(where: \.isStreaming) {
                            HStack(spacing: 9) {
                                ProgressView().controlSize(.mini).tint(SquircleStyle.accent)
                                Text("Hermes is working").font(.system(size: 12)).foregroundStyle(SquircleStyle.secondary)
                            }
                        }
                        Color.clear.frame(height: 1).id("conversation-bottom")
                    }
                    .padding(.horizontal, 24).padding(.bottom, 20)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.messages.last?.content) { _, _ in
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
            .onChange(of: model.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow(text: "An idea is enough")
                Spacer()
                Image(systemName: "sparkle").font(.system(size: 17, weight: .light)).foregroundStyle(SquircleStyle.accent)
            }
            .padding(.bottom, 22)
            Text("What are we\nbuilding next?")
                .font(.system(size: 42, weight: .medium, design: .rounded))
                .tracking(-1.7).lineSpacing(-1)
                .foregroundStyle(SquircleStyle.foreground)
            Text("Your projects, your agents, your Mac.\nPick up a thought and take it somewhere.")
                .font(.system(size: 15)).lineSpacing(5)
                .foregroundStyle(SquircleStyle.secondary)
                .padding(.top, 18).padding(.bottom, 34)
            VStack(spacing: 10) {
                suggestion("Start something new", detail: "Turn an idea into an iOS app", icon: "plus", prompt: "I have an idea for an iOS app. Help me shape it and get started.")
                suggestion("Pick up where we left off", detail: "Find the next step in a project", icon: "arrow.turn.down.right", prompt: "Look at my active projects and help me pick up where we left off.")
            }
        }
        .padding(.horizontal, 28).padding(.top, 47).padding(.bottom, 30)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suggestion(_ title: String, detail: String, icon: String, prompt: String) -> some View {
        Button {
            draft = prompt
            composerFocused = true
        } label: {
            HStack(spacing: 13) {
                Image(systemName: icon).font(.system(size: 17, weight: .light))
                    .foregroundStyle(SquircleStyle.accent).frame(width: 25)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .medium))
                    Text(detail).font(.system(size: 12)).foregroundStyle(SquircleStyle.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(SquircleStyle.secondary)
            }
            .padding(5)
        }.buttonStyle(QuietButtonStyle())
    }

    private var composer: some View {
        VStack(spacing: 9) {
            HStack(alignment: .bottom, spacing: 12) {
                TextField("A thought, a task, an idea…", text: $draft, axis: .vertical)
                    .font(.system(size: 16)).lineLimit(1...6)
                    .focused($composerFocused)
                    .padding(.vertical, 10).padding(.leading, 5)
                    .accessibilityIdentifier("messageComposer")
                Button {
                    if model.isRunning {
                        Task { await model.stop() }
                    } else {
                        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !message.isEmpty else { return }
                        draft = ""
                        composerFocused = false
                        Task { await model.send(message) }
                    }
                } label: {
                    Image(systemName: model.isRunning ? "stop.fill" : "arrow.up")
                        .font(.system(size: model.isRunning ? 13 : 18, weight: .semibold))
                        .foregroundStyle(SquircleStyle.background)
                        .frame(width: 40, height: 40)
                        .background(SquircleStyle.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(!model.isRunning && (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isLoading))
                .opacity(!model.isRunning && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                .accessibilityLabel(model.isRunning ? "Stop response" : "Send message")
            }
            .padding(10)
            .background(SquircleStyle.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(SquircleStyle.line))
            Text(model.status)
                .font(.system(size: 10)).foregroundStyle(SquircleStyle.secondary.opacity(0.8))
                .multilineTextAlignment(.center).lineLimit(2)
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
        .background(SquircleStyle.background)
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    private var isUser: Bool { message.role == "user" }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                if !isUser { SquircleMark(size: 19) }
                Eyebrow(text: isUser ? "You" : "Hermes")
                if message.isStreaming { ProgressView().controlSize(.mini).tint(SquircleStyle.accent) }
            }
            if !message.content.isEmpty {
                Text(.init(message.content))
                    .font(.system(size: 16)).lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(message.tools.enumerated()), id: \.offset) { _, tool in
                HStack(spacing: 7) {
                    Image(systemName: "wrench.and.screwdriver").font(.system(size: 10))
                    Text(tool).lineLimit(2)
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(SquircleStyle.secondary)
                .padding(.vertical, 7).padding(.horizontal, 10)
                .background(SquircleStyle.surface, in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(isUser ? 16 : 0)
        .background(isUser ? SquircleStyle.surface : Color.clear, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct ApprovalCard: View {
    let approval: AgentApproval
    let respond: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Your approval", systemImage: "hand.raised")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(SquircleStyle.accent)
            Text(approval.prompt).font(.system(size: 14)).lineLimit(4)
            if !approval.command.isEmpty {
                ScrollView(.horizontal) {
                    Text(approval.command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
            }
            HStack {
                Button("Deny") { respond(false) }.buttonStyle(.bordered)
                Spacer()
                Button("Allow once") { respond(true) }.buttonStyle(.borderedProminent)
                    .foregroundStyle(SquircleStyle.background)
            }.controlSize(.small)
        }
        .padding(16)
        .background(SquircleStyle.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(SquircleStyle.accent.opacity(0.25)))
    }
}

private struct SessionPicker: View {
    @ObservedObject var model: SquircleModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    dismiss()
                    Task { await model.createSession() }
                } label: {
                    Label("New conversation", systemImage: "square.and.pencil").foregroundStyle(SquircleStyle.accent)
                }.disabled(model.isRunning)
                    .listRowBackground(SquircleStyle.surface)
                ForEach(model.sessions) { session in
                    Button {
                        dismiss()
                        Task { await model.selectSession(session.id) }
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(session.title).font(.system(size: 15, weight: .medium)).lineLimit(1)
                                Text(session.preview.isEmpty ? "\(session.messageCount) messages" : session.preview)
                                    .font(.system(size: 12)).foregroundStyle(SquircleStyle.secondary).lineLimit(2)
                            }
                            Spacer()
                            if model.selectedSessionID == session.id {
                                Image(systemName: "checkmark").foregroundStyle(SquircleStyle.accent)
                            }
                        }.padding(.vertical, 6)
                    }
                    .disabled(model.isRunning)
                    .listRowBackground(SquircleStyle.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(SquircleStyle.background)
            .foregroundStyle(SquircleStyle.foreground)
            .navigationTitle("Conversations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
