import MicroDiffCore
import MicroDiffTestSupport
import Testing

@testable import MicroDiffUI

/// Slow paths that only run in a long soak (`MICRODIFF_SOAK=<n> scripts/test.sh --filter Isolated`).
extension IsolatedMemory {
    @MainActor
    @Suite(.serialized, .enabled(if: MemoryEnv.soak > 1, "slow: only in a soak (MICRODIFF_SOAK=<n>)"))
    struct SoakOnly {
        private let n = MemoryEnv.soak

        @Test("rescans triggered by the file watcher (the real path: FSEvents, throttling, background scans)")
        func watcherDrivenRescans() async {
            let soak = SoakRepo()
            let controller = makeController(soak.path)
            let workspace = controller.workspace
            workspace.start()
            await waitQuiet(workspace)
            workspace.openFile(soak.absolute("src/app.swift"), mode: .diff, pin: true, synchronously: true)
            let painter = OffscreenPainter()
            let before = ResourceCounts.now()
            var notesChanged = false

            let report = await measureSteadyState(
                "watcher-rescan", warmup: 10, perRound: 5 * n, heapBudget: 1024,
                flush: { TextCache.shared.removeAll() },
                settle: { await waitQuiet(workspace) },
                step: { i in
                    notesChanged = i % 2 == 0
                    soak.repo.write("notes.txt", notesChanged ? "one\ntwo\n" : "one\n")
                },
                wait: {
                    // No refresh call: the watcher has to notice.
                    _ = await waitUntil(timeout: .seconds(5)) {
                        workspace.snapshot?.repos.first?.changes.contains { $0.path == "notes.txt" } == notesChanged
                    }
                    await waitIdle(workspace)
                    painter.paint(controller.rootView)
                })
            #expect(report.holds(footprintMB: 2))
            #expect(await ResourceCounts.settle(to: before).holds())
        }
    }
}
