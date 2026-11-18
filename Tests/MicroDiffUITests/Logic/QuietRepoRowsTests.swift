import AppKit
import MicroDiffCore
import MicroDiffTestSupport
import Testing

@testable import MicroDiffUI

extension UITests {
    /// Nested repositories without changes in the changes tab: a header alone while there is something to pull or push.
    @MainActor
    @Suite
    struct QuietRepoRowsTests {
        /// An outer repository (one changed file, or none) with clean clones of remotes inside, kept alive together.
        private final class World {
            let outer = TestRepo()
            var remotes: [TestRemote] = []
            var seeds: [TestRepo] = []

            init(rootChanged: Bool = true) {
                outer.write("main.txt", "m\n")
                outer.commitAll("outer")
                if rootChanged { outer.write("main.txt", "changed\n") }
            }

            /// A clean clone of a new remote at `path`.
            @discardableResult
            func nest(_ path: String) -> TestRepo {
                let remote = TestRemote()
                let seed = remote.clone()
                outer.git("clone", "--quiet", remote.path, path)
                remotes.append(remote)
                seeds.append(seed)
                return seed
            }

            /// A clean submodule of a new remote at `path`, on `main` (registered and committed in the outer repository).
            func submodule(_ path: String) {
                let remote = TestRemote()
                seeds.append(remote.clone())
                remotes.append(remote)
                outer.git("submodule", "--quiet", "add", remote.path, path)
                outer.commitAll("add \(path)")
            }

            /// The remote of the clone at `index` gets a commit, and the clone fetches it.
            func behind(_ index: Int, _ path: String) {
                seeds[index].write("later.txt", "later\n")
                seeds[index].commitAll("later")
                seeds[index].git("push", "--quiet")
                outer.git("fetch", "--quiet", in: path)
            }

            func ahead(_ path: String) {
                outer.write(path + "/mine.txt", "mine\n")
                outer.commitAll("mine", in: path)
            }
        }

        private func rows(_ workspace: Workspace) -> [TreeRow] { workspace.sidebarRows() }
        private func headers(_ workspace: Workspace) -> [String] { rows(workspace).filter { $0.kind == .repo }.map(\.name) }

        @Test func aQuietRepositoryWithoutMarksIsNotListed() {
            let world = World()
            world.nest("inner")
            let workspace = scannedWorkspace(world.outer.path)
            #expect(headers(workspace) == [world.outer.path.split(separator: "/").last.map(String.init) ?? ""])
            #expect(workspace.snapshot?.quietRepos.count == 1)
        }

        @Test func behindFromWhatGitKnowsIsAHeaderAloneWithTheDownArrow() {
            let world = World()
            world.nest("inner")
            world.behind(0, "inner")
            let workspace = scannedWorkspace(world.outer.path)
            let all = rows(workspace)
            #expect(all.map(\.kind) == [.repo, .file, .repo])
            let header = all[2]
            #expect(header.name == "inner" && header.branch == "main" && header.gapBefore)
            #expect(header.sync == RepoSync(upstream: "origin/main", pull: true, push: false, checkedAt: nil))
            #expect(workspace.snapshot?.repos.count == 1)
            #expect(workspace.snapshot?.totalChangeCount == 1)
        }

        @Test func aheadAndBothAreMarkedToo() {
            let world = World()
            world.nest("ahead")
            world.nest("both")
            world.ahead("ahead")
            world.ahead("both")
            world.behind(1, "both")
            let workspace = scannedWorkspace(world.outer.path)
            let nested = rows(workspace).filter { $0.kind == .repo }.dropFirst()
            #expect(nested.map(\.name) == ["ahead", "both"])
            #expect(nested.first?.sync == RepoSync(upstream: "origin/main", pull: false, push: true))
            #expect(nested.last?.sync == RepoSync(upstream: "origin/main", pull: true, push: true))
        }

        @Test func theCountStaysAndTheNoChangesLineShowsOnlyWhileNothingElseIsListed() {
            let world = World(rootChanged: false)
            world.nest("inner")
            let quiet = scannedWorkspace(world.outer.path)
            #expect(rows(quiet).count == 1)
            #expect(quiet.sidebarEmptyMessage == "no changes")

            world.behind(0, "inner")
            let workspace = scannedWorkspace(world.outer.path)
            #expect(rows(workspace).filter { $0.kind == .repo }.count == 2)
            #expect(rows(workspace).count == 2)
            #expect(workspace.sidebarEmptyMessage == nil, "under a repository to pull the line would float in the empty space")
            #expect(workspace.snapshot?.totalChangeCount == 0)
            let controller = makeController(world.outer.path)
            controller.workspace.scanNow()
            #expect(controller.rootView.sidebarTabs.changeCount == 0)
            #expect(controller.rootView.tree.emptyMessage == nil)
        }

        @Test func theFilesTabIsUnchanged() {
            let world = World()
            world.nest("inner")
            world.behind(0, "inner")
            let workspace = scannedWorkspace(world.outer.path)
            workspace.selectSidebarTab(.files)
            #expect(rows(workspace).filter { $0.kind == .repo }.count == 1)
        }

        @Test func aFileChangeTurnsItIntoAnOrdinarySectionThatKeepsItsMarks() {
            let world = World()
            world.nest("inner")
            world.behind(0, "inner")
            let workspace = scannedWorkspace(world.outer.path)
            #expect(workspace.snapshot?.repos.count == 1)
            world.outer.write("inner/x.txt", "new\n")
            workspace.scanNow()
            #expect(workspace.snapshot?.repos.count == 2)
            #expect(workspace.snapshot?.quietRepos.isEmpty == true)
            let all = rows(workspace)
            #expect(all.map(\.kind) == [.repo, .file, .repo, .file])
            #expect(all[2].sync?.pull == true)
        }

        @Test func quietRepositoriesSitAmongTheSectionsByDisplayPath() {
            let world = World()
            world.nest("alpha-quiet")
            world.nest("mid-changed")
            world.nest("zeta-quiet")
            world.behind(0, "alpha-quiet")
            world.ahead("zeta-quiet")
            world.outer.write("mid-changed/f.txt", "x\n")
            let workspace = scannedWorkspace(world.outer.path)
            let names = headers(workspace)
            #expect(Array(names.dropFirst()) == ["alpha-quiet", "mid-changed", "zeta-quiet"])
        }

        @Test func aHeaderAloneDoesNothingWhenClicked() {
            let world = World()
            world.nest("inner")
            world.behind(0, "inner")
            let workspace = scannedWorkspace(world.outer.path)
            var refreshes = 0
            workspace.onSidebarChanged = { refreshes += 1 }
            let before = rows(workspace)
            let header = before[2]
            workspace.toggle(header)
            workspace.toggle(header)
            // It is only selected: nothing folds, and the sidebar is told once per click.
            #expect(refreshes == 2)
            #expect(rows(workspace) == before)
            #expect(workspace.selectedRowID == header.id)
            // A section header still folds.
            workspace.toggle(before[0])
            #expect(refreshes == 3)
            #expect(rows(workspace).map(\.kind) == [.repo, .repo])
        }

        @Test func aRepositoryThatGoesAwayLeavesNoRow() {
            let world = World()
            world.nest("inner")
            world.behind(0, "inner")
            let workspace = scannedWorkspace(world.outer.path)
            #expect(headers(workspace).count == 2)
            world.outer.remove("inner")
            workspace.scanNow()
            #expect(headers(workspace).count == 1)
        }

        // MARK: Clean submodules

        @Test func aCleanSubmoduleWithAMarkIsAHeaderAloneWithTheSubmoduleIcon() {
            let world = World(rootChanged: false)
            world.submodule("zeta")
            world.submodule("alpha")
            world.nest("mid-nested")
            world.behind(0, "zeta")      // seeds are in creation order: zeta, alpha, mid-nested
            world.ahead("mid-nested")
            let workspace = scannedWorkspace(world.outer.path)
            let all = rows(workspace).filter { $0.kind == .repo }
            #expect(all.map(\.name).dropFirst() == ["mid-nested", "zeta"], "by display path; alpha has no mark")
            #expect(all[2].isSubmodule && !all[1].isSubmodule)
            #expect(all[2].sync == RepoSync(upstream: "origin/main", pull: true, push: false, checkedAt: nil))
            #expect(TreeRowStyle(row: all[2], tab: .changes, isSelected: false).icon == .submodule)
            #expect(rows(workspace).count == 3, "nothing under them")
        }

        @Test func aSubmoduleHeaderGoesWhenTheMarkGoesAndComesBackAsASectionWithChanges() {
            let world = World(rootChanged: false)
            world.submodule("sub")
            world.behind(0, "sub")
            let workspace = scannedWorkspace(world.outer.path)
            #expect(headers(workspace).count == 2)
            world.outer.git("pull", "--quiet", "--ff-only", in: "sub")
            workspace.scanNow()
            #expect(headers(workspace).count == 1)

            world.outer.write("sub/x.txt", "new\n")
            workspace.scanNow()
            #expect(rows(workspace).map(\.kind) == [.repo, .repo, .file], "a normal section now")
            #expect(rows(workspace)[1].isSubmodule)
        }

        // MARK: After a remote check

        @Test func aRemoteCheckListsItAndAPullTakesItAwayWithoutAskingTheRemoteAgain() async throws {
            let world = World()
            world.nest("inner")
            // The remote moves and nobody fetches: git cannot know.
            world.seeds[0].write("later.txt", "later\n")
            world.seeds[0].commitAll("later")
            world.seeds[0].git("push", "--quiet")
            let folder = TempDir(prefix: "microdiff-quiet-log")
            let log = folder.path + "/calls"
            let fake = FakeGit.wrapping(logTo: log)
            let monitor = RemoteMonitor(checker: RemoteChecker(git: fake.runner), clock: Date.init)
            let workspace = Workspace(path: world.outer.path, remote: monitor)
            workspace.scanNow()
            #expect(headers(workspace).count == 1)

            monitor.enable()
            monitor.refresh()
            #expect(await waitUntil { headers(workspace).count == 2 })
            #expect(rows(workspace).last?.sync?.pull == true)
            #expect(rows(workspace).last?.sync?.checkedAt != nil)
            func remoteCalls() -> Int { (fileText(log) ?? "").split(separator: "\n").filter { $0.contains(" ls-remote ") }.count }
            #expect(remoteCalls() == 1, "only the nested repository follows a remote")

            world.outer.git("pull", "--quiet", "--ff-only", in: "inner")
            workspace.scanNow()
            #expect(await waitUntil { headers(workspace).count == 1 })
            #expect(await waitUntil { !monitor.isRunning })
            #expect(remoteCalls() == 1)
            monitor.stop()
            withExtendedLifetime((folder, fake)) {}
        }

        // MARK: Other readers of the repositories

        @Test func aFileInsideAQuietRepositoryHasItsOwnRepositoryAsTheBaseOfItsChangeBars() async {
            let world = World(rootChanged: false)
            let seed = world.nest("inner")
            seed.write("a.txt", "l1\nl2\nl3\n")
            seed.commitAll("a")
            seed.git("push", "--quiet")
            world.outer.git("pull", "--quiet", "origin", "main", in: "inner")
            let controller = editController(world.outer.path)
            controller.openForEdit("inner/a.txt")
            controller.showEdit(nil)
            controller.setCaret(4) // after "l1\n"... in "l2"
            controller.type("!")
            await controller.waitForMarks()
            #expect(controller.editorMarks == [.none, .modified, .none])
        }
    }
}
