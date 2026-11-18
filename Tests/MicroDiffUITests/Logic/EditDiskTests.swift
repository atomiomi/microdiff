import AppKit
import MicroDiffCore
import MicroDiffTestSupport
import Testing
@testable import MicroDiffUI

extension UITests {
    /// The file changes on disk while a tab is being edited. `scanNow()` stands in for the file watcher's rescan;
    /// the last tests use the real watcher.
    @MainActor
    @Suite
    struct EditDiskTests {
        private func path(_ repo: TestRepo, _ relative: String) -> String { repo.path + "/" + relative }

        private func editing(_ repo: TestRepo, _ file: String = "a.txt", prompts: FakePrompts = FakePrompts()) -> MainWindowController {
            let controller = editController(repo.path, prompts: prompts)
            controller.openForEdit(file)
            controller.showEdit(nil)
            return controller
        }

        // MARK: Not unsaved: follow the disk quietly

        @Test func aCleanEditorReloadsSilentlyAndKeepsTheCaret() {
            let repo = editRepo()
            let controller = editing(repo)
            controller.setCaret(8)
            repo.write("a.txt", "alpha\nBETA\ngamma\ndelta\n")
            controller.workspace.scanNow()
            #expect(controller.editorText == "alpha\nBETA\ngamma\ndelta\n")
            #expect(controller.caret == range(8, 0))
            #expect(!controller.stripShown)
            #expect(!controller.workspace.isUnsaved(path(repo, "a.txt")))
            #expect(!controller.canUndo, "undo steps of the old text are dropped")
        }

        @Test func aReloadThatShortensTheTextClampsTheCaret() {
            let repo = editRepo()
            let controller = editing(repo)
            controller.setCaret(15)
            repo.write("a.txt", "a\n")
            controller.workspace.scanNow()
            #expect(controller.editorText == "a\n")
            #expect(controller.caret == range(2, 0))
        }

        @Test func aCleanEditorWhoseFileIsDeletedLeavesEditMode() async {
            let repo = editRepo()
            let controller = editing(repo, "c.txt")
            repo.remove("c.txt")
            controller.workspace.scanNow()
            #expect(controller.workspace.tabs[0].mode == .diff)
            #expect(controller.workspace.buffers.isEmpty)
            await waitIdle(controller.workspace)
            #expect(controller.editorIsIdle)
            // Shown the way a deleted tracked file is shown today: its old contents.
            #expect(controller.workspace.content?.document?.kind == .deleted)
            #expect(!controller.workspace.canEditActiveTab)
        }

        @Test func anUntrackedCleanFileThatIsDeletedShowsNotFound() async {
            let repo = editRepo()
            repo.write("loose.txt", "loose\n")
            let controller = editController(repo.path)
            controller.openForEdit("loose.txt", mode: .diff)
            controller.showEdit(nil)
            repo.remove("loose.txt")
            controller.workspace.scanNow()
            #expect(controller.workspace.tabs[0].mode == .diff)
            await waitIdle(controller.workspace)
            #expect(controller.workspace.content?.message == DocumentLoader.missingMessage)
        }

        @Test func aBufferKeptForUndoIsDroppedWhenTheFileChangesOnDisk() async {
            let repo = editRepo()
            let controller = editing(repo)
            controller.type("saved ")
            controller.saveDocument(nil)
            controller.showRead(nil)
            await waitIdle(controller.workspace)
            #expect(controller.workspace.buffers.count == 1)
            repo.write("a.txt", "changed elsewhere\n")
            controller.workspace.scanNow()
            #expect(controller.workspace.buffers.isEmpty, "its undo steps no longer fit the file")
            controller.showEdit(nil)
            #expect(controller.editorText == "changed elsewhere\n")
            #expect(!controller.canUndo)
        }

        @Test func inEditModeAChangeOnDiskReloadsAndKeepsTheBuffer() async {
            let repo = editRepo()
            let controller = editing(repo)
            controller.type("saved ")
            await turnRunLoop()
            controller.saveDocument(nil)
            let buffer = controller.workspace.activeBuffer
            repo.write("a.txt", "changed elsewhere\n")
            controller.workspace.scanNow()
            #expect(controller.workspace.activeBuffer === buffer)
            #expect(controller.editorText == "changed elsewhere\n")
            #expect(!controller.canUndo)
        }

        // MARK: Unsaved: the strip

        @Test func aChangeOnDiskUnderUnsavedEditsShowsTheStrip() {
            let repo = editRepo()
            let controller = editing(repo)
            controller.type("mine ")
            repo.write("a.txt", "theirs\n")
            controller.workspace.scanNow()
            #expect(controller.stripShown)
            #expect(controller.editor?.conflict == .changed)
            #expect(controller.editorText == "mine alpha\nbeta\ngamma\n", "nothing is replaced without asking")
            // The text sits below the 28 pt strip.
            controller.rootView.layoutSubtreeIfNeeded()
            #expect(controller.editor?.scrollView.frame.minY == Theme.foldHeight)
        }

        @Test func reloadInTheStripTakesTheDiskText() {
            let repo = editRepo()
            let controller = editing(repo)
            controller.type("mine ")
            repo.write("a.txt", "theirs\n")
            controller.workspace.scanNow()
            controller.editor?.onReload?()
            #expect(controller.editorText == "theirs\n")
            #expect(!controller.stripShown)
            #expect(!controller.workspace.isUnsaved(path(repo, "a.txt")))
            #expect(controller.rootView.tabBar.tabs[0].isUnsaved == false)
            controller.rootView.layoutSubtreeIfNeeded()
            #expect(controller.editor?.scrollView.frame.minY == 0)
        }

        @Test func keepMineInTheStripKeepsTheEditsAndSavingOverwrites() {
            let repo = editRepo()
            let controller = editing(repo)
            controller.type("mine ")
            repo.write("a.txt", "theirs\n")
            controller.workspace.scanNow()
            controller.editor?.onKeepMine?()
            #expect(!controller.stripShown)
            #expect(controller.editorText == "mine alpha\nbeta\ngamma\n")
            #expect(controller.workspace.isUnsaved(path(repo, "a.txt")))
            controller.workspace.scanNow()
            #expect(!controller.stripShown, "the same disk version does not raise it again")
            controller.saveDocument(nil)
            #expect(fileText(path(repo, "a.txt")) == "mine alpha\nbeta\ngamma\n")
        }

        @Test func aDeletedFileUnderUnsavedEditsOffersOnlyKeepMine() throws {
            let repo = editRepo()
            let controller = editing(repo, "c.txt")
            controller.type("mine ")
            repo.remove("c.txt")
            controller.workspace.scanNow()
            #expect(controller.stripShown)
            #expect(controller.editor?.conflict == .deleted)
            #expect(controller.workspace.tabs[0].mode == .edit)
            controller.editor?.onReload?()
            #expect(controller.stripShown, "nothing to reload")
            controller.editor?.onKeepMine?()
            #expect(!controller.stripShown)
            controller.saveDocument(nil)
            #expect(fileText(path(repo, "c.txt")) == "mine first\nsecond\n", "saving brings the file back")
        }

        @Test func theDiskTextEqualToTheEditsMakesTheTabClean() {
            let repo = editRepo()
            let controller = editing(repo)
            controller.setCaret(0)
            controller.type("same ")
            repo.write("a.txt", "same alpha\nbeta\ngamma\n")
            controller.workspace.scanNow()
            #expect(!controller.stripShown)
            #expect(!controller.workspace.isUnsaved(path(repo, "a.txt")))
            #expect(controller.rootView.tabBar.tabs[0].isUnsaved == false)
        }

        @Test func anUnsavedTabOutsideEditModeGetsTheStripWhenItComesBack() async {
            let repo = editRepo()
            let controller = editing(repo)
            controller.type("mine ")
            controller.showRead(nil)
            repo.write("a.txt", "theirs\n")
            controller.workspace.scanNow()
            await waitIdle(controller.workspace)
            #expect(controller.editorIsIdle)
            controller.showEdit(nil)
            #expect(controller.stripShown)
            #expect(controller.editorText == "mine alpha\nbeta\ngamma\n")
        }

        // MARK: Refreshes never lose edits

        @Test func aRefreshKeepsUnsavedTabsAndTheirText() {
            let repo = editRepo()
            let controller = editing(repo)
            controller.type("keep ")
            controller.openForEdit("c.txt")
            for _ in 0..<3 {
                repo.write("b.txt", "churn\n")
                controller.workspace.scanNow()
                repo.git("add", "-A")
                controller.workspace.scanNow()
            }
            #expect(controller.workspace.tabNames == ["a.txt", "c.txt"])
            controller.workspace.selectTab(0)
            #expect(controller.editorText == "keep alpha\nbeta\ngamma\n")
            #expect(controller.workspace.isUnsaved(path(repo, "a.txt")))
        }

        // MARK: With the real file watcher

        @Test func theAppsOwnSaveDoesNotRaiseTheStrip() async {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.workspace.start()
            await waitQuiet(controller.workspace)
            controller.openForEdit("a.txt")
            controller.showEdit(nil)
            for round in 0..<3 {
                controller.type("\(round)")
                controller.saveDocument(nil)
                await waitQuiet(controller.workspace)
                #expect(!controller.stripShown)
                #expect(!controller.workspace.isUnsaved(path(repo, "a.txt")))
            }
            #expect(fileText(path(repo, "a.txt")) == "012alpha\nbeta\ngamma\n")
            #expect(controller.workspace.tabs[0].change?.kind == .modified)
        }

        @Test func anOutsideWriteIsPickedUpByTheWatcher() async {
            let repo = editRepo()
            let controller = editController(repo.path)
            controller.workspace.start()
            await waitQuiet(controller.workspace)
            controller.openForEdit("a.txt")
            controller.showEdit(nil)
            repo.write("a.txt", "from outside\n")
            #expect(await waitUntil { controller.editorText == "from outside\n" })
            controller.type("mine ")
            repo.write("a.txt", "outside again\n")
            #expect(await waitUntil { controller.stripShown })
        }
    }
}
