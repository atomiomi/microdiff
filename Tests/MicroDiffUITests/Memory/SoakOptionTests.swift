import MicroDiffCore
import Testing

@testable import MicroDiffUI

extension UITests {
    @MainActor
    struct SoakOptionTests {
        private func parse(_ arguments: [String]) -> LaunchOptions {
            LaunchOptions(arguments: ["MicroDiff"] + arguments)
        }

        @Test func soakTakesARoundCountAndKeepsThePath() {
            let options = parse(["--soak", "300", "/some/repo"])
            #expect(options.soakIterations == 300)
            #expect(options.path == "/some/repo")
        }

        @Test func soakWithoutACountUsesTheDefault() {
            let options = parse(["--soak", "/some/repo"])
            #expect(options.soakIterations == 50)
            #expect(options.path == "/some/repo")
            #expect(parse(["--soak"]).soakIterations == 50)
        }

        /// The driver `scripts/leaks.sh` runs, for a few rounds on a real repository (offscreen, as always).
        @Test func soakDriverRunsTheWholeRoundAndReports() async {
            let soak = SoakRepo()
            let controller = makeController(soak.path)
            let summary = await Soak.drive(controller, iterations: 5)
            #expect(summary.hasPrefix("SOAK iterations=5 "))
            #expect(summary.contains("fds="))
            #expect(controller.workspace.tabs.isEmpty)
            #expect(controller.workspace.snapshot != nil)
        }

        @Test func memoryProbeReadsThisProcess() {
            #expect(MemoryProbe.liveHeapBytes() > 0)
            #expect(ProcessMetrics.footprintBytes() > 0)
            #expect(MemoryProbe.openFileDescriptorCount() >= 3)
            #expect(MemoryProbe.threadCount() >= 1)
            // Other tests spawn git at the same time: a child can be a zombie for a moment, so only check it reads.
            #expect(MemoryProbe.zombieChildCount() >= 0)
            MemoryProbe.relieve()
        }

        @Test func noSoakByDefault() {
            #expect(parse(["/some/repo"]).soakIterations == nil)
        }
    }
}
