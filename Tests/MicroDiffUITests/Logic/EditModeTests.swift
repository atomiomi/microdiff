import AppKit
import MicroDiffCore
import MicroDiffTestSupport
import Testing
@testable import MicroDiffUI

extension UITests {
    /// The edit mode as the user drives it: switching modes, typing, undo, saving. Real window controller, never shown.
    @MainActor
    @Suite
    struct EditModeTests {
        private func path(_ repo: TestRepo, _ relative: String) -> String { repo.path + "/" + relative }

        // MARK: Nothing until it is used

        @Test func nothingOfTheEditorExistsUntilEditModeIsUsed() {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.openForEdit("a.txt", mode: .diff)
            controller.openForEdit("b.txt", mode: .diff)
            controller.showRead(nil)
            controller.showDiff(nil)
            controller.workspace.selectTab(0)
            #expect(controller.editor == nil)
            #expect(controller.workspace.buffers.isEmpty)
            #expect(!controller.rootView.subviews.contains { $0 is EditorView })
        }

        // MARK: Switching modes

        @Test func commandEEntersEditAndGoesBackToTheModeBefore() async throws {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.openForEdit("b.txt", mode: .diff)
            controller.showEdit(nil)
            #expect(controller.workspace.tabs[0].mode == .edit)
            #expect(controller.editorText == "one\ntwo\nthree\n")
            #expect(controller.rootView.showsEditor)
            #expect(controller.rootView.codeView.isHidden)
            #expect(controller.isEditorFirstResponder)

            controller.showDiff(nil)
            #expect(controller.workspace.tabs[0].mode == .diff)
            await waitIdle(controller.workspace)
            #expect(!controller.rootView.showsEditor)

            controller.showRead(nil)
            controller.showEdit(nil)
            controller.showRead(nil)
            #expect(controller.workspace.tabs[0].mode == .read)
        }

        @Test func commandDFromEditGoesToTheDiff() {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.openForEdit("b.txt", mode: .read)
            controller.showEdit(nil)
            controller.showDiff(nil)
            #expect(controller.workspace.tabs[0].mode == .diff)
            controller.showRead(nil)
            #expect(controller.workspace.tabs[0].mode == .read)
        }

        @Test func clickingTheSwitchWordsSetsEachMode() {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.openForEdit("b.txt", mode: .diff)
            let bar = controller.rootView.tabBar
            for mode in [ViewMode.edit, .read, .edit, .diff] {
                bar.onMode?(mode)
                #expect(controller.workspace.tabs[0].mode == mode)
                #expect(bar.mode == mode)
            }
        }

        @Test(arguments: [ViewMode.diff, .read, .edit])
        func eachModeKeyGoesStraightToItsModeFromTheOtherTwo(target: ViewMode) async {
            let repo = editRepo()
            let controller = editController(repo.path)
            for start in ViewMode.allCases where start != target {
                controller.openForEdit("b.txt", mode: start)
                controller.workspace.setMode(start)
                await waitIdle(controller.workspace)
                press(controller, target)
                #expect(controller.workspace.tabs[0].mode == target, "from \(start)")
                #expect(controller.rootView.tabBar.mode == target)
            }
        }

        @Test(arguments: [ViewMode.diff, .read, .edit])
        func theKeyOfTheCurrentModeChangesNothing(mode: ViewMode) async {
            let repo = TestRepo()
            repo.write("long.txt", numberedText(400))
            repo.commitAll("first")
            repo.write("long.txt", numberedText(400).replacingOccurrences(of: "line", with: "changed"))
            let controller = editController(repo.path)
            controller.openForEdit("long.txt", mode: mode)
            await waitIdle(controller.workspace)
            if mode == .edit {
                controller.scrollEditor(toLine: 100)
            } else {
                controller.rootView.codeView.scroll(to: CGPoint(x: 0, y: 1100))
            }
            let before = mode == .edit ? controller.editorScroll.y : controller.rootView.codeView.scrollOffset.y
            let generation = controller.workspace.loadGeneration
            press(controller, mode)
            #expect(!controller.workspace.isLoading)
            #expect(controller.workspace.loadGeneration == generation, "no reload")
            #expect(controller.workspace.tabs[0].mode == mode)
            let after = mode == .edit ? controller.editorScroll.y : controller.rootView.codeView.scrollOffset.y
            #expect(after == before)
            #expect(before > 0)
        }

        @Test func commandEOnAFileThatCannotBeEditedChangesNothing() async {
            let repo = editRepo()
            let controller = editController(repo.path)
            for file in ["bin.dat", "gone.txt", "latin1.txt"] {
                controller.openForEdit(file, mode: .diff)
                await waitIdle(controller.workspace)
                press(controller, .edit)
                #expect(controller.workspace.tabs.last?.mode == .diff, "\(file)")
                #expect(controller.workspace.buffers.isEmpty)
                #expect(controller.editor == nil)
            }
        }

        @Test func theViewMenuHasADiffReadAndEditItemAndRefreshOnShiftCommandR() throws {
            _ = NSApplication.shared
            let delegate = AppDelegate(options: LaunchOptions(arguments: ["MicroDiff"]), prescan: nil, windows: WindowManager(showsWindows: false))
            let view = try #require(delegate.makeMenu().items.first { $0.title == "View" }?.submenu)
            let items = view.items.filter { ["Diff", "Read", "Edit", "Refresh"].contains($0.title) }
            #expect(items.map(\.title) == ["Diff", "Read", "Edit", "Refresh"])
            #expect(items.map(\.keyEquivalent) == ["d", "r", "e", "r"])
            #expect(items.map(\.keyEquivalentModifierMask) == [[.command], [.command], [.command], [.command, .shift]])
        }

        /// What the menu item of a mode does.
        private func press(_ controller: MainWindowController, _ mode: ViewMode) {
            switch mode {
            case .diff: controller.showDiff(nil)
            case .read: controller.showRead(nil)
            case .edit: controller.showEdit(nil)
            }
        }

        // MARK: Files that open in edit mode from the files tab

        private func textFilesRepo() -> TestRepo {
            let repo = TestRepo()
            repo.write(".env", "KEY=1\n")
            repo.write("notes.txt", "my notes\n")
            repo.write("other.txt", "other\n")
            repo.write("CMakeLists.txt", "project(x)\n")
            repo.write("readme.md", "# hi\n")
            repo.write("latin1.txt", Data([0x63, 0x61, 0x66, 0xE9, 0x0A]))
            repo.commitAll("first")
            repo.write("notes.txt", "my notes\nmore\n")
            return repo
        }

        /// A mouse click on a file's row in the sidebar.
        private func click(_ controller: MainWindowController, _ name: String, count: Int = 1) {
            let tree = controller.rootView.tree
            guard let index = tree.rows.firstIndex(where: { $0.name == name }) else {
                Issue.record("no row \(name)")
                return
            }
            // The root row is a 28 pt band, every other row 24 pt, below 8 pt of padding.
            let y = 8 + 28 + CGFloat(index - 1) * 24 + 12
            tree.mouse(.down, at: CGPoint(x: 60, y: y), event: makeMouseDown(clickCount: count))
        }

        @Test(arguments: [".env", "notes.txt"])
        func aSingleClickInTheFilesTabOpensAPreviewInEditMode(name: String) {
            let repo = textFilesRepo()
            let controller = editController(repo.path)
            controller.showFiles(nil)
            click(controller, name)
            #expect(controller.workspace.tabs.count == 1)
            #expect(controller.workspace.tabs[0].isPreview)
            #expect(controller.workspace.tabs[0].mode == .edit)
            #expect(controller.editorText == (name == ".env" ? "KEY=1\n" : "my notes\nmore\n"))
        }

        @Test func aDoubleClickKeepsTheTabAndIsInEditMode() {
            let repo = textFilesRepo()
            let controller = editController(repo.path)
            controller.showFiles(nil)
            click(controller, "notes.txt")
            click(controller, "notes.txt", count: 2)
            #expect(controller.workspace.tabs.count == 1)
            #expect(!controller.workspace.tabs[0].isPreview)
            #expect(controller.workspace.tabs[0].mode == .edit)
        }

        @Test func theSameFileFromTheChangesTabOpensInTheDiff() {
            let repo = textFilesRepo()
            let controller = editController(repo.path)
            click(controller, "notes.txt")
            #expect(controller.workspace.tabs[0].mode == .diff)
            #expect(controller.editor == nil)
        }

        @Test func otherFilesAndCMakeListsOpenInRead() {
            let repo = textFilesRepo()
            let controller = editController(repo.path)
            controller.showFiles(nil)
            for name in ["readme.md", "CMakeLists.txt"] {
                click(controller, name)
                #expect(controller.workspace.tabs.last?.mode == .read, "\(name)")
            }
        }

        @Test func aTextFileThatIsNotUTF8OpensInReadWithEditDimmed() {
            let repo = textFilesRepo()
            let controller = editController(repo.path)
            controller.showFiles(nil)
            click(controller, "latin1.txt")
            #expect(controller.workspace.tabs[0].mode == .read)
            #expect(!controller.workspace.canEditActiveTab)
            #expect(!controller.rootView.tabBar.canEdit)
            #expect(controller.workspace.buffers.isEmpty)
        }

        @Test func clickingTheRowOfATabAlreadyOpenInReadLeavesItInRead() {
            let repo = textFilesRepo()
            let controller = editController(repo.path)
            controller.openForEdit("notes.txt", mode: .read)
            controller.showFiles(nil)
            click(controller, "notes.txt")
            #expect(controller.workspace.tabs.count == 1)
            #expect(controller.workspace.tabs[0].mode == .read)
            #expect(controller.workspace.buffers.isEmpty)
        }

        @Test func anotherSingleClickReplacesTheUntouchedPreviewAndItsBufferGoes() {
            let repo = textFilesRepo()
            let controller = editController(repo.path)
            controller.showFiles(nil)
            click(controller, "notes.txt")
            #expect(controller.workspace.buffers.count == 1)
            click(controller, "other.txt")
            #expect(controller.workspace.tabs.count == 1)
            #expect(controller.workspace.tabs[0].path == repo.path + "/other.txt")
            #expect(controller.workspace.buffers.keys.map { $0 } == [repo.path + "/other.txt"])
        }

        @Test func withNoTabCommandEAndCommandSDoNothing() {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.showEdit(nil)
            controller.saveDocument(nil)
            #expect(controller.workspace.tabs.isEmpty)
            #expect(controller.editor == nil)
        }

        @Test func editModeShowsAPlainBufferAndLoadsNoDocument() {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.openForEdit("a.txt", mode: .read)
            controller.showEdit(nil)
            #expect(controller.workspace.content == nil)
            #expect(!controller.workspace.isLoading)
            #expect(controller.rootView.message == nil)
        }

        // MARK: Leaving edit mode without a blank frame

        @Test func leavingEditModeKeepsTheTextOnScreenUntilTheDocumentArrives() async {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.openForEdit("b.txt", mode: .diff)
            controller.showEdit(nil)
            controller.showDiff(nil)
            #expect(controller.workspace.isLoading, "the diff loads in the background")
            #expect(controller.rootView.showsEditor)
            #expect(controller.textView?.isEditable == false)
            #expect(!controller.isEditorFirstResponder)
            #expect(controller.inkInMainArea() > 500, "text, not an empty view")
            controller.type("z")
            #expect(controller.workspace.buffers.isEmpty, "a keystroke meanwhile reaches no buffer")
            #expect(controller.editorText == "one\ntwo\nthree\n")

            await waitIdle(controller.workspace)
            #expect(controller.editorIsIdle)
            #expect(!controller.rootView.codeView.isHidden)
            #expect(controller.inkInMainArea() > 500, "the diff")
        }

        @Test func reenteringBeforeTheDocumentArrivesMakesTheEditorEditableAgain() async {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.openForEdit("a.txt")
            controller.showEdit(nil)
            controller.type("kept ")
            controller.showRead(nil)
            #expect(controller.textView?.isEditable == false)
            controller.showEdit(nil)
            #expect(controller.textView?.isEditable == true)
            #expect(controller.isEditorFirstResponder)
            controller.type("more ")
            #expect(controller.editorText == "kept more alpha\nbeta\ngamma\n")
            await waitIdle(controller.workspace)
            #expect(controller.rootView.showsEditor, "the load that was started is dropped")

            // A clean buffer is dropped on leaving: coming back makes a new one, editable too.
            controller.saveDocument(nil)
            controller.showRead(nil)
            controller.showEdit(nil)
            #expect(controller.textView?.isEditable == true)
            #expect(controller.isEditorFirstResponder)
        }

        @Test func closingOrSwitchingTheTabWhileLeavingSwapsAtOnce() async {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.openForEdit("a.txt")
            controller.showEdit(nil)
            controller.showRead(nil)
            controller.closeTab(nil)
            #expect(controller.editorIsIdle)
            #expect(controller.rootView.message == "no file open")

            controller.openForEdit("a.txt")
            controller.openForEdit("c.txt", mode: .diff)
            controller.workspace.selectTab(0)
            controller.showEdit(nil)
            controller.showDiff(nil)
            controller.workspace.selectTab(1)
            #expect(controller.rootView.showsEditor, "until c.txt has loaded")
            await waitIdle(controller.workspace)
            #expect(controller.editorIsIdle)
            #expect(controller.workspace.content?.document?.firstLine == "first")
        }

        // MARK: Text, caret, scroll and undo survive switches

        @Test func textCaretAndUndoSurviveSwitchingTabsAndBack() async {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.openForEdit("a.txt")
            controller.showEdit(nil)
            controller.setCaret(5)
            controller.type("!")
            await turnRunLoop()
            controller.openForEdit("c.txt")
            #expect(controller.workspace.activeTab == 1)
            #expect(!controller.rootView.showsEditor)

            controller.workspace.selectTab(0)
            #expect(controller.rootView.showsEditor)
            #expect(controller.editorText == "alpha!\nbeta\ngamma\n")
            #expect(controller.caret == range(6, 0))
            #expect(controller.canUndo)
            controller.undo()
            #expect(controller.editorText == "alpha\nbeta\ngamma\n")
            #expect(!controller.workspace.isUnsaved(path(repo, "a.txt")))
        }

        @Test func textCaretAndUndoSurviveSwitchingToDiffAndReadAndBack() async {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.openForEdit("b.txt", mode: .diff)
            controller.showEdit(nil)
            controller.setCaret(3)
            controller.type("X")
            await turnRunLoop()

            controller.showDiff(nil)
            #expect(controller.workspace.tabs[0].mode == .diff)
            await waitIdle(controller.workspace)
            // The diff shows what is on disk; the tab keeps its edits.
            #expect(controller.workspace.content?.document?.newText.line(0) == "one")
            #expect(controller.workspace.isUnsaved(path(repo, "b.txt")))
            // Only tab, no longer in edit mode: the editor is idle, the buffer stays.
            #expect(controller.editorIsIdle)
            #expect(controller.workspace.buffers.count == 1)

            controller.showRead(nil)
            controller.showEdit(nil)
            #expect(controller.editorText == "oneX\ntwo\nthree\n")
            #expect(controller.caret == range(4, 0))
            controller.undo()
            #expect(controller.editorText == "one\ntwo\nthree\n")
        }

        @Test func scrollPositionSurvivesSwitchingTabs() {
            let repo = TestRepo()
            repo.write("long.txt", numberedText(400))
            repo.write("short.txt", "x\n")
            repo.commitAll("first")
            let controller = editController(repo.path)
            controller.openForEdit("long.txt")
            controller.showEdit(nil)
            controller.scrollEditor(toLine: 100)
            #expect(controller.editorSpot == ScrollSpot(line: 100))
            controller.openForEdit("short.txt")
            controller.showEdit(nil)
            #expect(controller.editorScroll.y == 0)
            controller.workspace.selectTab(0)
            #expect(controller.editorSpot == ScrollSpot(line: 100))
            #expect(controller.editor?.visibleLineNumbers().first.map { [$0.line, Int($0.y)] } == [100, 0])
        }

        @Test func goingBetweenReadAndEditKeepsTheScrollPosition() async throws {
            let repo = TestRepo()
            repo.write("long.txt", numberedText(400))
            repo.commitAll("first")
            let controller = editController(repo.path)
            controller.openForEdit("long.txt", mode: .read)
            controller.rootView.codeView.scroll(to: CGPoint(x: 0, y: 1100))
            controller.showEdit(nil)
            // Line 49 starts at 8 + 49 * 22 = 1086: 14 points of it are above the edge, in both views.
            #expect(controller.editorSpot == ScrollSpot(line: 49, offset: 14))
            #expect(controller.editor?.visibleLineNumbers().first.map { [$0.line, Int($0.y)] } == [49, -14])
            controller.scrollEditor(toLine: 30)
            controller.showRead(nil)
            #expect(controller.workspace.tabs[0].mode == .read)
            await waitIdle(controller.workspace)
            #expect(controller.rootView.codeView.scrollOffset.y == 668)
        }

        @Test func undoStaysWithItsOwnFile() async {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.openForEdit("a.txt")
            controller.showEdit(nil)
            controller.setCaret(0)
            controller.type("A")
            await turnRunLoop()
            controller.openForEdit("c.txt")
            controller.showEdit(nil)
            #expect(!controller.canUndo)
            controller.setCaret(0)
            controller.type("C")
            await turnRunLoop()

            controller.undo()
            controller.undo()
            #expect(controller.editorText == "first\nsecond\n")
            controller.workspace.selectTab(0)
            #expect(controller.editorText == "Aalpha\nbeta\ngamma\n")
            controller.undo()
            #expect(controller.editorText == "alpha\nbeta\ngamma\n")
            controller.redo()
            #expect(controller.editorText == "Aalpha\nbeta\ngamma\n")
        }

        @Test func eachEditedTabHasItsOwnStorageAndUndoManager() {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.openForEdit("a.txt")
            controller.showEdit(nil)
            controller.openForEdit("c.txt")
            controller.showEdit(nil)
            let buffers = controller.workspace.buffers
            let a = buffers[path(repo, "a.txt")], c = buffers[path(repo, "c.txt")]
            #expect(a != nil && c != nil)
            #expect(a?.storage !== c?.storage)
            #expect(a?.undoManager !== c?.undoManager)
            #expect(controller.textView?.textStorage === c?.storage)
            #expect(controller.textView?.undoManager === c?.undoManager)
            // One editor per window.
            #expect(controller.rootView.subviews.filter { $0 is EditorView }.count == 1)
        }

        // MARK: Unsaved state

        @Test func typingMarksTheTabUnsavedAndTheWindowEdited() {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.openForEdit("a.txt")
            controller.showEdit(nil)
            #expect(controller.rootView.tabBar.tabs[0].isUnsaved == false)
            controller.type("x")
            #expect(controller.rootView.tabBar.tabs[0].isUnsaved)
            #expect(controller.window.isDocumentEdited)
            controller.deleteBackward()
            #expect(controller.rootView.tabBar.tabs[0].isUnsaved == false, "back to the saved text")
            #expect(!controller.window.isDocumentEdited)
        }

        @Test func typingInAPreviewTabKeepsTheTab() {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.openForEdit("a.txt", pin: false)
            #expect(controller.workspace.tabs[0].isPreview)
            controller.showEdit(nil)
            #expect(controller.workspace.tabs[0].isPreview, "entering edit mode alone does not keep it")
            controller.type("x")
            #expect(!controller.workspace.tabs[0].isPreview)
            #expect(controller.rootView.tabBar.tabs[0].isPreview == false)
            controller.openForEdit("c.txt", pin: false)
            #expect(controller.workspace.tabs.count == 2)
        }

        @Test func aPreviewTabInEditModeIsReplacedLikeAnyPreviewAndItsBufferGoes() {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.openForEdit("a.txt", pin: false)
            controller.showEdit(nil)
            controller.openForEdit("c.txt", pin: false)
            #expect(controller.workspace.tabs.count == 1)
            #expect(controller.workspace.buffers.isEmpty)
            #expect(controller.editorIsIdle)
        }

        // MARK: Saving

        @Test func saveWritesTheFileClearsTheDotAndRefreshesTheStatus() async {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.openForEdit("a.txt")
            #expect(controller.workspace.tabs[0].change == nil)
            controller.showEdit(nil)
            controller.setCaret(0)
            controller.type("new ")
            controller.saveDocument(nil)
            #expect(fileText(path(repo, "a.txt")) == "new alpha\nbeta\ngamma\n")
            #expect(!controller.workspace.isUnsaved(path(repo, "a.txt")))
            #expect(controller.rootView.tabBar.tabs[0].isUnsaved == false)
            #expect(!controller.window.isDocumentEdited)
            // The workspace scans again: the file is now modified in the sidebar and the tab's letter.
            #expect(await waitUntil { controller.workspace.tabs[0].change?.kind == .modified })
            #expect(controller.rootView.tabBar.tabs[0].kind == .modified)
            #expect(controller.workspace.tabs[0].mode == .edit)
        }

        @Test func saveFromTheDiffViewSavesAndKeepsTheUndoHistory() {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.openForEdit("a.txt")
            controller.showEdit(nil)
            controller.type("z")
            controller.showRead(nil)
            #expect(controller.workspace.buffers.count == 1)
            controller.saveDocument(nil)
            #expect(fileText(path(repo, "a.txt")) == "zalpha\nbeta\ngamma\n")
            #expect(controller.workspace.buffers.count == 1, "the undo history stays while the tab is open")
            #expect(!controller.workspace.isUnsaved(path(repo, "a.txt")))
        }

        // MARK: Undo across saves and modes

        @Test(arguments: [ViewMode.read, .diff])
        func undoSurvivesSavingAndLeavingEditMode(through mode: ViewMode) async {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.openForEdit("a.txt")
            controller.showEdit(nil)
            controller.setCaret(0)
            controller.type("typed ")
            await turnRunLoop()
            controller.saveDocument(nil)
            controller.workspace.setMode(mode)
            await waitIdle(controller.workspace)
            #expect(controller.workspace.buffers.count == 1)
            controller.showEdit(nil)
            #expect(controller.workspace.tabs[0].mode == .edit)
            #expect(controller.canUndo)

            controller.undo()
            #expect(controller.editorText == "alpha\nbeta\ngamma\n", "the text from before the typing")
            #expect(controller.workspace.isUnsaved(path(repo, "a.txt")), "past the save point: unsaved again")
            #expect(controller.rootView.tabBar.tabs[0].isUnsaved)
            #expect(controller.window.isDocumentEdited)

            controller.redo()
            #expect(controller.editorText == "typed alpha\nbeta\ngamma\n")
            #expect(!controller.workspace.isUnsaved(path(repo, "a.txt")), "back at the saved text: clean")
            #expect(!controller.window.isDocumentEdited)
        }

        @Test func undoHistoriesOfSavedFilesStaySeparate() async {
            let repo = editRepo()
            let controller = editController(repo.path)
            for (file, word) in [("a.txt", "A"), ("c.txt", "C")] {
                controller.openForEdit(file)
                controller.showEdit(nil)
                controller.setCaret(0)
                controller.type(word)
                await turnRunLoop()
                controller.saveDocument(nil)
                controller.showRead(nil)
            }
            await waitIdle(controller.workspace)
            controller.showEdit(nil)
            controller.undo()
            #expect(controller.editorText == "first\nsecond\n")
            #expect(!controller.canUndo)
            controller.workspace.selectTab(0)
            controller.showEdit(nil)
            #expect(controller.editorText == "Aalpha\nbeta\ngamma\n", "untouched by the other file's undo")
            controller.undo()
            #expect(controller.editorText == "alpha\nbeta\ngamma\n")
        }

        @Test func aKeptBufferThatIsNotOnScreenHoldsNoLayout() async throws {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.openForEdit("a.txt")
            controller.showEdit(nil)
            controller.setCaret(0)
            controller.type("typed ")
            await turnRunLoop()
            controller.saveDocument(nil)
            let buffer = try #require(controller.workspace.buffers.values.first)
            buffer.layoutManager.ensureLayout(for: buffer.container)
            #expect(buffer.layoutManager.firstUnlaidCharacterIndex() == buffer.storage.length)

            controller.showRead(nil)
            await waitIdle(controller.workspace)
            await turnRunLoop()
            #expect(controller.workspace.buffers.count == 1, "kept for its undo history")
            #expect(buffer.layoutManager.firstUnlaidCharacterIndex() == 0, "glyphs and line layout are given back")
            #expect(!buffer.layoutManager.backgroundLayoutEnabled)

            controller.showEdit(nil)
            #expect(buffer.layoutManager.backgroundLayoutEnabled)
            #expect(controller.editorText == "typed alpha\nbeta\ngamma\n")
            #expect(controller.editor?.visibleLineNumbers().map(\.line) == [0, 1, 2, 3])
            #expect(controller.canUndo)
        }

        @Test func saveWithoutChangesDoesNothing() {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.openForEdit("a.txt")
            controller.showEdit(nil)
            let before = fileBytes(path(repo, "a.txt"))
            controller.saveDocument(nil)
            #expect(fileBytes(path(repo, "a.txt")) == before)
        }

        @Test func aFailedSaveShowsTheReasonAndKeepsTheText() {
            let repo = editRepo()
            let prompts = FakePrompts()
            let controller = editController(repo.path, prompts: prompts)
            controller.openForEdit("a.txt")
            controller.showEdit(nil)
            controller.type("keep me ")
            setWritable(path(repo, "a.txt"), false)
            defer { setWritable(path(repo, "a.txt"), true) }
            controller.saveDocument(nil)
            #expect(prompts.messages == [EditError.permissionDenied.message])
            #expect(controller.editorText == "keep me alpha\nbeta\ngamma\n")
            #expect(controller.workspace.isUnsaved(path(repo, "a.txt")))
            #expect(fileText(path(repo, "a.txt")) == "alpha\nbeta\ngamma\n")
        }

        // MARK: Files that cannot be edited

        @Test(arguments: ["bin.dat", "gone.txt", "latin1.txt"])
        func editIsRefusedAndDimmedForFilesThatCannotBeEdited(file: String) {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.openForEdit(file, mode: .read)
            let mode = controller.workspace.tabs[0].mode
            controller.showEdit(nil)
            #expect(controller.workspace.tabs[0].mode == mode)
            #expect(!controller.rootView.tabBar.canEdit)
            #expect(!controller.workspace.canEditActiveTab)
            #expect(controller.editor == nil)
            #expect(controller.workspace.buffers.isEmpty)
        }

        @Test func binaryDeletedAndMissingFilesAreDimmedWithoutTryingFirst() {
            let repo = editRepo()
            let controller = editController(repo.path)
            for file in ["bin.dat", "gone.txt", "nowhere.txt"] {
                controller.openForEdit(file, mode: .diff)
                #expect(!controller.workspace.canEditActiveTab, "\(file)")
                #expect(!controller.rootView.tabBar.canEdit, "\(file): dimmed as soon as its content is there")
            }
            controller.openForEdit("a.txt", mode: .diff)
            #expect(controller.workspace.canEditActiveTab)
            #expect(controller.rootView.tabBar.canEdit)
        }

        @Test func aFileOverFourMegabytesCannotBeEdited() {
            let repo = TestRepo()
            writeBigFile(repo, "big.txt", megabytes: 5)
            repo.commitAll("first")
            let controller = editController(repo.path)
            controller.openForEdit("big.txt", mode: .read)
            #expect(controller.workspace.content?.document != nil, "the read view still shows it")
            #expect(!controller.workspace.canEditActiveTab)
        }

        @Test func aFileThatFailedIsTriedAgainOnceItChanged() {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.openForEdit("latin1.txt", mode: .read)
            controller.showEdit(nil)
            #expect(!controller.workspace.canEditActiveTab)
            repo.write("latin1.txt", "café, now in UTF-8\n")
            controller.workspace.scanNow()
            #expect(controller.workspace.canEditActiveTab)
            controller.showEdit(nil)
            #expect(controller.workspace.tabs[0].mode == .edit)
            #expect(controller.editorText == "café, now in UTF-8\n")
        }

        // MARK: Line endings and byte order mark

        @Test func crlfAndBOMSurviveARoundTripThroughTheEditor() {
            let repo = TestRepo()
            repo.write("win.txt", Data([0xEF, 0xBB, 0xBF] + Array("one\r\ntwo\r\n".utf8)))
            repo.commitAll("first")
            let controller = editController(repo.path)
            controller.openForEdit("win.txt")
            controller.showEdit(nil)
            #expect(controller.editorText == "one\ntwo\n")
            controller.setCaret(8)
            controller.type("three\n")
            controller.saveDocument(nil)
            #expect(fileBytes(path(repo, "win.txt")) == [0xEF, 0xBB, 0xBF] + Array("one\r\ntwo\r\nthree\r\n".utf8))
        }

        @Test func pastedTextIsPlain() {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.openForEdit("a.txt")
            controller.showEdit(nil)
            let textView = controller.textView
            #expect(textView?.isRichText == false)
            #expect(textView?.isAutomaticQuoteSubstitutionEnabled == false)
            #expect(textView?.isAutomaticDashSubstitutionEnabled == false)
            #expect(textView?.isAutomaticTextReplacementEnabled == false)
            #expect(textView?.isAutomaticSpellingCorrectionEnabled == false)
            #expect(textView?.isContinuousSpellCheckingEnabled == false)
            #expect(textView?.isAutomaticLinkDetectionEnabled == false)
            #expect(textView?.isAutomaticDataDetectionEnabled == false)
            #expect(textView?.usesFontPanel == false)
            #expect(textView?.usesRuler == false)
            controller.type("\"quotes\" -- and https://example.com")
            #expect(controller.editorText?.hasPrefix("\"quotes\" -- and https://example.com") == true)
        }

        @Test func theTextViewUsesTextKitOneOnTheBuffersOwnStack() {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.openForEdit("a.txt")
            controller.showEdit(nil)
            let buffer = controller.workspace.activeBuffer
            #expect(controller.textView?.layoutManager === buffer?.layoutManager)
            #expect(controller.textView?.textContainer === buffer?.container)
            #expect(buffer?.layoutManager.allowsNonContiguousLayout == true)
        }

        @Test func longLinesScrollSidewaysAndTheGutterStaysPut() throws {
            let repo = TestRepo()
            repo.write("wide.txt", String(repeating: "wide ", count: 200) + "\nshort\n")
            repo.commitAll("first")
            let controller = editController(repo.path)
            controller.openForEdit("wide.txt")
            controller.showEdit(nil)
            let editor = try #require(controller.editor)
            let clip = editor.scrollView.contentView.bounds
            #expect(controller.textView!.frame.width > clip.width + 500, "no wrapping: the text view is as wide as the longest line")
            #expect(controller.editor?.visibleLineNumbers().count == 3)
            editor.scroll(to: ScrollSpot(line: 0, offset: -8, x: 400))
            #expect(editor.scrollView.contentView.bounds.minX == 400)
            #expect(editor.scrollSpot().x == 400)
            #expect(editor.visibleLineNumbers().map(\.line) == [0, 1, 2], "the numbers do not scroll sideways")
        }

        // MARK: Return and Tab

        /// A controller editing a file with `text` (the repository is returned so it lives as long as the test).
        private func editing(_ text: String, file: String = "f.txt") -> (MainWindowController, TestRepo) {
            let repo = TestRepo()
            repo.write(file, text)
            repo.commitAll("first")
            let controller = editController(repo.path)
            controller.openForEdit(file)
            controller.showEdit(nil)
            return (controller, repo)
        }

        @Test func returnKeepsTheIndentationBeforeTheCaret() async {
            let (controller, repo) = editing("def a():\n    if b:\n\t\tc()\n")
            defer { withExtendedLifetime(repo) {} }
            controller.setCaret(18) // end of "    if b:"
            controller.pressReturn()
            #expect(controller.editorText == "def a():\n    if b:\n    \n\t\tc()\n")
            #expect(controller.caret == range(23, 0))
            await turnRunLoop()
            controller.undo()
            #expect(controller.editorText == "def a():\n    if b:\n\t\tc()\n", "one undo step")

            controller.setCaret(20) // inside "\t\tc()", after the first tab
            controller.pressReturn()
            #expect(controller.editorText == "def a():\n    if b:\n\t\n\t\tc()\n", "only the blanks before the caret")
            #expect(controller.workspace.isUnsaved(controller.workspace.activePath!), "through the normal path: the delegate saw it")

            controller.setCaret(0)
            controller.pressReturn()
            #expect(controller.editorText?.hasPrefix("\ndef a()") == true, "no indentation, a plain line break")
        }

        @Test func tabInsertsSpacesToTheNextLevelInASpaceIndentedFile() {
            let (controller, repo) = editing("a:\n  b: 1\n", file: "c.yaml")
            defer { withExtendedLifetime(repo) {} }
            #expect(controller.workspace.activeBuffer?.indentation == .spaces(2))
            controller.setCaret(3)
            controller.pressTab()
            #expect(controller.editorText == "a:\n    b: 1\n")
            controller.setCaret(8) // "    b" + one column: column 5
            controller.pressTab()
            #expect(controller.editorText == "a:\n    b : 1\n")
        }

        @Test func tabCountsColumnsOfTabsAlreadyInTheLine() {
            let (controller, repo) = editing("x\n    y\n")
            defer { withExtendedLifetime(repo) {} }
            #expect(controller.workspace.activeBuffer?.indentation == .spaces(4))
            controller.setCaret(2)
            controller.type("\tab")
            controller.pressTab()
            // A tab stops at column 4, "ab" makes 6: two spaces reach 8.
            #expect(controller.editorText == "x\n\tab      y\n")
        }

        @Test func tabInsertsATabInATabIndentedFileAndReplacesASelection() {
            let (controller, repo) = editing("func a() {\n\treturn 1\n}\n")
            defer { withExtendedLifetime(repo) {} }
            #expect(controller.workspace.activeBuffer?.indentation == .tabs)
            controller.setCaret(0, length: 4)
            controller.pressTab()
            #expect(controller.editorText == "\t a() {\n\treturn 1\n}\n")

            let (spaces, other) = editing("x\n  y\n")
            defer { withExtendedLifetime(other) {} }
            spaces.setCaret(0, length: 1)
            spaces.pressTab()
            #expect(spaces.editorText == "  \n  y\n")
        }

        // MARK: Line numbers

        @Test func theGutterNumbersTheVisibleLinesAndLightsTheCaretLine() {
            let repo = TestRepo()
            repo.write("long.txt", numberedText(300))
            repo.commitAll("first")
            let controller = editController(repo.path)
            controller.openForEdit("long.txt")
            controller.showEdit(nil)
            let top = controller.editor?.visibleLineNumbers() ?? []
            #expect(top.first?.line == 0)
            #expect(top.first?.y == 8)
            let height = controller.editor?.scrollView.contentView.bounds.height ?? 0
            #expect(top.count == Int(((height - 8) / 22).rounded(.up)))
            #expect(top.filter(\.isCaretLine).map(\.line) == [0])

            controller.scrollEditor(toLine: 200, offset: 5)
            let lines = controller.editor?.visibleLineNumbers() ?? []
            #expect(lines.first?.line == 200)
            #expect(lines.first?.y == -5)
            #expect(lines.map(\.line) == Array(200..<(200 + lines.count)))
            #expect(lines.filter(\.isCaretLine).isEmpty)

            controller.setCaret(controller.textView!.string.utf16.count)
            controller.scrollEditor(toLine: 290)
            let bottom = controller.editor?.visibleLineNumbers() ?? []
            // The empty line after the final line break gets a number too, and holds the caret.
            #expect(bottom.last?.line == 300)
            #expect(bottom.last?.isCaretLine == true)
        }

        @Test func theGutterRedrawsWhenTheTextChangesWithoutTyping() throws {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.openForEdit("a.txt")
            controller.showEdit(nil)
            let editor = try #require(controller.editor)
            let storage = try #require(controller.workspace.activeBuffer?.storage)
            var before = editor.gutter.invalidations
            storage.replaceCharacters(in: range(storage.length, 0), with: "delta\nepsilon\n")
            #expect(editor.gutter.invalidations > before)
            #expect(editor.visibleLineNumbers().map(\.line) == Array(0...5))

            // Another buffer's storage changing does not concern this gutter.
            let other = NSTextStorage(string: "x")
            before = editor.gutter.invalidations
            other.replaceCharacters(in: range(0, 0), with: "y")
            #expect(editor.gutter.invalidations == before)
        }

        @Test func lineNumbersFollowEditsAboveTheVisibleLines() {
            let repo = TestRepo()
            repo.write("long.txt", numberedText(300))
            repo.commitAll("first")
            let controller = editController(repo.path)
            controller.openForEdit("long.txt")
            controller.showEdit(nil)
            controller.scrollEditor(toLine: 100)
            #expect(controller.editor?.visibleLineNumbers().first?.line == 100)
            let buffer = controller.workspace.activeBuffer!
            #expect(buffer.line(at: buffer.storage.length) == 300)
            controller.setCaret(0)
            controller.type("new\nlines\n")
            #expect(buffer.line(at: buffer.storage.length) == 302)
            #expect(buffer.line(at: 4) == 1)
        }
    }
}
