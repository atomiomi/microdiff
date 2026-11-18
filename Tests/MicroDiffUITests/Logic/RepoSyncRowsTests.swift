import AppKit
import MicroDiffCore
import MicroDiffTestSupport
import Testing

@testable import MicroDiffUI

extension UITests {
    /// What the sidebar rows of repositories carry about pulling and pushing, from what git already knows.
    @MainActor
    @Suite
    struct RepoSyncRowsTests {
        /// An outer repository that is behind after a fetch, with a nested clone that has an unpushed commit and a change.
        private func fixture() -> (outer: TestRepo, remotes: [TestRemote]) {
            let outerRemote = TestRemote()
            let innerRemote = TestRemote()
            let outer = outerRemote.clone()
            let other = outerRemote.clone(pushingFirstCommit: false)
            other.write("later.txt", "later\n")
            other.commitAll("later")
            other.git("push", "--quiet")
            outer.git("fetch", "--quiet")

            outer.git("clone", "--quiet", innerRemote.path, "inner")
            let inner = innerRemote.clone()
            _ = inner
            outer.git("-C", "inner", "pull", "--quiet", "origin", "main")
            outer.write("inner/own.txt", "mine\n")
            outer.git("add", "own.txt", in: "inner")
            outer.git("commit", "--quiet", "-m", "mine", in: "inner")
            outer.write("inner/dirty.txt", "uncommitted\n")
            return (outer, [outerRemote, innerRemote])
        }

        @Test func bothSidebarTabsMarkTheRepositoryRows() {
            let (outer, remotes) = fixture()
            withExtendedLifetime(remotes) {
                let workspace = scannedWorkspace(outer.path)
                let changes = workspace.sidebarRows().filter { $0.kind == .repo }
                #expect(changes.count == 2)
                #expect(changes[0].sync == RepoSync(upstream: "origin/main", pull: true, push: false, checkedAt: nil))
                #expect(changes[1].sync?.push == true)
                #expect(changes[1].sync?.pull == false)

                workspace.selectSidebarTab(.files)
                let root = workspace.sidebarRows().first { $0.kind == .repo }
                #expect(root?.sync == RepoSync(upstream: "origin/main", pull: true, push: false, checkedAt: nil))
            }
        }

        @Test func aRepositoryWithNothingToDoHasNoMark() {
            let remote = TestRemote()
            let repo = remote.clone()
            let workspace = scannedWorkspace(repo.path)
            #expect(workspace.sidebarRows().allSatisfy { $0.sync == nil })
            let plain = TestRepo()
            plain.write("a.txt", "x\n")
            plain.commitAll("first")
            #expect(scannedWorkspace(plain.path).sidebarRows().allSatisfy { $0.sync == nil })
        }

        @Test func aDetachedHeadHasNoMark() {
            let remote = TestRemote()
            let repo = remote.clone()
            repo.write("b.txt", "x\n")
            repo.commitAll("ahead")
            repo.git("checkout", "--quiet", "--detach")
            #expect(scannedWorkspace(repo.path).sidebarRows().allSatisfy { $0.sync == nil })
        }

        @Test func theMarksFollowWhatTheRemoteChecksFound() async {
            let remote = TestRemote()
            let repo = remote.clone()
            let other = remote.clone(pushingFirstCommit: false)
            other.write("later.txt", "later\n")
            other.commitAll("later")
            other.git("push", "--quiet")
            let monitor = RemoteMonitor(clock: { Date() })
            let workspace = Workspace(path: repo.path, remote: monitor)
            workspace.scanNow()
            #expect(workspace.sidebarRows().first?.sync == nil)
            var refreshed = 0
            workspace.onSidebarChanged = { refreshed += 1 }
            monitor.enable()
            monitor.refresh()
            #expect(await waitUntil { workspace.sidebarRows().first?.sync?.pull == true })
            #expect(refreshed >= 1)
            monitor.stop()
        }
    }
}
