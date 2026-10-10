import SwiftUI
import UIKit

/// Entry point of the Share Extension (NSExtensionPrincipalClass). Hosts the
/// SwiftUI panel; the extension lifecycle (complete/cancel) stays here.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        let root = ShareRootView(
            extensionContext: extensionContext,
            onDone: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        )
        let host = UIHostingController(rootView: root)
        addChild(host)
        view.addSubview(host.view)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: self)
    }
}

struct ShareRootView: View {
    let extensionContext: NSExtensionContext?
    let onDone: () -> Void

    @StateObject private var session = CheckSession()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Cleared")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: onDone)
                    }
                }
        }
        .task { await session.ingest(from: extensionContext) }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .ingesting:
            ProgressView("Reading what you shared…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .fetchingListing:
            ProgressView("Loading the Depop listing…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .composing:
            ComposeView(session: session)
        case .checking:
            CheckingView()
        case .finished(let report):
            ReportView(report: report)
        case .failed(let message):
            FailureView(message: message)
        }
    }
}

/// Thumbnails + optional buyer context + the one primary button.
private struct ComposeView: View {
    @ObservedObject var session: CheckSession

    var body: some View {
        Form {
            if let listing = session.listing {
                ListingPreviewSection(listing: listing)
            }

            if let notice = session.listingNotice {
                Section {
                    Label(notice, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if session.listing == nil, !session.images.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(session.images.enumerated()), id: \.offset) { _, image in
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 72, height: 108)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                } header: {
                    Text("\(session.images.count) screenshot\(session.images.count == 1 ? "" : "s")")
                }
            }

            Section("Anything you care about? (optional)") {
                TextField(
                    "e.g. it's a gift, I care more that it's legit",
                    text: $session.userContext,
                    axis: .vertical
                )
                .lineLimit(2...4)
            }

            Section {
                Button {
                    Task { await session.runCheck() }
                } label: {
                    Text("Check")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

/// What the phone read off the Depop listing, so the buyer can see it's the
/// right item before spending a check on it.
private struct ListingPreviewSection: View {
    let listing: DepopListing

    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(listing.imageURLs.prefix(4), id: \.self) { url in
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.secondary.opacity(0.15)
                        }
                        .frame(width: 72, height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            if let title = listing.facts.modelOrName {
                Text(title).font(.headline)
            }
            if !details.isEmpty {
                Text(details.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if listing.isSold {
                Label("This listing looks sold or unavailable.", systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Depop listing")
        } footer: {
            if let seller = listing.seller {
                Text("Sold by @\(seller.username)")
            }
        }
    }

    private var details: [String] {
        var parts: [String] = []
        if let price = listing.facts.askingPrice {
            parts.append(price.formatted(.currency(code: listing.facts.currency)))
        }
        if let size = listing.facts.size { parts.append("Size \(size)") }
        if let condition = listing.facts.listedCondition { parts.append(condition) }
        if let brand = listing.facts.brand { parts.append(brand) }
        return parts
    }
}

/// The honest wait: a check takes ~30–90 s, so say what's happening.
private struct CheckingView: View {
    private static let stages = [
        "Reading the listing…",
        "Checking retail and used prices…",
        "Weighing trust signals…",
        "Writing the verdict…",
    ]
    @State private var stageIndex = 0

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(Self.stages[stageIndex])
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
            Text("This takes about a minute — real research, not a spinner.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(18))
                withAnimation {
                    stageIndex = min(stageIndex + 1, Self.stages.count - 1)
                }
            }
        }
    }
}

private struct ReportView: View {
    let report: CheckReport

    var body: some View {
        if let error = report.error {
            FailureView(message: error)
        } else {
            CareLabelView(report: report)
        }
    }
}

private struct FailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
