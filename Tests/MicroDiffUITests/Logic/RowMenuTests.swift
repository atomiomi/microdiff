import AppKit
import MicroDiffCore
import MicroDiffTestSupport
import Testing

@testable import MicroDiffUI

extension UITests {
    /// The context menu of a sidebar row. Finder and the Trash are fakes; the real ones are never called.
    @MainActor
    @Suite
    struct RowMenuTests {
        private func expand(_ controller: MainWindowController, _ paths: String...) {
            for path in paths { controller.workspace.toggle(controller.workspace.row(path: path)!) }
        }

        // MARK: Items

        @Test func aFileRowInTheFilesTabOffersNewFileShowInFinderAndMoveToTrash() {
            let repo = Fixture.changesRepo()
            let controller = menuController(repo.path, tab: .files)
            #expect(summary(controller.rowMenu("README.md")) == ["New File…", "Show in Finder", "-", "Move to Trash"])
            withExtendedLifetime(repo) {}
        }

        @Test func aFolderRowInTheFilesTabOffersTheSameItems() {
            let repo = Fixture.changesRepo()
            let controller = menuController(repo.path, tab: .files)
            #expect(summary(controller.rowMenu("src", kind: .directory)) == ["New File…", "Show in Finder", "-", "Move to Trash"])
            withExtendedLifetime(repo) {}
        }

        @Test func theRootRowInTheFilesTabOffersNoTrash() {
            let repo = Fixture.changesRepo()
            let controller = menuController(repo.path, tab: .files)
            #expect(summary(controller.rowMenu("", kind: .repo)) == ["New File…", "Show in Finder"])
            withExtendedLifetime(repo) {}
        }

        @Test func everyRowInTheChangesTabOffersOnlyShowInFinder() {
            let repo = Fixture.changesRepo()
            let controller = menuController(repo.path, tab: .changes)
            #expect(summary(controller.rowMenu("", kind: .repo)) == ["Show in Finder"])
            #expect(summary(controller.rowMenu("src", kind: .directory)) == ["Show in Finder"])
            #expect(summary(controller.rowMenu("src/app.swift")) == ["Show in Finder"])
            withExtendedLifetime(repo) {}
        }

        @Test func aDeletedFileInTheChangesTabCannotBeShown() {
            let repo = Fixture.changesRepo()
            let controller = menuController(repo.path, tab: .changes)
            #expect(summary(controller.rowMenu("docs/old.txt")) == ["Show in Finder (disabled)"])
            withExtendedLifetime(repo) {}
        }

        @Test func aRowThatIsGoneFromDiskIsDimmedInTheFilesTabToo() {
            let repo = Fixture.changesRepo()
            let controller = menuController(repo.path, tab: .files)
            let row = controller.workspace.row(path: "README.md")!
            repo.remove("README.md")
            #expect(summary(controller.menu(for: row)) == ["New File… (disabled)", "Show in Finder (disabled)", "-", "Move to Trash (disabled)"])
        }

        // MARK: Pointer

        /// The middle of a row of the files tab, in the tree's coordinates (the root row is a band, the rest are rows).
        private func middle(ofRow index: Int) -> CGPoint {
            let top = 8 + (index == 0 ? 0 : Theme.repoBandHeight + CGFloat(index - 1) * Theme.treeRowHeight)
            return point(40, top + Theme.treeRowHeight / 2)
        }

        @Test func aMenuIsForTheRowUnderThePointerAndNothingBelowTheRows() {
            let repo = Fixture.changesRepo()
            let controller = menuController(repo.path, tab: .files)
            let tree = controller.rootView.tree
            let rows = tree.rows
            let folder = rows.firstIndex { $0.path == "src" }!
            #expect(summary(tree.menu(at: middle(ofRow: folder))) == ["New File…", "Show in Finder", "-", "Move to Trash"])
            #expect(summary(tree.menu(at: middle(ofRow: 0))) == ["New File…", "Show in Finder"])
            #expect(tree.menu(at: middle(ofRow: rows.count + 3)) == nil)
            withExtendedLifetime(repo) {}
        }

        @Test func aRightClickDeliversTheRowUnderThePointerThroughTheCanvas() throws {
            let tree = TreeView(frame: .zero)
            tree.style = .files
            let window = hostInWindow(tree, width: 280, height: 300)
            let rows = (0..<5).map { index in
                TreeRow(
                    id: TreeRow.makeID(repoIndex: 0, kind: .file, path: "f\(index)"), kind: .file, depth: 0, name: "f\(index)",
                    path: "f\(index)", repoIndex: -1, change: nil)
            }
            tree.setRows(rows)
            tree.layoutSubtreeIfNeeded()
            var asked: [String] = []
            tree.menuForRow = { row in
                asked.append(row.name)
                return NSMenu()
            }
            // Rows start at 8 and are 24 tall: y 40 is row 1, y 250 is below the five rows.
            let canvas = try #require(window.topmostView(atWindowPoint: tree.convert(point(40, 40), to: nil)))
            #expect(canvas !== tree)
            let event = { (y: Double) in
                NSEvent.mouseEvent(
                    with: .rightMouseDown, location: tree.convert(point(40, y), to: nil), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            #expect(canvas.menu(for: event(40)) != nil)
            #expect(canvas.menu(for: event(250)) == nil)
            #expect(asked == ["f1"])
        }

        @Test func openingTheMenuOfAnotherRowChangesNothing() {
            let repo = Fixture.changesRepo()
            let controller = menuController(repo.path, tab: .files)
            let workspace = controller.workspace
            workspace.open(workspace.row(path: "README.md")!, pin: false)
            let selected = workspace.selectedRowID
            let tree = controller.rootView.tree
            let folder = tree.rows.firstIndex { $0.path == "src" }!
            var opened = 0
            var toggled = 0
            tree.onOpen = { _, _ in opened += 1 }
            tree.onToggle = { _ in toggled += 1 }

            #expect(tree.menu(at: middle(ofRow: folder)) != nil)
            #expect(tree.menu(at: middle(ofRow: tree.rows.firstIndex { $0.path == "docs" }!)) != nil)

            #expect(workspace.selectedRowID == selected)
            #expect(tree.selectedID == selected)
            #expect(workspace.tabNames == ["README.md"])
            #expect(workspace.row(path: "src")?.isExpanded == false)
            #expect(opened == 0 && toggled == 0)
            withExtendedLifetime(repo) {}
        }

        // MARK: Show in Finder

        @Test func showInFinderGivesTheAbsolutePathOfAFileAFolderAndTheRoot() {
            let repo = Fixture.changesRepo()
            let actions = FakeFileActions()
            let controller = menuController(repo.path, tab: .files, actions: actions)
            expand(controller, "src", "src/ui")
            controller.choose("Show in Finder", in: controller.rowMenu("README.md"))
            controller.choose("Show in Finder", in: controller.rowMenu("src/ui/widgets", kind: .directory))
            controller.choose("Show in Finder", in: controller.rowMenu("", kind: .repo))
            #expect(actions.revealed == [repo.path + "/README.md", repo.path + "/src/ui/widgets", repo.path])
        }

        @Test func showInFinderOnARepositoryRowOfTheChangesTabRevealsTheRepositoryFolder() throws {
            let repo = Fixture.submoduleRepo()
            let actions = FakeFileActions()
            let controller = menuController(repo.path, tab: .changes, actions: actions)
            let rows = controller.workspace.sidebarRows().filter { $0.kind == .repo }
            #expect(rows.count == 2)
            for row in rows { controller.choose("Show in Finder", in: controller.menu(for: row)) }
            #expect(actions.revealed == [repo.path, repo.path + "/vendor/lib"])
            controller.choose("Show in Finder", in: controller.rowMenu("lib.c"))
            #expect(actions.revealed.last == repo.path + "/vendor/lib/lib.c")
        }

        @Test func showInFinderOnASubmoduleFolderOfTheFilesTabRevealsIt() {
            let repo = Fixture.submoduleRepo()
            let actions = FakeFileActions()
            let controller = menuController(repo.path, tab: .files, actions: actions)
            expand(controller, "vendor")
            #expect(controller.workspace.row(path: "vendor/lib")?.isSubmodule == true)
            controller.choose("Show in Finder", in: controller.rowMenu("vendor/lib", kind: .directory))
            #expect(actions.revealed == [repo.path + "/vendor/lib"])
            withExtendedLifetime(repo) {}
        }

        // MARK: Move to Trash

        @Test func movingAFileToTheTrashAsksThenTrashesAndRefreshes() async {
            let repo = Fixture.changesRepo()
            let actions = FakeFileActions()
            let prompts = FakePrompts(trash: [true])
            let controller = menuController(repo.path, tab: .files, prompts: prompts, actions: actions)
            controller.choose("Move to Trash", in: controller.rowMenu("README.md"))
            #expect(prompts.trashQuestions == [TrashQuestion(name: "README.md", isFolder: false)])
            #expect(prompts.trashQuestions.map(\.message) == ["Move “README.md” to the Trash?"])
            #expect(actions.trashed == [repo.path + "/README.md"])
            #expect(await waitUntil { controller.workspace.row(path: "README.md") == nil })
            #expect(!exists(repo.path + "/README.md"))
            #expect(prompts.messages.isEmpty)
        }

        @Test func movingAFolderToTheTrashSaysEverythingInItGoes() async {
            let repo = Fixture.changesRepo()
            let actions = FakeFileActions()
            let prompts = FakePrompts(trash: [true])
            let controller = menuController(repo.path, tab: .files, prompts: prompts, actions: actions)
            controller.choose("Move to Trash", in: controller.rowMenu("src", kind: .directory))
            #expect(prompts.trashQuestions.map(\.message) == ["Move “src” and everything in it to the Trash?"])
            #expect(actions.trashed == [repo.path + "/src"])
            #expect(await waitUntil { controller.workspace.row(path: "src") == nil })
            withExtendedLifetime(repo) {}
        }

        @Test func cancellingTheQuestionDoesNothing() async {
            let repo = Fixture.changesRepo()
            let actions = FakeFileActions()
            let prompts = FakePrompts(trash: [false])
            let controller = menuController(repo.path, tab: .files, prompts: prompts, actions: actions)
            controller.choose("Move to Trash", in: controller.rowMenu("README.md"))
            #expect(prompts.trashQuestions.count == 1)
            #expect(actions.trashed.isEmpty)
            await waitIdle(controller.workspace)
            #expect(exists(repo.path + "/README.md"))
            #expect(controller.workspace.row(path: "README.md") != nil)
            withExtendedLifetime(repo) {}
        }

        @Test func aFailureIsToldAndNothingElseHappens() async {
            let repo = Fixture.changesRepo()
            let actions = FakeFileActions()
            actions.failsToTrash = true
            let prompts = FakePrompts(trash: [true])
            let controller = menuController(repo.path, tab: .files, prompts: prompts, actions: actions)
            let before = controller.workspace.sidebarRows()
            controller.choose("Move to Trash", in: controller.rowMenu("README.md"))
            #expect(prompts.messages == ["the Trash is full"])
            #expect(actions.trashed.isEmpty)
            await waitIdle(controller.workspace)
            #expect(exists(repo.path + "/README.md"))
            #expect(!controller.workspace.isScanning)
            #expect(controller.workspace.sidebarRows() == before)
            withExtendedLifetime(repo) {}
        }

        @Test func nothingOutsideTheOpenedFolderAndNotTheFolderItselfIsTrashed() {
            let repo = Fixture.changesRepo()
            let outside = TempDir()
            outside.write("keep.txt", "keep\n")
            let actions = FakeFileActions()
            let prompts = FakePrompts(trash: [true, true, true, true])
            let controller = menuController(repo.path, tab: .files, prompts: prompts, actions: actions)
            controller.moveToTrash(repo.path)
            controller.moveToTrash(repo.path + "/")
            controller.moveToTrash(outside.path + "/keep.txt")
            controller.moveToTrash(repo.path + "/../" + (outside.path as NSString).lastPathComponent + "/keep.txt")
            #expect(prompts.trashQuestions.isEmpty)
            #expect(actions.trashed.isEmpty)
            #expect(exists(outside.path + "/keep.txt"))
            #expect(exists(repo.path + "/README.md"))
        }

        @Test func aLinkIsTrashedAsTheLinkNotAsItsTarget() {
            let repo = Fixture.changesRepo()
            symlink(repo.path + "/src", at: repo.path + "/link")
            let prompts = FakePrompts(trash: [false])
            let controller = menuController(repo.path, tab: .files, prompts: prompts)
            controller.moveToTrash(repo.path + "/link")
            #expect(prompts.trashQuestions == [TrashQuestion(name: "link", isFolder: false)])
        }

        // MARK: Tabs of trashed files

        @Test func aReadTabOfATrashedFileStaysAndShowsItAsDeleted() async {
            let repo = Fixture.changesRepo()
            let controller = menuController(repo.path, tab: .files, prompts: FakePrompts(trash: [true]))
            controller.openForEdit("README.md", mode: .read)
            controller.choose("Move to Trash", in: controller.rowMenu("README.md"))
            #expect(await waitUntil { controller.workspace.tabs.first?.change?.kind == .deleted })
            await waitIdle(controller.workspace)
            #expect(controller.workspace.tabNames == ["README.md"])
            #expect(controller.workspace.tabs[0].mode == .read)
            #expect(controller.workspace.content?.document?.kind == .deleted)
            withExtendedLifetime(repo) {}
        }

        @Test func anEditTabWithUnsavedEditsOfATrashedFileGetsTheDeletedStrip() async {
            let repo = Fixture.changesRepo()
            let controller = menuController(repo.path, tab: .files, prompts: FakePrompts(trash: [true]))
            controller.openForEdit("README.md")
            controller.showEdit(nil)
            controller.type("mine ")
            controller.choose("Move to Trash", in: controller.rowMenu("README.md"))
            #expect(await waitUntil { controller.stripShown })
            #expect(controller.editor?.conflict == .deleted)
            #expect(controller.workspace.tabs[0].mode == .edit)
            #expect(controller.workspace.isUnsaved(repo.path + "/README.md"))
            withExtendedLifetime(repo) {}
        }

        @Test func aCleanEditTabOfATrashedFileLeavesEditMode() async {
            let repo = Fixture.changesRepo()
            let controller = menuController(repo.path, tab: .files, prompts: FakePrompts(trash: [true]))
            controller.openForEdit("README.md")
            controller.showEdit(nil)
            controller.choose("Move to Trash", in: controller.rowMenu("README.md"))
            #expect(await waitUntil { controller.workspace.tabs.first?.mode == .diff })
            #expect(controller.workspace.buffers.isEmpty)
            withExtendedLifetime(repo) {}
        }
    }
}
