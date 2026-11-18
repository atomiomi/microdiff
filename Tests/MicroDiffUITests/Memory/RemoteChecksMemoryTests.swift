import MicroDiffCore
import MicroDiffTestSupport
import Testing

@testable import MicroDiffUI

/// A window that asks its remotes all day (every five minutes, on every Refresh) must not grow.
extension IsolatedMemory {
    @MainActor
    @Suite(.serialized)
    struct RemoteChecks {
        private let n = MemoryEnv.soak

        @Test("remote checks: many runs against a local bare repository, remote moving now and then")
        func runs() async {
            let fixture = RemoteFixture()
            let monitor = RemoteFixture.liveMonitor()
            monitor.enable()
            monitor.setVisible(true)
            monitor.update(repos: [fixture.snapshot()])
            let before = ResourceCounts.now()

            let report = await measureSteadyState(
                "remote-checks", warmup: 30, perRound: 20 * n, heapBudget: 256,
                step: { i in
                    // Every tenth run finds a moved remote (a pull mark), the others find it as it was.
                    if i % 10 == 0 { fixture.moveRemote() }
                    monitor.refresh()
                },
                wait: { _ = await waitUntil(timeout: .seconds(30)) { !monitor.isRunning } })
            #expect(report.holds(footprintMB: 2))
            monitor.stop()
            #expect(await ResourceCounts.settle(to: before).holds())
        }

        @Test("remote checks that fail or hang and are killed leave no descriptor, thread or process behind")
        func killedChecks() async {
            let fixture = RemoteFixture(hangs: true)
            let monitor = fixture.makeMonitor()
            monitor.enable()
            monitor.update(repos: [fixture.snapshot()])
            let before = ResourceCounts.now()
            for _ in 0..<(10 * n) {
                monitor.refresh()
                _ = await waitUntil { fixture.hungPid != nil && monitor.isRunning }
                monitor.stop()
                monitor.enable()
                monitor.update(repos: [fixture.snapshot()])
            }
            monitor.stop()
            #expect(await eventually { !fixture.hungProcessExists })
            #expect(await ResourceCounts.settle(to: before).holds())
        }
    }
}
