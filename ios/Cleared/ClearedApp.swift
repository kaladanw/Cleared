import SwiftUI

/// Host app: sign in once (the Share Extension reuses the same Keychain
/// session), and browse the account's check history. The checking itself
/// still happens in the ClearedShare extension.
@main
struct ClearedApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            switch model.authState {
            case .signedIn:
                HistoryView()
            case .signedOut:
                SignInView()
            }
        }
        .task { await model.syncHistory() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            // The extension may have refreshed, signed out, or added a check.
            model.reloadSession()
            Task { await model.syncHistory() }
        }
        .onChange(of: model.authState) { _, state in
            if case .signedIn = state {
                Task { await model.syncHistory() }
            }
        }
    }
}
