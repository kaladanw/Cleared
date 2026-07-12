import SwiftUI

/// The host app is deliberately a shell (see mds/phase-3.md): it explains
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
    @State private var lastReport: CheckReport?

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
                if let lastReport {
                    Section("Recent") {
                        NavigationLink {
                            if let error = lastReport.error {
                                ContentUnavailableView(
                                    "Check unavailable",
                                    systemImage: "exclamationmark.triangle",
                                    description: Text(error)
                                )
                            } else {
                                CareLabelView(report: lastReport)
                                    .navigationTitle("Last check")
                                    .navigationBarTitleDisplayMode(.inline)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(lastReport.verdict.recommendation?.rawValue.capitalized ?? "Last check")
                                    .font(.headline)
                                Text(lastReport.verdict.oneLine)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Cleared")
            .onAppear { lastReport = LastReportStore.load() }
        }
    }
}

#Preview {
    HomeView()
}
