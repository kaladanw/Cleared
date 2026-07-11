import SwiftUI
import UIKit

/// State machine for the extension: ingest → compose → checking → report/failed.
@MainActor
final class CheckSession: ObservableObject {
    enum Phase {
        case ingesting
        case composing
        case checking
        case finished(CheckReport)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .ingesting
    @Published var userContext = ""
    @Published private(set) var images: [UIImage] = []

    func ingest(from context: NSExtensionContext?) async {
        images = await ShareIngest.loadImages(from: context)
        phase = images.isEmpty
            ? .failed("No screenshots received — share the listing photos to analyze.")
            : .composing
    }

    func runCheck() async {
        guard let client = ClearedAPIClient.fromConfig() else {
            phase = .failed(ClearedAPIError.notConfigured.errorDescription ?? "Not configured.")
            return
        }
        phase = .checking

        let payloads = images.compactMap { $0.downscaledJPEG() }
        guard !payloads.isEmpty else {
            phase = .failed("Couldn't read the shared images.")
            return
        }

        do {
            let trimmed = userContext.trimmingCharacters(in: .whitespacesAndNewlines)
            let report = try await client.check(
                images: payloads,
                userContext: trimmed.isEmpty ? nil : trimmed
            )
            phase = .finished(report)
        } catch let error as ClearedAPIError {
            phase = .failed(error.errorDescription ?? "Something went wrong.")
        } catch {
            phase = .failed("Network problem: \(error.localizedDescription)")
        }
    }
}
