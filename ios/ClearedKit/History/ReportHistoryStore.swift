import Foundation

/// A check that exists only on this device: either not saved by the server
/// (shared-secret `/check`, no `report_id`), or saved but not yet seen in a
/// `GET /api/reports` response.
public struct LocalReport: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var reportID: String?
    public var checkedAt: Date
    public var listingURL: String?
    public var report: CheckReport

    public init(id: String = UUID().uuidString, reportID: String?, checkedAt: Date, listingURL: String?, report: CheckReport) {
        self.id = id
        self.reportID = reportID
        self.checkedAt = checkedAt
        self.listingURL = listingURL
        self.report = report
    }
}

extension CheckReport: Equatable {
    public static func == (lhs: CheckReport, rhs: CheckReport) -> Bool {
        // Reports are value snapshots; compare the encoded form.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(lhs)) == (try? encoder.encode(rhs))
    }
}

/// One entry in the history list, server row or local-only check.
public enum HistoryEntry: Identifiable, Equatable, Sendable {
    case server(ReportRow)
    case local(LocalReport)

    public var id: String {
        switch self {
        case .server(let row): return "server:\(row.id)"
        case .local(let local): return "local:\(local.id)"
        }
    }

    public var date: Date? {
        switch self {
        case .server(let row): return row.checkedDate
        case .local(let local): return local.checkedAt
        }
    }

    public var report: CheckReport? {
        switch self {
        case .server(let row): return row.report
        case .local(let local): return local.report
        }
    }

    public var title: String {
        switch self {
        case .server(let row): return row.displayTitle
        case .local(let local):
            return local.report.listingFacts.modelOrName ?? local.report.listingFacts.brand ?? "Listing check"
        }
    }

    public var recommendation: Recommendation? {
        switch self {
        case .server(let row): return row.verdict ?? row.report?.verdict.recommendation
        case .local(let local): return local.report.verdict.recommendation
        }
    }

    /// Not in the account's history: only on this phone.
    public var isLocalOnly: Bool {
        if case .local(let local) = self { return local.reportID == nil }
        return false
    }
}

/// On-disk history in the App Group container, shared by the app and the
/// Share Extension. Replaces `LastReportStore`.
///
/// `GET /api/reports` is the source of truth (contract §3). This file is only
/// an offline cache of it plus checks the server never saved:
/// - `replaceServerRows` swaps in the server list wholesale and drops local
///   entries that carry a `report_id` (the server now owns them).
/// - On a failed fetch nothing is touched: the cache stays as it was.
/// - The cache is per account (`userID`); another account's cache is never shown.
public struct ReportHistoryStore: Sendable {
    struct Snapshot: Codable, Equatable {
        var userID: String?
        var fetchedAt: Date?
        var serverRows: [ReportRow]
        var local: [LocalReport]

        static let empty = Snapshot(userID: nil, fetchedAt: nil, serverRows: [], local: [])
    }

    static let filename = "report-history.json"
    static let legacyFilename = "last-report.json"
    static let maxLocal = 25

    let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The App Group container; nil if the entitlement is missing.
    public static func shared() -> ReportHistoryStore? {
        ClearedConfig.appGroupContainer.map(ReportHistoryStore.init(directory:))
    }

    private var fileURL: URL { directory.appending(path: Self.filename) }
    private var legacyURL: URL { directory.appending(path: Self.legacyFilename) }

    // MARK: Reading

    /// Merged list, newest first. `userID` nil = signed out: only checks
    /// recorded while signed out are shown.
    public func entries(for userID: String?) -> [HistoryEntry] {
        let snapshot = load()
        let serverRows = snapshot.userID == userID ? snapshot.serverRows : []
        let known = Set(serverRows.map(\.id))
        let local = snapshot.local.filter { entry in
            guard let reportID = entry.reportID else { return true }
            return !known.contains(reportID)
        }
        let merged = serverRows.map(HistoryEntry.server) + local.map(HistoryEntry.local)
        return merged.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    public func lastFetched(for userID: String?) -> Date? {
        let snapshot = load()
        return snapshot.userID == userID ? snapshot.fetchedAt : nil
    }

    // MARK: Writing

    /// Server list for `userID` arrived: it replaces the cache.
    public func replaceServerRows(_ rows: [ReportRow], userID: String, fetchedAt: Date = Date()) throws {
        var snapshot = load()
        if snapshot.userID != userID {
            // Different account: its rows and its saved local checks aren't ours.
            snapshot.local.removeAll { $0.reportID != nil }
        }
        snapshot.userID = userID
        snapshot.fetchedAt = fetchedAt
        snapshot.serverRows = rows
        snapshot.local.removeAll { $0.reportID != nil }
        try write(snapshot)
    }

    /// A check just finished (extension or app). Error reports aren't history.
    public func record(_ report: CheckReport, listingURL: URL?, at date: Date = Date()) throws {
        guard report.error == nil else { return }
        var snapshot = load()
        snapshot.local.insert(
            LocalReport(reportID: report.reportId, checkedAt: date, listingURL: listingURL?.absoluteString, report: report),
            at: 0
        )
        snapshot.local = Array(snapshot.local.prefix(Self.maxLocal))
        try write(snapshot)
    }

    /// Sign-out: drop the account's cached rows and anything it saved.
    public func clearAccountData() throws {
        var snapshot = load()
        snapshot.userID = nil
        snapshot.fetchedAt = nil
        snapshot.serverRows = []
        snapshot.local.removeAll { $0.reportID != nil }
        try write(snapshot)
    }

    // MARK: File

    func load() -> Snapshot {
        if let data = try? Data(contentsOf: fileURL),
           let snapshot = try? Self.decoder().decode(Snapshot.self, from: data) {
            return snapshot
        }
        return migrateLegacy() ?? .empty
    }

    private func write(_ snapshot: Snapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(snapshot).write(to: fileURL, options: [.atomic])
    }

    /// One-time import of PR #11's `last-report.json` as a local entry.
    private func migrateLegacy() -> Snapshot? {
        guard let data = try? Data(contentsOf: legacyURL),
              let report = try? CheckReport.decoder().decode(CheckReport.self, from: data)
        else { return nil }
        var snapshot = Snapshot.empty
        if report.error == nil {
            let modified = (try? FileManager.default.attributesOfItem(atPath: legacyURL.path)[.modificationDate]) as? Date
            snapshot.local = [LocalReport(reportID: report.reportId, checkedAt: modified ?? Date(), listingURL: nil, report: report)]
        }
        if (try? write(snapshot)) != nil {
            try? FileManager.default.removeItem(at: legacyURL)
        }
        return snapshot
    }

    /// Writes camelCase via the default encoder; `convertFromSnakeCase` leaves
    /// camelCase keys alone, so the same decoder reads cache and server JSON.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
