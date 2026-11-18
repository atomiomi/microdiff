import CoreGraphics
import MicroDiffCore
import MicroDiffTestSupport
import Testing
@testable import MicroDiffUI

extension UITests {
    @MainActor
    @Suite
    struct WorkspaceContentTests {
        private static let repo = Fixture.changesRepo()

        private func opened(_ relative: String, mode: ViewMode = .diff) -> Workspace {
            let workspace = scannedWorkspace(Self.repo.path)
            workspace.open(Self.repo, relative, mode: mode)
            return workspace
        }

        @Test func modifiedFileOpensAsADiff() throws {
            let document = try #require(opened("src/app.swift").content?.document)
            #expect(document.kind == .diff)
            #expect(document.patch.hunks.count == 2)
            #expect(document.rows.foldCount >= 2)
            #expect(document.newText.lineCount == 40)
        }

        @Test func modifiedFileInFileModeOpensAsTheWholeFileWithMarks() throws {
            let document = try #require(opened("src/app.swift", mode: .read).content?.document)
            #expect(document.kind == .file)
            #expect(document.rows.rowCount == 40)
            #expect(document.rows.foldCount == 0)
        }

        @Test func untrackedFileOpensAsPlainText() throws {
            let document = try #require(opened("new/deep/fresh.txt").content?.document)
            #expect(document.kind == .plain)
            #expect(document.rows.rowCount == 2)
            #expect(document.firstLine == "fresh file")
        }

        @Test func deletedFileOpensWithItsOldContents() throws {
            let workspace = opened("docs/old.txt")
            let document = try #require(workspace.content?.document)
            #expect(document.kind == .deleted)
            #expect(document.firstLine == "old one")
            #expect(document.rows.rowCount == 2)
            #expect(workspace.tabs[0].change?.kind == .deleted)
        }

        @Test func unchangedRenameOpensAsPlainText() throws {
            let workspace = opened("docs/renamed.txt")
            #expect(workspace.tabs[0].change?.kind == .renamed)
            #expect(workspace.content?.document?.firstLine == "will be renamed")
        }

        @Test func binaryFileShowsTheBinaryMessage() {
            #expect(opened("data.bin").content?.message == "binary file")
        }

        @Test func missingFileShowsTheNotFoundMessage() {
            let workspace = scannedWorkspace(Self.repo.path)
            workspace.open(Self.repo, "src/never-existed.swift")
            #expect(workspace.content?.message == "file not found")
        }

        @Test func unchangedFileOpensAsPlainText() throws {
            let document = try #require(opened("README.md", mode: .read).content?.document)
            #expect(document.kind == .plain)
            #expect(document.firstLine == "# fixture")
        }

        @Test func fileInsideTheSubmoduleOpensWithItsDiff() throws {
            let repo = Fixture.submoduleRepo()
            let workspace = scannedWorkspace(repo.path)
            workspace.open(repo, "vendor/lib/lib.c")
            let document = try #require(workspace.content?.document)
            #expect(document.kind == .diff)
            #expect(document.patch.hunks.count == 1)
            #expect(workspace.tabs[0].change?.kind == .modified)
            #expect(workspace.tabs[0].repoIndex == 1)
        }

        @Test func fileOutsideTheWorkspaceOpensWithoutChanges() throws {
            let other = Fixture.plainFolder()
            let workspace = scannedWorkspace(Self.repo.path)
            workspace.openFile(other.path + "/top.txt", mode: .read, pin: true, synchronously: true)
            #expect(workspace.tabs[0].change == nil)
            #expect(workspace.content?.document?.firstLine == "top")
            workspace.selectSidebarTab(.files)
            #expect(workspace.selectedRowID == nil)
        }

        @Test func contentCallbackReportsScrollKeepingOnlyForTheSameFile() async {
            let workspace = opened("src/app.swift")
            var keeps: [Bool] = []
            workspace.onContentChanged = { keeps.append($0) }
            workspace.open(Self.repo, "src/other.swift")
            #expect(keeps == [false])
            workspace.setMode(.read)
            _ = await waitUntil { keeps.count == 2 }
            #expect(keeps == [false, false])
        }
    }

    @MainActor
    @Suite
    struct WorkspaceRescanTests {
        private func count(_ tab: Workspace) -> Int { tab.snapshot?.totalChangeCount ?? -1 }

        @Test func rescanAfterRevertingAFileDropsItsChange() async throws {
            let repo = Fixture.changesRepo()
            let workspace = scannedWorkspace(repo.path)
            workspace.open(repo, "src/app.swift")
            #expect(workspace.tabs[0].change?.kind == .modified)
            #expect(count(workspace) == 6)

            repo.git("checkout", "--", "src/app.swift")
            workspace.scanNow()

            #expect(count(workspace) == 5)
            #expect(workspace.snapshot?.repos[0].changes.contains { $0.path == "src/app.swift" } == false)
            #expect(workspace.row(path: "src/app.swift") == nil)
            #expect(workspace.tabs[0].change == nil)
            #expect(workspace.tabs[0].repoIndex == nil)
            #expect(workspace.selectedRowID == nil)
            // The open tab now shows the file as it is, without a diff.
            let loaded = await waitUntil { workspace.content?.document?.kind == .plain }
            #expect(loaded)
        }

        @Test func rescanAfterEditingAFileTurnsItsTabIntoADiff() async {
            let repo = Fixture.cleanRepo()
            let workspace = scannedWorkspace(repo.path)
            workspace.open(repo, "README.md")
            #expect(workspace.content?.document?.kind == .plain)

            repo.write("README.md", "# clean\nand now changed\n")
            workspace.scanNow()

            #expect(count(workspace) == 1)
            #expect(workspace.tabs[0].change?.kind == .modified)
            #expect(workspace.tabs[0].repoIndex == 0)
            #expect(await waitUntil { workspace.content?.document?.kind == .diff })
        }

        @Test func rescanShowsNewFilesInBothTabs() {
            let repo = Fixture.cleanRepo()
            let workspace = scannedWorkspace(repo.path)
            #expect(workspace.sidebarEmptyMessage == "no changes")

            repo.write("brand-new.txt", "hello\n")
            workspace.scanNow()

            #expect(workspace.sidebarEmptyMessage == nil)
            #expect(workspace.row(path: "brand-new.txt")?.change?.kind == .added)
            workspace.selectSidebarTab(.files)
            #expect(workspace.row(path: "brand-new.txt")?.change?.kind == .added)
        }

        @Test func rescanNotifiesTheTabsOnlyWhenTheStatusChanged() {
            let repo = Fixture.changesRepo()
            let workspace = scannedWorkspace(repo.path)
            workspace.open(repo, "src/app.swift")
            var tabs = 0, sidebar = 0
            workspace.onTabsChanged = { tabs += 1 }
            workspace.onSidebarChanged = { sidebar += 1 }

            workspace.scanNow()
            #expect(tabs == 0)
            #expect(sidebar == 1)

            repo.git("checkout", "--", "src/other.swift")
            workspace.scanNow()
            #expect(tabs == 1)
            #expect(sidebar == 2)
        }

        @Test func rescanKeepsTheContentOfAnUnchangedFileUntouched() async {
            let repo = Fixture.changesRepo()
            let workspace = scannedWorkspace(repo.path)
            workspace.open(repo, "src/app.swift")
            var contentCallbacks = 0
            workspace.onContentChanged = { _ in contentCallbacks += 1 }

            workspace.scanNow()
            // Give the background reload time to finish; it must find nothing new to show.
            try? await Task.sleep(for: .milliseconds(150))
            #expect(contentCallbacks == 0)
        }

        @Test func rescanKeepsScrollWhenTheFileOnDiskChanges() async {
            let repo = Fixture.changesRepo()
            let workspace = scannedWorkspace(repo.path)
            workspace.open(repo, "src/app.swift")
            workspace.rememberScroll(CGPoint(x: 0, y: 300))
            var keeps: [Bool] = []
            workspace.onContentChanged = { keeps.append($0) }

            repo.write("src/app.swift", Fixture.numberedLines(replacing: [20: "let value20 = 1"]))
            workspace.scanNow()

            #expect(await waitUntil { !keeps.isEmpty })
            #expect(keeps == [true])
            #expect(workspace.activeScroll == CGPoint(x: 0, y: 300))
        }

        @Test func filesTabPicksUpFilesThatGitIgnoresAfterARescan() {
            let repo = Fixture.cleanRepo()
            repo.write(".gitignore", "*.log\n")
            repo.commitAll("ignore logs")
            let workspace = scannedWorkspace(repo.path)
            workspace.selectSidebarTab(.files)
            #expect(workspace.row(path: "debug.log") == nil)

            repo.write("debug.log", "line\n")
            workspace.scanNow()

            // git status is the same, but the folder is not.
            #expect(count(workspace) == 0)
            #expect(workspace.row(path: "debug.log") != nil)
        }

        @Test func rescanOfADeletedFileOnDiskTurnsItsTabIntoADeletedDocument() async {
            let repo = Fixture.cleanRepo()
            let workspace = scannedWorkspace(repo.path)
            workspace.open(repo, "README.md", mode: .read)

            repo.remove("README.md")
            workspace.scanNow()

            #expect(workspace.tabs[0].change?.kind == .deleted)
            #expect(await waitUntil { workspace.content?.document?.kind == .deleted })
            #expect(workspace.content?.document?.firstLine == "# clean")
        }
    }

}
