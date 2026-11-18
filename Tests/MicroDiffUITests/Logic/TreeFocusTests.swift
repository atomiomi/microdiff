import AppKit
import MicroDiffCore
import MicroDiffTestSupport
import Testing

@testable import MicroDiffUI

extension UITests {
    /// Where the keyboard goes when a file is opened from the tree.
    @MainActor
    @Suite
    struct TreeFocusTests {
        private func controller(_ repo: TestRepo, prompts: FakePrompts = FakePrompts()) -> MainWindowController {
            menuController(repo.path, tab: .files, prompts: prompts)
        }

        @Test func aSingleClickOnATextFileOpensItInEditModeWithoutTakingTheKeyboard() {
            let repo = treeRepo()
            let c = controller(repo)
            c.click("a.txt")
            #expect(c.workspace.tabs.map(\.mode) == [.edit])
            #expect(c.workspace.tabs[0].isPreview)
            #expect(c.rootView.showsEditor)
            #expect(c.editorText == "alpha\nbeta\n")
            #expect(c.treeHasKeyboard)
            #expect(!c.isEditorFirstResponder)
        }

        @Test func backspaceRightAfterAClickAsksToTrashAndTypingDoesNotChangeTheText() {
            let repo = treeRepo()
            let prompts = FakePrompts(trash: [false])
            let c = controller(repo, prompts: prompts)
            c.click("a.txt")
            c.pressKey(0, characters: "x")
            #expect(c.editorText == "alpha\nbeta\n")
            c.press(.backspace)
            #expect(prompts.trashQuestions == [TrashQuestion(name: "a.txt", isFolder: false)])
            #expect(c.editorText == "alpha\nbeta\n")
            #expect(exists(repo.path + "/a.txt"))
        }

        @Test func aDoubleClickKeepsTheTabAndMovesTheKeyboardToTheEditor() {
            let repo = treeRepo()
            let c = controller(repo)
            c.doubleClick("a.txt")
            #expect(c.workspace.tabs[0].isPreview == false)
            #expect(c.isEditorFirstResponder)
        }

        @Test func aDoubleClickOnACodeFileMovesTheKeyboardToTheCodeView() {
            let repo = treeRepo()
            let c = controller(repo)
            c.click("code.swift")
            #expect(c.treeHasKeyboard)
            c.doubleClick("code.swift")
            #expect(c.workspace.tabs[0].mode == .read)
            #expect(c.codeViewHasKeyboard)
        }

        @Test func returnKeepsTheSelectedFileAndMovesTheKeyboardToTheMainArea() {
            let repo = treeRepo()
            let c = controller(repo)
            c.click("a.txt")
            c.pressKey(36)
            #expect(c.workspace.tabs[0].isPreview == false)
            #expect(c.isEditorFirstResponder)
            c.click("code.swift")
            c.pressKey(76)
            #expect(c.workspace.tabs.count == 2)
            #expect(c.codeViewHasKeyboard)
        }

        @Test func theArrowKeysKeepWorkingAcrossEditModeFiles() {
            let repo = treeRepo()
            let c = controller(repo)
            c.click("a.txt")
            c.pressKey(125)
            #expect(c.workspace.tabNames == ["b.txt"])
            #expect(c.workspace.tabs[0].mode == .edit)
            #expect(c.treeHasKeyboard)
            c.pressKey(125)
            #expect(c.workspace.tabNames == ["code.swift"])
            c.pressKey(126)
            c.pressKey(126)
            #expect(c.workspace.tabNames == ["a.txt"])
            #expect(c.treeHasKeyboard)
        }

        @Test func clickingAFileTabStillMovesTheKeyboardToItsEditor() {
            let repo = treeRepo()
            let c = controller(repo)
            c.doubleClick("a.txt")
            c.doubleClick("code.swift")
            c.focusSidebar()
            c.rootView.tabBar.onSelect?(0)
            #expect(c.isEditorFirstResponder)
        }

        @Test func theModeKeysStillMoveTheKeyboardToTheEditor() {
            let repo = treeRepo()
            let c = controller(repo)
            c.click("code.swift")
            c.showEdit(nil)
            #expect(c.isEditorFirstResponder)
            c.showRead(nil)
            #expect(!c.isEditorFirstResponder)
        }

        @Test func aFileOpenedByOtherMeansStillTakesTheKeyboard() {
            let repo = treeRepo()
            let c = controller(repo)
            c.focusSidebar()
            c.openForEdit("a.txt", mode: .edit)
            #expect(c.isEditorFirstResponder)
        }
    }
}
