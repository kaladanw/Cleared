import SwiftUI
import UIKit

/// Entry point of the Share Extension (NSExtensionPrincipalClass). Hosts the
/// SwiftUI panel; the extension lifecycle (complete/cancel) stays here.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        let root = ShareRootView(onDone: { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        let host = UIHostingController(rootView: root)
        addChild(host)
        view.addSubview(host.view)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: self)
    }
}

/// S1 placeholder — S3 replaces this with ingest → context → check → report.
struct ShareRootView: View {
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal")
                    .font(.largeTitle)
                Text("Cleared")
                    .font(.headline)
                Text(
                    ClearedConfig.isConfigured
                        ? "Backend configured — flow lands in S3."
                        : "Backend not configured."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
    }
}
