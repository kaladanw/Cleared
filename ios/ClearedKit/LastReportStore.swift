import Foundation

/// A tiny bridge between the Share Extension and host app. Reports stay on the
/// device in the shared app-group container; listing images are never persisted.
enum LastReportStore {
    private static let appGroup = "group.com.kaladanw.cleared"
    private static let filename = "last-report.json"

    static func save(_ report: CheckReport, in directory: URL? = nil) throws {
        let data = try JSONEncoder().encode(report)
        try data.write(to: fileURL(in: directory), options: .atomic)
    }

    static func load(from directory: URL? = nil) -> CheckReport? {
        guard let data = try? Data(contentsOf: fileURL(in: directory)) else { return nil }
        // The store writes camelCase, while accepting a backend-shaped fixture
        // here keeps simulator validation and future migrations forgiving.
        return try? CheckReport.decoder().decode(CheckReport.self, from: data)
    }

    private static func fileURL(in directory: URL?) throws -> URL {
        if let directory {
            return directory.appending(path: filename)
        }

        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else { throw CocoaError(.fileNoSuchFile) }
        return container.appending(path: filename)
    }
}
