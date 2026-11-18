import AppKit
import MicroDiffCore
import MicroDiffTestSupport
import Testing
@testable import MicroDiffUI

extension UITests {
    /// Unsaved edits are never lost without asking: closing a tab, closing the window, quitting, opening another folder.
    /// The questions go through the `Prompts` seam; no dialog is ever shown.
    @MainActor
    @Suite
    struct EditPromptTests {
        private func path(_ repo: TestRepo, _ relative: String) -> String { repo.path + "/" + relative }

        /// A controller with `a.txt` typed into ("x" at the start) and `c.txt` open and clean.
        private func edited(_ repo: TestRepo, _ prompts: FakePrompts) -> MainWindowController {
            let controller = editController(repo.path, prompts: prompts)
            controller.openForEdit("a.txt")
            controller.showEdit(nil)
            controller.setCaret(0)
            controller.type("x")
            controller.openForEdit("c.txt")
            controller.workspace.selectTab(0)
            return controller
        }

        // MARK: Closing a tab

        @Test func closingACleanTabAsksNothing() {
            let repo = editRepo()
            let prompts = FakePrompts()
            let controller = edited(repo, prompts)
            controller.requestCloseTab(1)
            #expect(prompts.questions.isEmpty)
            #expect(controller.workspace.tabs.count == 1)
        }

        @Test func closingAnUnsavedTabAndSaving() {
            let repo = editRepo()
            let prompts = FakePrompts([.save])
            let controller = edited(repo, prompts)
            controller.closeTab(nil)
            #expect(prompts.questions == [.closeTab(name: "a.txt")])
            #expect(fileText(path(repo, "a.txt")) == "xalpha\nbeta\ngamma\n")
            #expect(controller.workspace.tabNames == ["c.txt"])
            #expect(controller.workspace.buffers.isEmpty)
        }

        @Test func closingAnUnsavedTabWithoutSaving() async {
            let repo = editRepo()
            let prompts = FakePrompts([.dontSave])
            let controller = edited(repo, prompts)
            controller.rootView.tabBar.onClose?(0)
            #expect(prompts.questions == [.closeTab(name: "a.txt")])
            #expect(fileText(path(repo, "a.txt")) == "alpha\nbeta\ngamma\n")
            #expect(controller.workspace.tabNames == ["c.txt"])
            #expect(controller.workspace.buffers.isEmpty)
            await waitIdle(controller.workspace)
            #expect(controller.editorIsIdle, "no tab is in edit mode any more")
        }

        @Test func cancellingTheCloseKeepsTheTabAndItsText() {
            let repo = editRepo()
            let prompts = FakePrompts([.cancel])
            let controller = edited(repo, prompts)
            controller.closeTab(nil)
            #expect(controller.workspace.tabNames == ["a.txt", "c.txt"])
            #expect(controller.editorText == "xalpha\nbeta\ngamma\n")
            #expect(controller.workspace.isUnsaved(path(repo, "a.txt")))
        }

        @Test func aFailedSaveWhileClosingKeepsTheTab() {
            let repo = editRepo()
            let prompts = FakePrompts([.save])
            let controller = edited(repo, prompts)
            setWritable(path(repo, "a.txt"), false)
            defer { setWritable(path(repo, "a.txt"), true) }
            controller.closeTab(nil)
            #expect(prompts.messages == [EditError.permissionDenied.message])
            #expect(controller.workspace.tabNames == ["a.txt", "c.txt"])
            #expect(controller.workspace.isUnsaved(path(repo, "a.txt")))
        }

        @Test func aMiddleClickOnAnUnsavedBackgroundTabAsksToo() {
            let repo = editRepo()
            let prompts = FakePrompts([.dontSave])
            let controller = edited(repo, prompts)
            controller.workspace.selectTab(1)
            controller.rootView.tabBar.onClose?(0)
            #expect(prompts.questions == [.closeTab(name: "a.txt")])
            #expect(controller.workspace.tabNames == ["c.txt"])
        }

        // MARK: Closing the window

        @Test func closingAWindowWithoutUnsavedTabsAsksNothing() {
            let repo = editRepo()
            let prompts = FakePrompts()
            let controller = editController(repo.path, prompts: prompts)
            controller.openForEdit("a.txt")
            controller.showEdit(nil)
            #expect(controller.windowShouldClose(controller.window))
            #expect(prompts.questions.isEmpty)
        }

        @Test func closingTheWindowAsksOnceForAllUnsavedTabs() {
            let repo = editRepo()
            let prompts = FakePrompts([.cancel])
            let controller = edited(repo, prompts)
            controller.workspace.selectTab(1)
            controller.showEdit(nil)
            controller.type("y")
            #expect(!controller.windowShouldClose(controller.window))
            #expect(prompts.questions == [.closeWindow(fileCount: 2)])
            #expect(controller.workspace.tabs.count == 2)
        }

        @Test(arguments: [SaveAnswer.save, .dontSave, .cancel])
        func theWindowCloseAnswers(answer: SaveAnswer) {
            let repo = editRepo()
            let prompts = FakePrompts([answer])
            let controller = edited(repo, prompts)
            var closed = 0
            controller.onClose = { _ in closed += 1 }
            #expect(!controller.windowShouldClose(controller.window), "the answer comes later; the window closes itself then")
            switch answer {
            case .save:
                #expect(fileText(path(repo, "a.txt")) == "xalpha\nbeta\ngamma\n")
                #expect(closed == 1)
            case .dontSave:
                #expect(fileText(path(repo, "a.txt")) == "alpha\nbeta\ngamma\n")
                #expect(closed == 1)
            case .cancel:
                #expect(closed == 0)
                #expect(controller.workspace.isUnsaved(path(repo, "a.txt")))
            }
        }

        @Test func saveAllThatFailsKeepsTheWindowOpen() {
            let repo = editRepo()
            let prompts = FakePrompts([.save])
            let controller = edited(repo, prompts)
            var closed = 0
            controller.onClose = { _ in closed += 1 }
            setWritable(path(repo, "a.txt"), false)
            defer { setWritable(path(repo, "a.txt"), true) }
            _ = controller.windowShouldClose(controller.window)
            #expect(closed == 0)
            #expect(prompts.messages.count == 1)
        }

        // MARK: Opening another folder

        @Test(arguments: [SaveAnswer.save, .dontSave, .cancel])
        func openingAnotherFolderAsksFirst(answer: SaveAnswer) {
            let repo = editRepo()
            let other = Fixture.cleanRepo()
            let prompts = FakePrompts([answer])
            let controller = edited(repo, prompts)
            controller.open(path: other.path)
            #expect(prompts.questions == [.closeWindow(fileCount: 1)])
            #expect(controller.workspace.rootPath == (answer == .cancel ? repo.path : other.path))
            #expect(fileText(path(repo, "a.txt")) == (answer == .save ? "xalpha\nbeta\ngamma\n" : "alpha\nbeta\ngamma\n"))
            if answer != .cancel { #expect(controller.editorIsIdle) }
        }

        // MARK: Quitting

        @Test func quittingAsksEveryWindowWithUnsavedTabsInTurn() {
            let manager = WindowManager(showsWindows: false)
            let first = editRepo(), second = editRepo(), clean = editRepo()
            let prompts = FakePrompts([.save, .dontSave])
            for repo in [first, clean, second] {
                let controller = manager.makeWindow(path: repo.path)
                controller.prompts = prompts.prompts
                controller.workspace.scanNow()
                controller.openForEdit("a.txt")
                controller.showEdit(nil)
                if repo !== clean { controller.type("q") }
            }
            #expect(manager.hasUnsavedEdits)
            var result: Bool?
            manager.confirmQuit { result = $0 }
            #expect(result == true)
            #expect(prompts.questions == [.closeWindow(fileCount: 1), .closeWindow(fileCount: 1)])
            #expect(fileText(path(first, "a.txt")) == "qalpha\nbeta\ngamma\n")
            #expect(fileText(path(second, "a.txt")) == "alpha\nbeta\ngamma\n")
        }

        @Test func cancelInAnyWindowStopsTheQuit() {
            let manager = WindowManager(showsWindows: false)
            let first = editRepo(), second = editRepo()
            let prompts = FakePrompts([.cancel])
            for repo in [first, second] {
                let controller = manager.makeWindow(path: repo.path)
                controller.prompts = prompts.prompts
                controller.workspace.scanNow()
                controller.openForEdit("a.txt")
                controller.showEdit(nil)
                controller.type("q")
            }
            var result: Bool?
            manager.confirmQuit { result = $0 }
            #expect(result == false)
            #expect(prompts.questions.count == 1, "the second window is not asked after a Cancel")
        }

        @Test func quittingWithNothingUnsavedAsksNothing() {
            let manager = WindowManager(showsWindows: false)
            let prompts = FakePrompts()
            let controller = manager.makeWindow(path: editRepo().path)
            controller.prompts = prompts.prompts
            #expect(!manager.hasUnsavedEdits)
            var result: Bool?
            manager.confirmQuit { result = $0 }
            #expect(result == true)
            #expect(prompts.questions.isEmpty)
        }

        @Test func theAppAsksBeforeTerminatingOnlyWithUnsavedEdits() {
            let manager = WindowManager(showsWindows: false)
            let delegate = AppDelegate(options: LaunchOptions(arguments: ["MicroDiff"]), prescan: nil, windows: manager)
            let prompts = FakePrompts()
            let controller = manager.makeWindow(path: editRepo().path)
            controller.prompts = prompts.prompts
            controller.workspace.scanNow()
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
            #expect(prompts.questions.isEmpty)
        }
    }
}
