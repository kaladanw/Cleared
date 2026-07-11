import SwiftUI

/// The host app is deliberately a shell (see claude.mds/phase-3.md): it explains
/// the share-sheet flow and shows config state. All real interaction happens in
/// the ClearedShare extension.
@main
struct ClearedApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}

struct HomeView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("How to use Cleared") {
                    Label("Screenshot a Depop listing", systemImage: "camera.viewfinder")
                    Label("Share the screenshot(s)", systemImage: "square.and.arrow.up")
                    Label("Pick Cleared in the share sheet", systemImage: "checkmark.seal")
                }
                Section("Backend") {
                    if ClearedConfig.isConfigured {
                        Label(
                            ClearedConfig.backendURL?.host() ?? "configured",
                            systemImage: "network"
                        )
                    } else {
                        Label(
                            "Not configured — fill in ios/Secrets.xcconfig and rebuild",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Cleared")
        }
    }
}

#Preview {
    HomeView()
}
