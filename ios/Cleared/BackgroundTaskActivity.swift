import UIKit

/// Keeps the app running while it holds the session refresh lock. iOS kills a
/// suspended app that holds a file lock in the shared App Group container
/// (0xdead10cc), so the short lock-holding refresh runs inside a UIKit
/// background task. The extension can't use UIApplication; it uses
/// `ImmediateActivity` and relies on the kernel dropping the lock if killed.
struct BackgroundTaskActivity: LockHoldingActivity {
    @MainActor
    private final class TaskBox {
        var id: UIBackgroundTaskIdentifier = .invalid

        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }

    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        let box = await MainActor.run { () -> TaskBox in
            let box = TaskBox()
            box.id = UIApplication.shared.beginBackgroundTask(withName: "Cleared session refresh") {
                MainActor.assumeIsolated { box.end() }
            }
            return box
        }
        do {
            let value = try await work()
            await box.end()
            return value
        } catch {
            await box.end()
            throw error
        }
    }
}
