import SwiftUI

/// The account's checks from `GET /api/reports` (the same list as the web
/// hub), with the on-device cache shown when the server can't be reached.
struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmSignOut = false

    var body: some View {
        List {
            if let reason = model.history.staleReason {
                Section {
                    Label(reason, systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            if model.history.entries.isEmpty {
                Section {
                    if model.isSyncing {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else {
                        HowToSection()
                    }
                }
            } else {
                Section("Your checks") {
                    ForEach(model.history.entries) { entry in
                        NavigationLink {
                            HistoryDetailView(entry: entry)
                        } label: {
                            HistoryRowView(entry: entry)
                        }
                    }
                }
            }
        }
        .navigationTitle("Cleared")
        .refreshable { await model.syncHistory() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let email = model.currentUser?.email {
                        Text("Signed in as \(email)")
                    }
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                } label: {
                    Image(systemName: "person.crop.circle")
                        .accessibilityLabel("Account")
                }
            }
        }
        .confirmationDialog("Sign out of Cleared?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task { await model.signOut() }
            }
        } message: {
            Text("The share sheet will ask you to sign in again. Your checks stay saved in your account.")
        }
    }
}

private struct HistoryRowView: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                if let recommendation = entry.recommendation {
                    Text(recommendation.rawValue.capitalized)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(color(for: recommendation).opacity(0.15)))
                        .foregroundStyle(color(for: recommendation))
                }
            }
            if let oneLine = entry.report?.verdict.oneLine, !oneLine.isEmpty {
                Text(oneLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                if let date = entry.date {
                    Text(date, format: .relative(presentation: .named))
                }
                if entry.isLocalOnly {
                    Text("· On this iPhone only")
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func color(for recommendation: Recommendation) -> Color {
        switch recommendation {
        case .buy: return .green
        case .negotiate: return .orange
        case .skip: return .red
        }
    }
}

private struct HistoryDetailView: View {
    let entry: HistoryEntry

    private var listingURL: URL? {
        let raw: String?
        switch entry {
        case .server(let row): raw = row.listingURL
        case .local(let local): raw = local.listingURL
        }
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    var body: some View {
        Group {
            if let report = entry.report {
                if let error = report.error {
                    ContentUnavailableView("Check unavailable", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else {
                    CareLabelView(report: report)
                }
            } else {
                ContentUnavailableView(
                    "Can't show this check",
                    systemImage: "doc.questionmark",
                    description: Text("This report was saved in a format this version of the app can't read. Open it in the web hub, or update the app.")
                )
            }
        }
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let url = listingURL {
                ToolbarItem(placement: .topBarTrailing) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right.square")
                            .accessibilityLabel("Open listing")
                    }
                }
            }
        }
    }
}

struct HowToSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No checks yet").font(.headline)
            Label("In Depop, open a listing and tap Share", systemImage: "square.and.arrow.up")
            Label("Pick Cleared in the share sheet", systemImage: "checkmark.seal")
            Label("Or share screenshots of a listing from Photos", systemImage: "camera.viewfinder")
        }
        .font(.subheadline)
        .padding(.vertical, 4)
    }
}
