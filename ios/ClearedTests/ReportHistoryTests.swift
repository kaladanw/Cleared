import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

/// GET /api/reports decoding, the history cache rules (contract §3), and the
/// API client's 401 → refresh once → retry once → sign out flow.
final class ReportHistoryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try AuthFixtures.tempDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func serverRows() throws -> [ReportRow] {
        try ReportRow.decoder().decode([ReportRow].self, from: FixtureLoader.data("reports-list", "json"))
    }

    private func report(_ name: String = "run-0-output", reportID: String? = nil) throws -> CheckReport {
        var report = try CheckReport.decoder().decode(CheckReport.self, from: FixtureLoader.data(name, "json"))
        report.reportId = reportID
        return report
    }

    // MARK: ReportRow

    func testDecodesServerRowsLeniently() throws {
        let rows = try serverRows()
        XCTAssertEqual(rows.count, 2)
        let first = rows[0]
        XCTAssertEqual(first.listingName, "Levi's 505 Regular")
        XCTAssertEqual(first.verdict, .negotiate)
        XCTAssertEqual(first.tags, ["gift"])
        XCTAssertEqual(first.sellerUsername, "davidjared")
        XCTAssertTrue(first.canRecheck)
        XCTAssertNotNil(first.report, "report_json decodes into CheckReport")
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-07T16:24:00Z")).timeIntervalSince1970 + 0.123
        XCTAssertEqual(try XCTUnwrap(first.checkedDate).timeIntervalSince1970, expected, accuracy: 0.001,
                       "microsecond timestamps parse")

        let second = rows[1]
        XCTAssertNil(second.report, "an unreadable report_json doesn't drop the row")
        XCTAssertEqual(second.listingURL, "")
        XCTAssertNotNil(second.checkedDate)
        XCTAssertEqual(second.displayTitle, "Listing check")
    }

    // MARK: Store

    func testServerReplacesCacheAndUnsavedLocalChecksSurvive() throws {
        let store = ReportHistoryStore(directory: directory)
        try store.record(report(), listingURL: nil, at: Date(timeIntervalSince1970: 1_791_500_000))           // unsaved
        try store.record(report(reportID: "saved-1"), listingURL: nil, at: Date(timeIntervalSince1970: 1_791_500_100))
        XCTAssertEqual(store.entries(for: "user-1").count, 2)

        try store.replaceServerRows(serverRows(), userID: "user-1")
        let entries = store.entries(for: "user-1")
        XCTAssertEqual(entries.count, 3, "2 server rows + the unsaved local check; saved-1 is the server's now")
        XCTAssertEqual(entries.filter(\.isLocalOnly).count, 1)
        XCTAssertEqual(entries.first?.id, "local:\(store.load().local[0].id)", "newest first")
    }

    func testSavedCheckShowsUntilServerListIncludesIt() throws {
        let store = ReportHistoryStore(directory: directory)
        try store.replaceServerRows(serverRows(), userID: "user-1")
        try store.record(report(reportID: "brand-new"), listingURL: nil)
        XCTAssertEqual(store.entries(for: "user-1").count, 3)
        XCTAssertFalse(store.entries(for: "user-1")[0].isLocalOnly, "saved to the account, just not fetched yet")
    }

    func testCacheIsPerAccount() throws {
        let store = ReportHistoryStore(directory: directory)
        try store.replaceServerRows(serverRows(), userID: "user-1")
        XCTAssertEqual(store.entries(for: "someone-else").count, 0)
        XCTAssertEqual(store.entries(for: nil).count, 0)
        try store.clearAccountData()
        XCTAssertEqual(store.entries(for: "user-1").count, 0)
    }

    func testErrorReportsAreNotHistory() throws {
        let store = ReportHistoryStore(directory: directory)
        var failed = try report()
        failed.error = "No screenshots received"
        try store.record(failed, listingURL: nil)
        XCTAssertTrue(store.entries(for: nil).isEmpty)
    }

    func testMigratesLegacyLastReport() throws {
        let legacy = directory.appending(path: ReportHistoryStore.legacyFilename)
        try FixtureLoader.data("run-0-output", "json").write(to: legacy)
        let store = ReportHistoryStore(directory: directory)
        XCTAssertEqual(store.entries(for: nil).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "imported once, then removed")
        XCTAssertEqual(store.entries(for: nil).count, 1)
    }

    func testCacheRoundTripKeepsReportContent() throws {
        let store = ReportHistoryStore(directory: directory)
        let rows = try serverRows()
        try store.replaceServerRows(rows, userID: "user-1")
        guard case .server(let cached) = store.entries(for: "user-1").first else { return XCTFail() }
        XCTAssertEqual(cached, rows[0])
        XCTAssertEqual(cached.report?.verdict.oneLine, rows[0].report?.verdict.oneLine)
    }

    // MARK: Service + API client auth flow

    private func api(_ transport: FakeTransport, provider: AccessTokenProvider) -> ClearedAPIClient {
        ClearedAPIClient(
            baseURL: URL(string: "https://api.example.com")!, token: "shared",
            accessTokenProvider: provider, transport: transport, unavailableRetryDelay: .zero
        )
    }

    private func sessionManager(_ store: SessionStore, _ refresher: FakeRefresher) -> SessionManager {
        SessionManager(
            store: store, refresher: refresher,
            lock: FileLock(url: directory.appending(path: "lock"), pollInterval: .milliseconds(5)),
            now: { AuthFixtures.t0 }, transientRetryDelays: []
        )
    }

    private var reportsJSON: String { get throws { try FixtureLoader.string("reports-list", "json") } }

    func testFetchReportsRequestShape() async throws {
        let transport = FakeTransport([.status(200, try reportsJSON)])
        let sessions = sessionManager(InMemorySessionStore(AuthFixtures.session(1)), FakeRefresher([]))
        let rows = try await api(transport, provider: sessions).fetchReports()
        XCTAssertEqual(rows.count, 2)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/api/reports")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Cleared-Token"))
    }

    func test401RefreshesOnceAndRetriesOnce() async throws {
        let store = InMemorySessionStore(AuthFixtures.session(1))
        let refresher = FakeRefresher([.success(AuthFixtures.session(2))])
        let transport = FakeTransport([.status(401, #"{"detail":"Invalid or expired token."}"#), .status(200, try reportsJSON)])
        let rows = try await api(transport, provider: sessionManager(store, refresher)).fetchReports()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(refresher.calls, 1)
        XCTAssertEqual(transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer access-1", "Bearer access-2"])
        XCTAssertEqual(try store.load()?.refreshToken, "refresh-2")
    }

    func testSecond401SignsOut() async throws {
        let store = InMemorySessionStore(AuthFixtures.session(1))
        let refresher = FakeRefresher([.success(AuthFixtures.session(2))])
        let transport = FakeTransport([.status(401, "{}"), .status(401, "{}"), .status(200, "[]")])
        do {
            _ = try await api(transport, provider: sessionManager(store, refresher)).fetchReports()
            XCTFail("expected signInRequired")
        } catch {
            XCTAssertEqual(error as? ClearedAPIError, .signInRequired)
        }
        XCTAssertEqual(transport.requests.count, 2, "retry exactly once")
        XCTAssertEqual(refresher.calls, 1, "refresh exactly once")
        XCTAssertNil(try store.load(), "signed out after the retry also failed")
    }

    func testRefresh401DuringRetrySignsOutWithoutRetrying() async throws {
        let store = InMemorySessionStore(AuthFixtures.session(1))
        let refresher = FakeRefresher([.failure(AuthError.refreshTokenInvalid)])
        let transport = FakeTransport([.status(401, "{}")])
        do {
            _ = try await api(transport, provider: sessionManager(store, refresher)).fetchReports()
            XCTFail()
        } catch {
            XCTAssertEqual(error as? ClearedAPIError, .signInRequired)
        }
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertNil(try store.load())
    }

    func testCheckListing401RetryAlsoAppliesToChecks() async throws {
        let store = InMemorySessionStore(AuthFixtures.session(1))
        let refresher = FakeRefresher([.success(AuthFixtures.session(2))])
        let transport = FakeTransport([.status(401, "{}"), .status(200, try FixtureLoader.string("run-0-output", "json"))])
        let body = CheckListingRequest(facts: .init(), imageUrls: ["https://media-photos.depop.com/x/P0.jpg"],
                                       userContext: nil, listingUrl: nil, seller: nil)
        _ = try await api(transport, provider: sessionManager(store, refresher)).checkListing(body)
        XCTAssertEqual(transport.requests.map(\.url?.path), ["/check-listing", "/check-listing"])
        XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer access-2")
    }

    func testExpiringTokenIsRefreshedBeforeTheCheckIsSent() async throws {
        let store = InMemorySessionStore(AuthFixtures.session(1, expiresIn: 60))
        let refresher = FakeRefresher([.success(AuthFixtures.session(2))])
        let transport = FakeTransport([.status(200, try FixtureLoader.string("run-0-output", "json"))])
        _ = try await api(transport, provider: sessionManager(store, refresher))
            .check(images: [Data([0xFF, 0xD8])], userContext: nil)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer access-2")
        XCTAssertNil(transport.requests.first?.value(forHTTPHeaderField: "X-Cleared-Token"))
    }

    func testSync503KeepsCacheAndSession() async throws {
        let historyStore = ReportHistoryStore(directory: directory)
        try historyStore.replaceServerRows(serverRows(), userID: "user-1")
        let sessions = InMemorySessionStore(AuthFixtures.session(1))
        let transport = FakeTransport([.status(503, #"{"detail":"history unavailable"}"#), .status(503, "{}")])
        let service = ReportHistoryService(api: api(transport, provider: sessionManager(sessions, FakeRefresher([]))),
                                           store: historyStore)
        let snapshot = await service.sync(userID: "user-1")
        XCTAssertEqual(transport.requests.count, 2, "one retry on 503")
        XCTAssertEqual(snapshot.entries.count, 2, "cache shown")
        XCTAssertNotNil(snapshot.staleReason)
        XCTAssertFalse(snapshot.signedOut)
        XCTAssertNotNil(try sessions.load(), "503 never signs out")
        XCTAssertEqual(historyStore.entries(for: "user-1").count, 2, "cache untouched")
    }

    func testSyncReplacesCacheFromServer() async throws {
        let historyStore = ReportHistoryStore(directory: directory)
        try historyStore.record(report(reportID: "old-saved"), listingURL: nil)
        let transport = FakeTransport([.status(200, try reportsJSON)])
        let service = ReportHistoryService(
            api: api(transport, provider: sessionManager(InMemorySessionStore(AuthFixtures.session(1)), FakeRefresher([]))),
            store: historyStore
        )
        let snapshot = await service.sync(userID: "user-1")
        XCTAssertNil(snapshot.staleReason)
        XCTAssertEqual(snapshot.entries.count, 2)
        XCTAssertEqual(historyStore.lastFetched(for: "user-1") != nil, true)
    }

    func testSyncWhenSessionRejectedReportsSignedOut() async throws {
        let transport = FakeTransport([.status(401, "{}")])
        let service = ReportHistoryService(
            api: api(transport, provider: sessionManager(InMemorySessionStore(AuthFixtures.session(1)),
                                                         FakeRefresher([.failure(AuthError.refreshTokenInvalid)]))),
            store: ReportHistoryStore(directory: directory)
        )
        let snapshot = await service.sync(userID: "user-1")
        XCTAssertTrue(snapshot.signedOut)
    }
}
