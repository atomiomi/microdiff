import MicroDiffCore
import MicroDiffTestSupport
import Testing

@testable import MicroDiffUI

/// Scans run on every file change: with many clean submodules they must not grow anything.
extension IsolatedMemory {
    @MainActor
    @Suite(.serialized)
    struct QuietSubmodules {
        private let n = MemoryEnv.soak

        @Test("scans: repeated scans of a repository with clean submodules, one of them moving now and then")
        func scans() async {
            let source = TestRepo()
            source.write("lib.txt", "library\n")
            source.commitAll("library")
            let repo = TestRepo()
            repo.write("main.txt", "m\n")
            repo.commitAll("outer")
            for index in 0..<8 { repo.addSubmodule(from: source, at: "vendor/lib\(index)") }
            repo.commitAll("submodules")
            let scanner = RepoScanner()
            #expect(scanner.scan(root: repo.path).quietRepos.count == 8)
            let before = ResourceCounts.now()

            let report = await measureSteadyState(
                "quiet-submodule-scans", warmup: 20, perRound: 15 * n, heapBudget: 256,
                step: { i in
                    // Every tenth scan finds a commit in one of them, which costs one call for that one.
                    if i % 10 == 0 {
                        repo.write("vendor/lib\(i / 10 % 8)/n\(i).txt", "\(i)\n")
                        repo.commitAll("c\(i)", in: "vendor/lib\(i / 10 % 8)")
                    }
                    _ = scanner.scan(root: repo.path)
                })
            #expect(report.holds(footprintMB: 2))
            #expect(scanner.quietSubmodules.count == 8, "bounded by the submodules there are")
            #expect(await ResourceCounts.settle(to: before).holds())
            withExtendedLifetime(source) {}
        }
    }
}
