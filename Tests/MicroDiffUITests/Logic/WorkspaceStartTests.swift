import MicroDiffCore
import MicroDiffTestSupport
import Testing
@testable import MicroDiffUI

extension UITests {
    /// How the first scan arrives (the one that starts at process launch) and how a burst of refresh requests is spread out.
    @MainActor
    @Suite
    struct WorkspaceStartTests {
        private func changedRepo() -> TestRepo {
            let repo = TestRepo()
            repo.write("a.txt", "one\n")
            repo.commitAll("first")
            repo.write("a.txt", "two\n")
            return repo
        }

        @Test func aFinishedPrescanFillsTheWorkspaceBeforeStartReturns() {
            let repo = changedRepo()
            let prescan = BackgroundScan(path: repo.path)
            // Let it finish, so the quick path is taken however loaded the machine is.
            _ = prescan.wait(timeout: 30)
            let workspace = Workspace(path: repo.path)
            var sidebarUpdates = 0
            workspace.onSidebarChanged = { sidebarUpdates += 1 }

            workspace.start(prescan: prescan)

            #expect(workspace.snapshot?.totalChangeCount == 1)
            #expect(workspace.rootPath == repo.path)
            #expect(sidebarUpdates == 1)
        }

        @Test func aSlowPrescanLeavesTheWorkspaceEmptyUntilItArrives() async {
            let repo = changedRepo()
            let git = FakeGit.slow(0.15)
            let prescan = BackgroundScan(path: repo.path, scanner: RepoScanner(git: git.runner))
            let workspace = Workspace(path: repo.path)

            workspace.start(prescan: prescan)
            #expect(workspace.snapshot == nil)

            #expect(await waitUntil { workspace.snapshot != nil })
            #expect(workspace.snapshot?.totalChangeCount == 1)
            #expect(workspace.sidebarRows().contains { $0.name == "a.txt" })
        }

        @Test func aPrescanOfASubfolderMovesTheWorkspaceToTheRepositoryRoot() {
            let repo = changedRepo()
            repo.write("sub/deep/x.txt", "x\n")
            let prescan = BackgroundScan(path: repo.path + "/sub/deep")
            _ = prescan.wait(timeout: 30)
            let workspace = Workspace(path: repo.path + "/sub/deep")
            workspace.start(prescan: prescan)
            #expect(workspace.rootPath == repo.path)
            #expect(workspace.rootName == folderName(repo.path))
        }

        @Test func startWithoutAPrescanScansInTheBackground() async {
            let repo = changedRepo()
            let workspace = Workspace(path: repo.path)
            workspace.start()
            #expect(workspace.snapshot == nil)
            #expect(await waitUntil { workspace.snapshot != nil })
            #expect(workspace.snapshot?.totalChangeCount == 1)
        }

        @Test func requestsDuringAScanBecomeOneFollowUpScanAfterAPauseAndSeeTheNewestFiles() async {
            let repo = changedRepo()
            let workspace = Workspace(path: repo.path)
            var applied = 0
            var times: [ContinuousClock.Instant] = []
            workspace.onSidebarChanged = {
                applied += 1
                times.append(.now)
            }

            workspace.refresh()
            // Arrives while the first scan runs: remembered, not run in parallel.
            workspace.refresh()
            workspace.refresh()
            repo.write("late.txt", "late\n")

            #expect(await waitUntil { applied == 1 })
            // A request during the pause is covered by the follow-up scan, which has not started yet.
            workspace.refresh()
            #expect(await waitUntil { applied == 2 })
            #expect(times[1] - times[0] >= .milliseconds(200))
            #expect(workspace.snapshot?.repos.first?.changes.map(\.path).sorted() == ["a.txt", "late.txt"])

            // Nothing else was queued: no third scan follows.
            _ = await waitUntil(timeout: .milliseconds(600)) { applied > 2 }
            #expect(applied == 2)
        }

        @Test func aRequestAfterTheScanFinishedStartsANewScanRightAway() async {
            let repo = changedRepo()
            let workspace = Workspace(path: repo.path)
            workspace.refresh()
            #expect(await waitUntil { workspace.snapshot != nil })
            repo.write("b.txt", "b\n")
            workspace.refresh()
            #expect(await waitUntil { workspace.snapshot?.totalChangeCount == 2 })
        }
    }
}
