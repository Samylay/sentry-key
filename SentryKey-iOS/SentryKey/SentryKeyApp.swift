import SwiftUI

@main
struct SentryKeyApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // Hides fingerprints and server names from the app switcher
                // snapshot (CLAUDE.md, data protection).
                .overlay {
                    if scenePhase != .active {
                        PrivacyCover()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.reloadIfNeeded() }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .onboarding:
                // Welcome pushes Pairing, so Back works until pairing ends.
                NavigationStack { WelcomeView() }
            case .paired:
                // A one-way door: once paired, onboarding is gone.
                HomeView()
            }
        }
        .animation(.default, value: model.phase)
        .sheet(item: $model.pending) { request in
            ApprovalView(request: request)
                // Swiping down must not leave a request hanging: the user
                // picks Deny or Approve, or the request times out.
                .interactiveDismissDisabled()
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            Image(systemName: "key.viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
        }
        .ignoresSafeArea()
    }
}
