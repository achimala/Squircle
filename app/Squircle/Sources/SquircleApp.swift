import SwiftUI

@main
struct SquircleApp: App {
    @StateObject private var model = SquircleModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            SquircleRootView(model: model)
                .preferredColorScheme(.dark)
                .tint(SquircleStyle.accent)
                .task { await model.refresh() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.refresh() } }
                }
        }
    }
}

struct SquircleRootView: View {
    @ObservedObject var model: SquircleModel

    var body: some View {
        TabView {
            ChatView(model: model)
                .tabItem { Label("Hermes", systemImage: "bubble.left.and.text.bubble.right") }
            BuildsView(model: model)
                .tabItem { Label("Builds", systemImage: "square.stack.3d.up") }
        }
        .toolbarBackground(SquircleStyle.background, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .foregroundStyle(SquircleStyle.foreground)
    }
}
