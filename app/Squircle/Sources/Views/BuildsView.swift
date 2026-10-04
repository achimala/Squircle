import SwiftUI

struct BuildsView: View {
    @ObservedObject var model: SquircleModel
    @Environment(\.openURL) private var openURL
    @State private var installingID: String?
    @State private var installError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    header
                    if !model.isConfigured {
                        ConnectionUnavailableView().padding(.top, 65)
                    } else if model.builds.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 30, weight: .light)).foregroundStyle(SquircleStyle.accent)
                                .padding(.bottom, 5)
                            Text("From an idea to your iPhone.")
                                .font(.system(size: 24, weight: .medium, design: .rounded))
                            Text("Ask Hermes to build your app. Its progress and install link will appear here.")
                                .font(.system(size: 15)).lineSpacing(5).foregroundStyle(SquircleStyle.secondary)
                        }
                        .padding(25).frame(maxWidth: .infinity, alignment: .leading)
                        .background(SquircleStyle.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    } else {
                        VStack(spacing: 14) {
                            ForEach(model.builds) { build in
                                buildCard(build)
                            }
                        }
                    }
                    if let error = model.error {
                        Text(error).font(.system(size: 12)).foregroundStyle(SquircleStyle.secondary)
                    }
                }
                .padding(.horizontal, 24).padding(.top, 25).padding(.bottom, 30)
            }
            .refreshable { await model.refresh() }
            .background(SquircleStyle.background)
            .toolbar(.hidden, for: .navigationBar)
            .alert("Could not open installation", isPresented: Binding(get: { installError != nil }, set: { if !$0 { installError = nil } })) {
                Button("OK") { installError = nil }
            } message: { Text(installError ?? "") }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Eyebrow(text: "Made on your Mac")
                Spacer()
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 16)).frame(width: 32, height: 32)
                }.disabled(model.isLoading).accessibilityLabel("Refresh builds")
            }
            Text("Builds").font(.system(size: 38, weight: .medium, design: .rounded)).tracking(-1.1)
            Text("The things you're making, ready for a closer look.")
                .font(.system(size: 14)).lineSpacing(4).foregroundStyle(SquircleStyle.secondary)
        }.padding(.bottom, 5)
    }

    private func buildCard(_ build: AppBuild) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SquircleStyle.raised)
                    Image(systemName: "app.dashed").font(.system(size: 26, weight: .light)).foregroundStyle(SquircleStyle.accent)
                }.frame(width: 55, height: 55)
                VStack(alignment: .leading, spacing: 7) {
                    Text(build.title).font(.system(size: 19, weight: .semibold, design: .rounded)).lineLimit(2)
                    Text(build.version.isEmpty ? "Development build" : build.version)
                        .font(.system(size: 12)).foregroundStyle(SquircleStyle.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 7) {
                Circle().fill(build.canInstall ? SquircleStyle.green : SquircleStyle.accent).frame(width: 5, height: 5)
                Text(build.canInstall ? "READY TO INSTALL" : build.status.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1)
                    .foregroundStyle(build.canInstall ? SquircleStyle.green : SquircleStyle.secondary)
                Spacer()
                Text(build.date, style: .relative).font(.system(size: 11)).foregroundStyle(SquircleStyle.secondary)
            }
            if build.canInstall {
                Button {
                    installingID = build.id
                    Task {
                        if let url = await model.installURL(for: build) {
                            openURL(url) { accepted in
                                if !accepted { installError = "iOS could not open the installation link. Try again from this build." }
                            }
                        }
                        installingID = nil
                    }
                } label: {
                    HStack(spacing: 8) {
                        if installingID == build.id { ProgressView().tint(SquircleStyle.background) }
                        else { Image(systemName: "arrow.down.to.line").font(.system(size: 13, weight: .semibold)) }
                        Text("Install on iPhone").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(SquircleStyle.background).padding(.horizontal, 16).padding(.vertical, 14)
                    .background(SquircleStyle.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }.disabled(installingID != nil)
            }
        }
        .padding(20)
        .background(SquircleStyle.surface, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 25, style: .continuous).stroke(SquircleStyle.line))
    }
}
