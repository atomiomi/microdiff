import MicroDiffCore
import MicroDiffTestSupport
import Testing
@testable import MicroDiffUI

extension UITests {
    @MainActor
    @Suite
    struct WorkspaceSidebarTests {
        private static let changes = Fixture.changesRepo()

        private func workspace(_ tab: SidebarTab = .changes) -> Workspace {
            let workspace = scannedWorkspace(Self.changes.path)
            workspace.sidebarTab = tab
            return workspace
        }

        // MARK: Changes tab

        @Test func changesTabStartsWithTheRepoRow() throws {
            let rows = workspace().sidebarRows()
            let first = try #require(rows.first)
            #expect(first.kind == .repo)
            #expect(first.name == folderName(Self.changes.path))
            #expect(first.branch == "main")
            #expect(first.depth == 0)
            #expect(first.isExpanded)
        }

        @Test func changesTabListsEveryChangedFileWithItsKind() {
            let rows = workspace().sidebarRows()
            let files = Dictionary(uniqueKeysWithValues: rows.filter { $0.kind == .file }.map { ($0.path, $0.change?.kind) })
            #expect(files == [
                "src/app.swift": .modified,
                "src/other.swift": .modified,
                "data.bin": .modified,
                "docs/old.txt": .deleted,
                "docs/renamed.txt": .renamed,
                "new/deep/fresh.txt": .added,
            ])
        }

        @Test func changesTabCompactsSingleChildFolders() {
            let rows = workspace().sidebarRows()
            #expect(rows.contains { $0.kind == .directory && $0.name == "new/deep" && $0.path == "new/deep" })
            #expect(!rows.contains { $0.kind == .file && $0.path == "README.md" })
        }

        @Test func changesTabRowIdsAreUnique() {
            let ids = workspace().sidebarRows().map(\.id)
            #expect(Set(ids).count == ids.count)
        }

        @Test func changesTabShowsASectionPerRepoWithAGapBeforeTheSecond() throws {
            let repo = Fixture.submoduleRepo()
            let rows = scannedWorkspace(repo.path).sidebarRows()
            let repoRows = rows.filter { $0.kind == .repo }
            #expect(repoRows.count == 2)
            #expect(repoRows[1].isSubmodule)
            #expect(repoRows[1].name == "vendor/lib")
            #expect(repoRows[1].gapBefore)
            #expect(!repoRows[0].gapBefore)
            let lib = try #require(rows.first { $0.kind == .file && $0.path == "lib.c" })
            #expect(lib.repoIndex == 1)
        }

        // MARK: Files tab

        @Test func filesTabStartsWithTheExpandedRootRow() throws {
            let rows = workspace(.files).sidebarRows()
            let root = try #require(rows.first)
            #expect(root.kind == .repo)
            #expect(root.name == folderName(Self.changes.path))
            #expect(root.path == "")
            #expect(root.isExpanded)
            #expect(root.repoIndex == 0)
        }

        @Test func filesTabListsFoldersBeforeFilesAndHidesDotGit() {
            let rows = workspace(.files).sidebarRows()
            let top = rows.filter { $0.depth == 1 }.map(\.name)
            #expect(top == ["docs", "new", "src", "data.bin", "README.md"])
            #expect(!rows.contains { $0.name == ".git" })
        }

        @Test func filesTabShowsTheDiskNotTheChanges() {
            let workspace = workspace(.files)
            // The deleted file is gone from disk, so it has no row; folders are collapsed until opened.
            workspace.toggle(workspace.row(path: "docs")!)
            #expect(workspace.row(path: "docs/old.txt") == nil)
            #expect(workspace.row(path: "docs/renamed.txt")?.change?.kind == .renamed)
        }

        @Test func filesTabMarksFoldersAndFilesThatChanged() {
            let workspace = workspace(.files)
            workspace.toggle(workspace.row(path: "src")!)
            workspace.toggle(workspace.row(path: "new")!)
            #expect(workspace.row(path: "src", kind: .directory)?.dirMark == .modified)
            #expect(workspace.row(path: "new", kind: .directory)?.dirMark == .added)
            #expect(workspace.row(path: "docs", kind: .directory)?.dirMark == .modified)
            #expect(workspace.row(path: "src/app.swift")?.change?.kind == .modified)
            #expect(workspace.row(path: "README.md")?.change == nil)
            #expect(workspace.row(path: "README.md")?.repoIndex == -1)
        }

        // MARK: Empty message

        @Test func emptyMessageIsNilWhileThereAreChanges() {
            #expect(workspace().sidebarEmptyMessage == nil)
        }

        @Test func emptyMessageSaysNoChangesForACleanRepo() {
            let repo = Fixture.cleanRepo()
            #expect(scannedWorkspace(repo.path).sidebarEmptyMessage == "no changes")
        }

        @Test func emptyMessageSaysNotAGitRepositoryForAPlainFolder() {
            let folder = Fixture.plainFolder()
            #expect(scannedWorkspace(folder.path).sidebarEmptyMessage == "not a git repository")
        }

        @Test func emptyMessageIsNeverShownInTheFilesTab() {
            let clean = Fixture.cleanRepo()
            let plain = Fixture.plainFolder()
            for path in [clean.path, plain.path, Self.changes.path] {
                let workspace = scannedWorkspace(path)
                workspace.sidebarTab = .files
                #expect(workspace.sidebarEmptyMessage == nil)
            }
        }

        @Test func plainFolderStillListsItsFilesInTheFilesTab() {
            let folder = Fixture.plainFolder()
            let workspace = scannedWorkspace(folder.path)
            workspace.selectSidebarTab(.files)
            let rows = workspace.sidebarRows()
            #expect(rows.first?.repoIndex == -1)
            #expect(rows.first?.branch == nil)
            #expect(rows.map(\.name).contains("top.txt"))
            #expect(workspace.sidebarRows().count == 3)
        }

        // MARK: Toggle

        @Test func togglingTheRepoRowCollapsesAndReExpandsTheChangesTab() throws {
            let workspace = workspace()
            let all = workspace.sidebarRows()
            let repoRow = try #require(all.first)

            workspace.toggle(repoRow)
            let collapsed = workspace.sidebarRows()
            #expect(collapsed.count == 1)
            #expect(collapsed[0].isExpanded == false)

            workspace.toggle(collapsed[0])
            #expect(workspace.sidebarRows() == all)
        }

        @Test func togglingAFolderRowHidesAndShowsItsFilesInTheChangesTab() throws {
            let workspace = workspace()
            let srcRow = try #require(workspace.row(path: "src", kind: .directory))
            #expect(workspace.row(path: "src/app.swift") != nil)

            workspace.toggle(srcRow)
            #expect(workspace.row(path: "src/app.swift") == nil)
            #expect(workspace.row(path: "src", kind: .directory)?.isExpanded == false)
            #expect(workspace.row(path: "docs/old.txt") != nil)

            workspace.toggle(try #require(workspace.row(path: "src", kind: .directory)))
            #expect(workspace.row(path: "src/app.swift") != nil)
        }

        @Test func togglingFoldersInTheFilesTabExpandsAndCollapses() throws {
            let workspace = workspace(.files)
            #expect(workspace.row(path: "src/app.swift") == nil)

            workspace.toggle(try #require(workspace.row(path: "src", kind: .directory)))
            #expect(workspace.row(path: "src/app.swift") != nil)
            #expect(workspace.row(path: "src", kind: .directory)?.isExpanded == true)

            workspace.toggle(try #require(workspace.row(path: "src", kind: .directory)))
            #expect(workspace.row(path: "src/app.swift") == nil)
        }

        @Test func togglingTheRootRowInTheFilesTabHidesEverything() throws {
            let workspace = workspace(.files)
            workspace.toggle(try #require(workspace.sidebarRows().first))
            #expect(workspace.sidebarRows().count == 1)
            workspace.toggle(try #require(workspace.sidebarRows().first))
            #expect(workspace.sidebarRows().count > 1)
        }

        @Test func collapsingInOneTabDoesNotCollapseTheOther() throws {
            let workspace = workspace()
            workspace.toggle(try #require(workspace.sidebarRows().first))
            workspace.selectSidebarTab(.files)
            #expect(workspace.sidebarRows().count > 1)
        }

        @Test func togglingNotifiesTheSidebar() throws {
            let workspace = workspace()
            var calls = 0
            workspace.onSidebarChanged = { calls += 1 }
            workspace.toggle(try #require(workspace.sidebarRows().first))
            #expect(calls == 1)
        }

        // MARK: Opening rows

        @Test func openingAChangesRowOpensADiffTab() throws {
            let workspace = workspace()
            workspace.open(try #require(workspace.row(path: "src/app.swift")), pin: false)
            let tab = try #require(workspace.tabs.first)
            #expect(workspace.tabs.count == 1)
            #expect(tab.path == Self.changes.path + "/src/app.swift")
            #expect(tab.mode == .diff)
            #expect(tab.change?.kind == .modified)
            #expect(tab.isPreview)
        }

        @Test func openingAFilesRowOpensAFileTab() throws {
            let workspace = workspace(.files)
            workspace.toggle(try #require(workspace.row(path: "src", kind: .directory)))
            workspace.open(try #require(workspace.row(path: "src/app.swift")), pin: true)
            let tab = try #require(workspace.tabs.first)
            #expect(tab.mode == .read)
            #expect(tab.path == Self.changes.path + "/src/app.swift")
            #expect(tab.change?.kind == .modified)
            #expect(tab.isPreview == false)
        }

        @Test func openingAFolderOrRepoRowDoesNothing() throws {
            let workspace = workspace()
            workspace.open(try #require(workspace.sidebarRows().first), pin: true)
            workspace.open(try #require(workspace.row(path: "src", kind: .directory)), pin: true)
            #expect(workspace.tabs.isEmpty)
        }

        @Test func openingAChangedFileInASubmoduleUsesThatRepository() throws {
            let repo = Fixture.submoduleRepo()
            let workspace = scannedWorkspace(repo.path)
            workspace.open(try #require(workspace.row(path: "lib.c")), pin: true)
            #expect(workspace.tabs.first?.path == repo.path + "/vendor/lib/lib.c")
            #expect(workspace.tabs.first?.repoIndex == 1)
        }
    }

}
