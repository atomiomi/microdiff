import AppKit
import MicroDiffCore
import MicroDiffTestSupport
import Testing

@testable import MicroDiffUI

extension UITests {
    /// The tree's own selected row: folders and repository rows can be selected, the keys move it through every row.
    @MainActor
    @Suite
    struct TreeSelectionTests {
        private func controller(_ repo: TestRepo) -> MainWindowController {
            menuController(repo.path, tab: .files)
        }

        private func id(_ c: MainWindowController, _ path: String, kind: TreeRowKind? = nil) -> String? {
            c.workspace.row(path: path, kind: kind)?.id
        }

        private func selected(_ c: MainWindowController) -> String? { c.rootView.tree.selectedID }

        // MARK: Clicks

        @Test func clickingAFolderSelectsAndOpensIt() {
            let repo = treeRepo()
            let c = controller(repo)
            c.click("dir", kind: .directory)
            #expect(c.workspace.selectedRowID == id(c, "dir"))
            #expect(selected(c) == id(c, "dir"))
            #expect(c.workspace.row(path: "dir")?.isExpanded == true)
            #expect(c.workspace.row(path: "dir/inner.txt") != nil)
            #expect(c.workspace.tabs.isEmpty)
            c.click("dir", kind: .directory)
            #expect(c.workspace.row(path: "dir/inner.txt") == nil)
            #expect(selected(c) == id(c, "dir"))
        }

        @Test func clickingTheRepositoryRowSelectsAndFoldsIt() {
            let repo = treeRepo()
            let c = controller(repo)
            c.click("", kind: .repo)
            #expect(selected(c) == id(c, "", kind: .repo))
            #expect(c.workspace.sidebarRows().count == 1)
        }

        @Test func clickingAFileSelectsItAndOpensThePreview() {
            let repo = treeRepo()
            let c = controller(repo)
            c.click("dir", kind: .directory)
            c.click("b.txt")
            #expect(selected(c) == id(c, "b.txt"))
            #expect(c.workspace.tabNames == ["b.txt"])
        }

        // MARK: Keys

        @Test func theArrowKeysMoveThroughEveryRowAndOnlyFilesOpen() {
            let repo = treeRepo()
            let c = controller(repo)
            c.focusSidebar()
            c.pressKey(125)
            #expect(selected(c) == id(c, "", kind: .repo))
            c.pressKey(125)
            #expect(selected(c) == id(c, "dir"))
            #expect(c.workspace.tabs.isEmpty)
            c.pressKey(125)
            #expect(selected(c) == id(c, "a.txt"))
            #expect(c.workspace.tabNames == ["a.txt"])
            c.pressKey(125)
            c.pressKey(125)
            #expect(c.workspace.tabNames == ["code.swift"])
            c.pressKey(126)
            c.pressKey(126)
            c.pressKey(126)
            #expect(selected(c) == id(c, "dir"))
            #expect(c.workspace.tabNames == ["a.txt"], "a folder leaves the open tab alone")
        }

        @Test func leftAndRightOnFolders() {
            let repo = treeRepo()
            let c = controller(repo)
            c.click("dir", kind: .directory)
            c.pressKey(123)
            #expect(c.workspace.row(path: "dir")?.isExpanded == false)
            c.pressKey(124)
            #expect(c.workspace.row(path: "dir")?.isExpanded == true)
            c.pressKey(124)
            #expect(selected(c) == id(c, "dir/sub"), "an open folder goes to its first child")
            c.pressKey(124)
            #expect(c.workspace.row(path: "dir/sub/deep.swift") != nil)
            c.pressKey(123)
            c.pressKey(123)
            #expect(selected(c) == id(c, "dir"), "a closed folder goes to its parent")
            #expect(c.workspace.tabs.isEmpty)
        }

        @Test func leftOnAFileGoesToTheFolderAndTheTopLevelStays() {
            let repo = treeRepo()
            let c = controller(repo)
            c.click("a.txt")
            c.pressKey(123)
            #expect(selected(c) == id(c, "", kind: .repo))
            c.pressKey(123)
            #expect(c.workspace.sidebarRows().count == 1, "the open root closes")
            c.pressKey(123)
            #expect(selected(c) == id(c, "", kind: .repo))
            #expect(c.workspace.sidebarRows().count == 1)
            c.pressKey(124)
            #expect(c.workspace.sidebarRows().count > 1)
        }

        @Test func returnOnAFolderOpensAndClosesIt() {
            let repo = treeRepo()
            let c = controller(repo)
            c.click("dir", kind: .directory)
            c.pressKey(36)
            #expect(c.workspace.row(path: "dir")?.isExpanded == false)
            c.pressKey(36)
            #expect(c.workspace.row(path: "dir")?.isExpanded == true)
            #expect(c.workspace.tabs.isEmpty)
        }

        // MARK: Following the open file

        @Test func aTabClickBringsTheSelectionToItsFile() {
            let repo = treeRepo()
            let c = controller(repo)
            c.doubleClick("a.txt")
            c.doubleClick("b.txt")
            c.click("dir", kind: .directory)
            c.workspace.selectTab(0)
            #expect(selected(c) == id(c, "a.txt"))
        }

        @Test func closingATabBringsTheSelectionToTheOpenFile() {
            let repo = treeRepo()
            let c = controller(repo)
            c.doubleClick("a.txt")
            c.doubleClick("b.txt")
            c.click("dir", kind: .directory)
            c.requestCloseTab(1)
            #expect(selected(c) == id(c, "a.txt"))
        }

        @Test func switchingTheSidebarTabBringsTheSelectionToTheOpenFile() {
            let repo = treeRepo()
            let c = controller(repo)
            c.doubleClick("a.txt")
            c.click("dir", kind: .directory)
            c.workspace.selectSidebarTab(.changes)
            c.workspace.selectSidebarTab(.files)
            #expect(selected(c) == id(c, "a.txt"))
        }

        @Test func aFileOpenedByOtherMeansBringsTheSelectionToIt() {
            let repo = treeRepo()
            let c = controller(repo)
            c.click("dir", kind: .directory)
            c.openForEdit("b.txt", mode: .read)
            #expect(selected(c) == id(c, "b.txt"))
        }

        // MARK: Rescans

        @Test func theSelectionSurvivesARescan() {
            let repo = treeRepo()
            let c = controller(repo)
            c.doubleClick("a.txt")
            c.click("dir", kind: .directory)
            let dir = id(c, "dir")
            repo.write("new.txt", "new\n")
            c.workspace.scanNow()
            #expect(c.workspace.selectedRowID == dir)
            #expect(selected(c) == dir)
        }

        @Test func whenTheSelectedRowIsGoneTheOpenFileIsSelected() {
            let repo = treeRepo()
            let c = controller(repo)
            c.doubleClick("a.txt")
            c.click("dir", kind: .directory)
            repo.remove("dir")
            c.workspace.scanNow()
            #expect(selected(c) == id(c, "a.txt"))
        }

        @Test func whenNothingIsOpenAndTheSelectedRowIsGoneNothingIsSelected() {
            let repo = treeRepo()
            let c = controller(repo)
            c.click("dir", kind: .directory)
            repo.remove("dir")
            c.workspace.scanNow()
            #expect(selected(c) == nil)
        }

        @Test func theMenuOfAnotherRowDoesNotMoveTheSelection() {
            let repo = treeRepo()
            let c = controller(repo)
            c.click("dir", kind: .directory)
            _ = c.rowMenu("a.txt")
            #expect(selected(c) == id(c, "dir"))
        }
    }
}
