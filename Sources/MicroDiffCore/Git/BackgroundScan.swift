import Foundation

/// A workspace scan that starts on its own thread the moment it is created.
///
/// The app creates one first thing in `main`, so git is already working while AppKit starts up
/// and the first frame can show real content.
package final class BackgroundScan: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: WorkspaceSnapshot?

    package init(path: String, scanner: RepoScanner = RepoScanner()) {
        Thread.detachNewThread { [self] in
            let snapshot = scanner.scan(root: scanner.resolveRoot(for: path).root)
            condition.lock()
            result = snapshot
            condition.broadcast()
            condition.unlock()
        }
    }

    /// The snapshot, waiting at most `timeout` seconds for it. Nil when it is not ready in time.
    package func wait(timeout: TimeInterval) -> WorkspaceSnapshot? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while result == nil {
            if !condition.wait(until: deadline) { break }
        }
        return result
    }

    /// The snapshot, however long it takes. Call it off the main thread.
    package func waitUntilDone() -> WorkspaceSnapshot {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let result { return result }
            condition.wait()
        }
    }
}
