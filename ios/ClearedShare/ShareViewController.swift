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
            ProgressView("Reading screenshots…")
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
