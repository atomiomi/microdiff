import MicroDiffCore
import MicroDiffTestSupport
import Testing

/// Core objects that own threads, streams or callbacks are freed when they are done.
@Suite("Memory: core lifetimes")
struct CoreLifetimeTests {
    /// Something to capture in a callback: when it is freed, whoever held the callback is gone too.
    private final class Sentinel: Sendable {}

    private final class Weak<T: AnyObject>: @unchecked Sendable {
        weak var object: T?
        init(_ object: T?) { self.object = object }
    }

    /// Polls until `condition` holds or about `seconds` passed.
    private func eventually(seconds: Int = 5, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<(seconds * 200) {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test("a stopped watcher lets go of the watcher and of its callback")
    func stoppedWatcherIsFreed() async {
        let dir = TempDir()
        var watcherRef = Weak<FSWatcher>(nil)
        var sentinelRef = Weak<Sentinel>(nil)
        do {
            let sentinel = Sentinel()
            sentinelRef = Weak(sentinel)
            let watcher = FSWatcher(path: dir.path) { _ = sentinel }
            watcherRef = Weak(watcher)
            watcher.start()
            watcher.stop()
        }
        #expect(await eventually { watcherRef.object == nil && sentinelRef.object == nil })
    }

    @Test("a running watcher that is released stops and frees its callback")
    func releasedRunningWatcherIsFreed() async {
        let dir = TempDir()
        var sentinelRef = Weak<Sentinel>(nil)
        do {
            let sentinel = Sentinel()
            sentinelRef = Weak(sentinel)
            let watcher = FSWatcher(path: dir.path) { _ = sentinel }
            watcher.start()
            dir.write("a.txt", "a\n")
        }
        // The FSEvents stream held the callback; deinit must have stopped and released it.
        #expect(await eventually { sentinelRef.object == nil })
    }

    @Test("many watchers started and stopped all go away")
    func manyWatchersGoAway() async {
        let dir = TempDir()
        var refs: [Weak<Sentinel>] = []
        for _ in 0..<50 {
            let sentinel = Sentinel()
            refs.append(Weak(sentinel))
            let watcher = FSWatcher(path: dir.path) { _ = sentinel }
            watcher.start()
            watcher.stop()
        }
        #expect(await eventually { refs.allSatisfy { $0.object == nil } })
    }

    @Test("a finished background scan is freed, its thread holds nothing")
    func finishedBackgroundScanIsFreed() async {
        let repo = TestRepo()
        repo.write("a.txt", "a\n")
        var scanRef = Weak<BackgroundScan>(nil)
        do {
            let scan = BackgroundScan(path: repo.path)
            scanRef = Weak(scan)
            #expect(scan.waitUntilDone().isGitRepo)
        }
        #expect(await eventually { scanRef.object == nil })
    }

    @Test("a background scan dropped before it finished is freed once it finishes")
    func droppedBackgroundScanIsFreed() async {
        let repo = TestRepo()
        repo.write("a.txt", "a\n")
        var scanRef = Weak<BackgroundScan>(nil)
        do {
            let scan = BackgroundScan(path: repo.path)
            scanRef = Weak(scan)
        }
        #expect(await eventually(seconds: 10) { scanRef.object == nil })
    }
}
