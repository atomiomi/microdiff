import AppKit
import MicroDiffCore
import MicroDiffTestSupport
import Testing

@testable import MicroDiffUI

extension UITests {
    /// Backspace on the selected file of the files tab is "Move to Trash". Finder and the Trash are fakes.
    @MainActor
    @Suite
    struct DeleteKeyTests {
        @MainActor
        private struct Setup {
            let repo = Fixture.changesRepo()
            let actions = FakeFileActions()
            let prompts: FakePrompts
            let controller: MainWindowController

            init(answers: [Bool] = [], tab: SidebarTab = .files, open: Bool = true, mode: ViewMode = .read) {
                prompts = FakePrompts(trash: answers)
                controller = menuController(repo.path, tab: tab, prompts: prompts, actions: actions)
                if open { controller.openForEdit("README.md", mode: mode) }
            }
        }

        nonisolated static let presses: [(DeleteKey, NSEvent.ModifierFlags)] = [(.backspace, []), (.forwardDelete, []), (.backspace, .command), (.forwardDelete, .command)]

        // MARK: Tree focused

        @Test(arguments: DeleteKeyTests.presses)
        func theKeyAsksAboutTheSelectedFileAndConfirmingTrashesIt(press: (DeleteKey, NSEvent.ModifierFlags)) async {
            let (key, modifiers) = press
            let s = Setup(answers: [true])
            s.controller.focusSidebar()
            s.controller.press(key, modifiers: modifiers)
            #expect(s.prompts.trashQuestions == [TrashQuestion(name: "README.md", isFolder: false)])
            #expect(s.actions.trashed == [s.repo.path + "/README.md"])
            #expect(await waitUntil { s.controller.workspace.row(path: "README.md") == nil })
        }

        @Test func cancellingDoesNothing() async {
            let s = Setup(answers: [false])
            s.controller.focusSidebar()
            s.controller.press(.backspace)
            #expect(s.prompts.trashQuestions.count == 1)
            #expect(s.actions.trashed.isEmpty)
            await waitIdle(s.controller.workspace)
            #expect(exists(s.repo.path + "/README.md"))
        }

        @Test func theChangesTabIgnoresTheKey() {
            let s = Setup(answers: [true], tab: .changes, open: false)
            s.controller.openForEdit("src/app.swift", mode: .diff)
            s.controller.focusSidebar()
            #expect(s.controller.workspace.selectedRowID != nil)
            s.controller.press(.backspace)
            #expect(s.prompts.trashQuestions.isEmpty)
            #expect(s.actions.trashed.isEmpty)
        }

        @Test func noSelectedRowMeansNoQuestion() {
            let s = Setup(answers: [true], open: false)
            s.controller.focusSidebar()
            #expect(s.controller.workspace.selectedRowID == nil)
            s.controller.press(.backspace)
            #expect(s.prompts.trashQuestions.isEmpty)
            #expect(s.actions.trashed.isEmpty)
        }

        @Test func aSelectedFileThatVanishedFromDiskMeansNoQuestion() {
            let s = Setup(answers: [true])
            s.controller.focusSidebar()
            s.repo.remove("README.md")
            s.controller.press(.backspace)
            #expect(s.prompts.trashQuestions.isEmpty)
            #expect(s.actions.trashed.isEmpty)
        }

        @Test(arguments: [NSEvent.ModifierFlags.option, .control, .shift, [.command, .option], [.command, .shift]] as [NSEvent.ModifierFlags])
        func otherModifiersAreNotHandled(modifiers: NSEvent.ModifierFlags) {
            let s = Setup(answers: [true])
            s.controller.focusSidebar()
            s.controller.press(.backspace, modifiers: modifiers)
            s.controller.press(.forwardDelete, modifiers: modifiers)
            #expect(s.prompts.trashQuestions.isEmpty)
            #expect(s.actions.trashed.isEmpty)
        }

        // MARK: Selected folders and rows

        @Test func aSelectedFolderAsksWithTheFolderTextAndTrashesIt() async {
            let repo = treeRepo()
            let actions = FakeFileActions()
            let prompts = FakePrompts(trash: [true])
            let controller = menuController(repo.path, tab: .files, prompts: prompts, actions: actions)
            controller.click("dir", kind: .directory)
            controller.press(.backspace)
            #expect(prompts.trashQuestions.map(\.message) == ["Move “dir” and everything in it to the Trash?"])
            #expect(actions.trashed == [repo.path + "/dir"])
            #expect(await waitUntil { controller.workspace.row(path: "dir") == nil })
            #expect(controller.rootView.tree.selectedID == nil, "nothing is open to fall back to")
        }

        @Test func afterTrashingTheSelectionFallsBackToTheOpenFile() async {
            let repo = treeRepo()
            let prompts = FakePrompts(trash: [true])
            let controller = menuController(repo.path, tab: .files, prompts: prompts)
            controller.doubleClick("a.txt")
            controller.click("dir", kind: .directory)
            controller.press(.forwardDelete, modifiers: .command)
            #expect(await waitUntil { controller.workspace.row(path: "dir") == nil })
            #expect(controller.rootView.tree.selectedID == controller.workspace.row(path: "a.txt")?.id)
        }

        @Test func aSelectedFileRowAsksForTheFile() {
            let repo = treeRepo()
            let prompts = FakePrompts(trash: [false])
            let controller = menuController(repo.path, tab: .files, prompts: prompts)
            controller.click("code.swift")
            controller.press(.backspace)
            #expect(prompts.trashQuestions == [TrashQuestion(name: "code.swift", isFolder: false)])
        }

        @Test func theRootRowOffersNothing() {
            let repo = treeRepo()
            let prompts = FakePrompts(trash: [true])
            let actions = FakeFileActions()
            let controller = menuController(repo.path, tab: .files, prompts: prompts, actions: actions)
            controller.click("", kind: .repo)
            controller.press(.backspace)
            controller.press(.forwardDelete, modifiers: .command)
            #expect(prompts.trashQuestions.isEmpty)
            #expect(actions.trashed.isEmpty)
        }

        @Test func aSelectedFolderInTheChangesTabOffersNothing() {
            let repo = Fixture.changesRepo()
            let prompts = FakePrompts(trash: [true])
            let actions = FakeFileActions()
            let controller = menuController(repo.path, tab: .changes, prompts: prompts, actions: actions)
            controller.workspace.select(controller.workspace.row(path: "src", kind: .directory)!)
            controller.focusSidebar()
            controller.press(.backspace)
            #expect(prompts.trashQuestions.isEmpty)
            #expect(actions.trashed.isEmpty)
            withExtendedLifetime(repo) {}
        }

        // MARK: Focus elsewhere

        @Test func inTheEditorTheKeysOnlyDeleteText() {
            let s = Setup(answers: [true, true], mode: .edit)
            let controller = s.controller
            #expect(controller.isEditorFirstResponder)
            #expect(controller.workspace.selectedRowID != nil)
            let text = controller.editorText
            controller.setCaret(6)
            controller.press(.backspace)
            #expect(controller.editorText == "# fixure\n\nsome words\n")
            controller.press(.backspace, modifiers: .command)
            #expect(controller.editorText == "ure\n\nsome words\n")
            #expect(controller.editorText != text)
            #expect(s.prompts.trashQuestions.isEmpty)
            #expect(s.actions.trashed.isEmpty)
            #expect(exists(s.repo.path + "/README.md"))
        }

        @Test func inTheCodeViewThereIsNoQuestion() {
            let s = Setup(answers: [true])
            s.controller.focusCode()
            s.controller.press(.backspace)
            s.controller.press(.backspace, modifiers: .command)
            #expect(s.prompts.trashQuestions.isEmpty)
            #expect(s.actions.trashed.isEmpty)
        }

        // MARK: The menu item

        @Test func theMenuItemShowsCommandBackspaceWithoutBeingAShortcut() {
            let s = Setup()
            let item = s.controller.rowMenu("README.md")?.items.first { $0.title == "Move to Trash" }
            #expect(item?.keyEquivalent == "\u{8}")
            #expect(item?.keyEquivalentModifierMask == .command)
            #expect(item?.menu?.supermenu == nil)
        }
    }
}
