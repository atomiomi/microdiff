import Foundation

// Foundation helpers live here because importing Foundation next to Testing fails on a Command Line Tools install
// (no `_Testing_Foundation` overlay).

func isOnMainThread() -> Bool { Thread.isMainThread }

/// Thread-safe counter the watcher callback can bump.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func bump() { lock.withLock { n += 1 } }
}

func waitFor(timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}
