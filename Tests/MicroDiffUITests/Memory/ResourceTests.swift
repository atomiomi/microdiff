import MicroDiffCore
import MicroDiffTestSupport
import Testing

@testable import MicroDiffUI

/// File descriptors, threads and child processes: a window open for days must not run out of them.
/// Every git run makes two pipes and a child process; every watcher an FSEvents stream.
extension IsolatedMemory {
    @MainActor
    @Suite(.serialized)
    struct Resources {
        private let n = MemoryEnv.soak

        /// With the scans of the other tests in this pass, the default run spawns about a thousand git processes,
        /// each followed by a file descriptor check.
        @Test("hundreds of git runs leave no file descriptor, thread or zombie behind, and the heap flat")
        func gitRuns() async {
            let repo = TestRepo()
            repo.write("a.txt", "one\n")
            repo.commitAll("first")
            repo.write("a.txt", "two\n")
            repo.write("new.txt", "new\n")
            let git = GitRunner()
            let before = ResourceCounts.now()

            let report = await measureSteadyState(
                "git-run", warmup: 50, perRound: 30 * n, heapBudget: 128,
                step: { _ in _ = try? git.run(["status", "--porcelain=v2", "-z", "--untracked-files=all"], in: repo.path) })
            #expect(report.holds(footprintMB: 2))
            #expect(await ResourceCounts.settle(to: before).holds())
        }

        @Test("starting and stopping the watcher many times leaves nothing behind")
        func watcherStartStop() async {
            let dir = TempDir()
            dir.write("a.txt", "a\n")
            let before = ResourceCounts.now()

            // FSEvents keeps some bookkeeping per process that grows over the first few hundred streams and then
            // stays flat (seen in 5000-cycle runs): warm it up with quick cycles first. It also grows in 10-20 KB
            // steps, hence the 512 B budget; a watcher that is never freed is caught by the core lifetime tests.
            for _ in 0..<800 {
                let watcher = FSWatcher(path: dir.path) {}
                watcher.start()
                watcher.stop()
            }
            let report = await measureSteadyState(
                "watcher-start-stop", warmup: 30, perRound: 30 * n, heapBudget: 512,
                // FSEvents tears a stream down asynchronously, on its own queues. Back-to-back start/stop in a tight
                // loop outruns that cleanup and looks like growth; in the app a watcher starts once per folder.
                settle: { try? await Task.sleep(for: .milliseconds(50)) },
                step: { _ in
                    let watcher = FSWatcher(path: dir.path) {}
                    watcher.start()
                    watcher.stop()
                },
                wait: { try? await Task.sleep(for: .milliseconds(2)) })
            #expect(report.holds(footprintMB: 2))
            #expect(await ResourceCounts.settle(to: before).holds())
        }

        @Test("finished background scans leave no thread behind")
        func backgroundScans() async {
            let soak = SoakRepo()
            let before = ResourceCounts.now()
            let report = await measureSteadyState(
                "background-scan", warmup: 5, rounds: 4, perRound: 5 * n, heapBudget: 2048,
                step: { _ in _ = BackgroundScan(path: soak.path).waitUntilDone() })
            #expect(report.holds(footprintMB: 2))
            #expect(await ResourceCounts.settle(to: before).holds())
        }

        @Test("rescans of a watched workspace leave no file descriptor or thread behind")
        func watchedRescans() async {
            let soak = SoakRepo()
            let before = ResourceCounts.now()
            do {
                let workspace = Workspace(path: soak.path)
                workspace.start()
                await waitIdle(workspace)
                for _ in 0..<(40 * n) {
                    workspace.refresh()
                    await waitIdle(workspace)
                }
            }
            // The workspace and its watcher are gone now: everything they opened must be closed again.
            #expect(await ResourceCounts.settle(to: before).holds())
        }
    }
}
