import Testing
import MicroDiffCore

@Suite struct FSEventFilterTests {
    @Test(arguments: [
        ("/w/a.txt", true),
        ("/w/src/deep/dir/file.swift", true),
        ("/w/.gitignore", true),
        ("/w/.github/workflows/ci.yml", true),
        ("/w/x.git/file", true),
        ("/w/.git/index", true),
        ("/w/.git/HEAD", true),
        ("/w/.git/ORIG_HEAD", true),
        ("/w/.git/refs/heads/main", true),
        ("/w/.git/refs/tags/v1", true),
        ("/w/.git/modules/lib/index", true),
        ("/w/.git/modules/lib/HEAD", true),
        ("/w/.git/modules/lib/refs/heads/dev", true),
        ("/w/sub/.git/index", true),
        ("/w/.git/index.lock", false),
        ("/w/.git/objects/ab/cdef", false),
        ("/w/.git/logs/HEAD", false),
        ("/w/.git/logs/refs/heads/main", false),
        ("/w/.git/FETCH_HEAD", false),
        ("/w/.git/modules/lib/objects/x", false),
        ("/w/.git/config", false),
        ("/w/.git/refs", false),
        ("/w/.git", false),
        ("/w/.git/", false),
        ("/w/sub/.git", false),
    ] as [(String, Bool)])
    func relevance(path: String, expected: Bool) {
        #expect(FSEventFilter.isRelevant(path: path) == expected)
    }
}

/// FSEvents may still report the folder's creation right after `start()`. Let that settle, then measure from here.
private func settled(_ hits: Counter) async -> Int {
    try? await Task.sleep(for: .milliseconds(1200))
    return hits.value
}

@Suite(.serialized) struct FSWatcherTests {
    @Test func fileWriteTriggersCallbackOnMainQueue() async {
        let t = TempDir()
        let hits = Counter()
        let onMain = Counter()
        let watcher = FSWatcher(path: t.path) {
            if isOnMainThread() { onMain.bump() }
            hits.bump()
        }
        watcher.start()
        t.write("a.txt", "hello")
        #expect(await waitFor { hits.value > 0 })
        #expect(onMain.value == hits.value)
        watcher.stop()
    }

    @Test func gitObjectsNoiseIsIgnored() async {
        let t = TempDir()
        t.mkdir(".git/objects")
        let hits = Counter()
        let watcher = FSWatcher(path: t.path) { hits.bump() }
        watcher.start()
        let base = await settled(hits)
        t.write(".git/objects/ab/cdef", "blob")
        try? await Task.sleep(for: .milliseconds(1500))
        #expect(hits.value == base)
        watcher.stop()
    }

    @Test func gitIndexTriggers() async {
        let t = TempDir()
        t.mkdir(".git")
        let hits = Counter()
        let watcher = FSWatcher(path: t.path) { hits.bump() }
        watcher.start()
        let base = await settled(hits)
        t.write(".git/index", "x")
        #expect(await waitFor { hits.value > base })
        watcher.stop()
    }

    @Test func nothingArrivesAfterStop() async {
        let t = TempDir()
        let hits = Counter()
        let watcher = FSWatcher(path: t.path) { hits.bump() }
        watcher.start()
        _ = await settled(hits)
        watcher.stop()
        let base = hits.value
        t.write("late.txt", "x")
        try? await Task.sleep(for: .milliseconds(1500))
        #expect(hits.value == base)
    }

    @Test func startStopTwiceIsHarmless() async {
        let t = TempDir()
        let hits = Counter()
        let watcher = FSWatcher(path: t.path) { hits.bump() }
        watcher.stop()
        watcher.start(); watcher.start()
        watcher.stop(); watcher.stop()
        watcher.start()
        let base = await settled(hits)
        t.write("again.txt", "x")
        #expect(await waitFor { hits.value > base })
        watcher.stop()
    }

    @Test func deinitStopsTheStream() async {
        let t = TempDir()
        let hits = Counter()
        var watcher: FSWatcher? = FSWatcher(path: t.path) { hits.bump() }
        watcher?.start()
        _ = await settled(hits)
        watcher = nil
        let base = hits.value
        t.write("after.txt", "x")
        try? await Task.sleep(for: .milliseconds(1500))
        #expect(hits.value == base)
    }
}
