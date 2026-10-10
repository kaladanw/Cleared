import Foundation
import SwiftUI

/// App-wide state: who is signed in (always read from the shared Keychain via
/// `SessionManager`, never cached on its own), and the history list.
@MainActor
final class AppModel: ObservableObject {
    enum AuthState: Equatable {
        case signedOut
        case signedIn(ClearedSession.User)
    }

    @Published private(set) var authState: AuthState = .signedOut
    @Published private(set) var history = HistorySnapshot(entries: [])
    @Published private(set) var isSyncing = false

    /// Why sign-in can't work in this build (missing backend URL, App Group,
    /// or keychain group). Shown instead of a form that would fail anyway.
    let setupError: String?

    private let sessions: SessionManager?
    private let authClient: AuthClient?
    private let historyStore: ReportHistoryStore?

    init() {
        var setupError: String?
        do {
            sessions = try ClearedAuth.makeSessionManager(activity: BackgroundTaskActivity())
        } catch {
            sessions = nil
            setupError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        self.setupError = setupError
        authClient = ClearedConfig.backendURL.map { AuthClient(baseURL: $0) }
        historyStore = ReportHistoryStore.shared()

        reloadSession()
        if let sessions {
            // A refresh 401 or a second request 401 cleared the session.
            let handler: @Sendable () -> Void = { [weak self] in
                Task { @MainActor in self?.reloadSession() }
            }
            Task { await sessions.setSignedOutHandler(handler) }
        }
    }

    var currentUser: ClearedSession.User? {
        if case .signedIn(let user) = authState { return user }
        return nil
    }

    /// Reread the shared Keychain item: the extension may have refreshed or
    /// signed out while the app was in the background.
    func reloadSession() {
        let user = sessions?.currentSession()?.user
        let newState: AuthState = user.map(AuthState.signedIn) ?? .signedOut
        if newState != authState { authState = newState }
        loadCachedHistory()
    }

    // MARK: Auth

    func signIn(email: String, password: String) async throws {
        guard let sessions, let authClient else { throw ClearedAPIError.notConfigured }
        let session = try await authClient.login(email: Self.normalized(email), password: password)
        try await sessions.signIn(session)
        reloadSession() // RootView syncs history when authState flips to signedIn.
    }

    /// Returns the outcome so the view can show the email-confirmation step.
    func signUp(email: String, password: String) async throws -> SignupOutcome {
        guard let sessions, let authClient else { throw ClearedAPIError.notConfigured }
        let outcome = try await authClient.signup(email: Self.normalized(email), password: password)
        if case .signedIn(let session) = outcome {
            try await sessions.signIn(session)
            reloadSession()
        }
        return outcome
    }

    func signOut() async {
        try? await sessions?.signOut()
        try? historyStore?.clearAccountData()
        reloadSession()
    }

    // MARK: History

    func loadCachedHistory() {
        guard let historyStore else { return }
        history = HistorySnapshot(entries: historyStore.entries(for: currentUser?.id))
    }

    /// `GET /api/reports` → cache (contract §3). On launch, foreground, and
    /// pull-to-refresh. Failures keep the cache and say so.
    func syncHistory() async {
        guard !isSyncing else { return }
        guard let user = currentUser, let historyStore,
              let api = ClearedAPIClient.fromConfig(accessTokenProvider: sessions)
        else {
            loadCachedHistory()
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        let snapshot = await ReportHistoryService(api: api, store: historyStore).sync(userID: user.id)
        history = snapshot
        if snapshot.signedOut {
            reloadSession()
        }
    }

    private static func normalized(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
