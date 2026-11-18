import AppKit
import MicroDiffCore
import MicroDiffTestSupport
import Testing
@testable import MicroDiffUI

extension UITests {
    /// The window controller wires the workspace to the views and handles the menu actions. The window is never shown.
    @MainActor
    @Suite
    struct WindowControllerTests {
        private static let repo = Fixture.changesRepo()

        private func controller(_ repo: TestRepo = Self.repo) -> MainWindowController {
            _ = NSApplication.shared
            let controller = MainWindowController(path: repo.path)
            controller.workspace.scanNow()
            controller.window.contentView?.layoutSubtreeIfNeeded()
            return controller
        }

        private func root(_ controller: MainWindowController) throws -> RootView {
            try #require(controller.window.contentView as? RootView)
        }

        private func open(_ controller: MainWindowController, _ paths: [String], mode: ViewMode = .file) {
            for path in paths {
                controller.workspace.openFile(Self.repo.path + "/" + path, mode: mode, pin: true, synchronously: true)
            }
        }

        // MARK: tabs from the menu

        @Test func nextAndPreviousTabWrapAround() {
            let controller = controller()
            open(controller, ["README.md", "src/app.swift", "src/other.swift"])
            #expect(controller.workspace.activeTab == 2)

            controller.nextTab(nil)
            #expect(controller.workspace.activeTab == 0)
            controller.nextTab(nil)
            #expect(controller.workspace.activeTab == 1)
            controller.previousTab(nil)
            controller.previousTab(nil)
            #expect(controller.workspace.activeTab == 2)
        }

        @Test func nextTabDoesNothingWithOneTabOrNone() {
            let controller = controller()
            controller.nextTab(nil)
            #expect(controller.workspace.activeTab == nil)
            open(controller, ["README.md"])
            controller.nextTab(nil)
            controller.previousTab(nil)
            #expect(controller.workspace.activeTab == 0)
        }

        @Test func closeTabClosesTheActiveTab() {
            let controller = controller()
            open(controller, ["README.md", "src/app.swift"])
            controller.closeTab(nil)
            #expect(controller.workspace.tabPaths == [Self.repo.path + "/README.md"])
            #expect(controller.workspace.activeTab == 0)
        }

        @Test func toggleDiffFileSwitchesTheActiveTabsModeBothWays() throws {
            let controller = controller()
            controller.toggleDiffFile(nil)
            #expect(controller.workspace.tabs.isEmpty)

            open(controller, ["src/app.swift"], mode: .diff)
            controller.toggleDiffFile(nil)
            #expect(controller.workspace.tabs[0].mode == .file)
            controller.toggleDiffFile(nil)
            #expect(controller.workspace.tabs[0].mode == .diff)
        }

        // MARK: sidebar from the menu

        @Test func showFilesAndShowChangesSwitchTheSidebarAndTheTreeStyle() throws {
            let controller = controller()
            let root = try root(controller)
            #expect(controller.workspace.sidebarTab == .changes)

            controller.showFiles(nil)
            #expect(controller.workspace.sidebarTab == .files)
            #expect(root.sidebarTabs.selected == .files)
            #expect(root.tree.rows.contains { $0.name == "README.md" })

            controller.showChanges(nil)
            #expect(controller.workspace.sidebarTab == .changes)
            #expect(root.sidebarTabs.selected == .changes)
            #expect(root.tree.rows.contains { $0.name == "app.swift" || $0.path == "src/app.swift" })
        }

        @Test func eachSidebarTabRemembersItsScrollPosition() throws {
            let repo = TestRepo()
            for index in 0..<80 { repo.write("dir/file\(index).txt", "x\n") }
            repo.commitAll("many")
            for index in 0..<80 { repo.write("dir/file\(index).txt", "y\n") }
            let controller = controller(repo)
            let root = try root(controller)
            root.frame = NSRect(x: 0, y: 0, width: 1180, height: 400)
            root.layoutSubtreeIfNeeded()

            controller.showFiles(nil)
            // The changes list is long as well (80 changed files). Scroll both, differently.
            controller.workspace.toggle(try #require(controller.workspace.row(path: "dir", kind: .directory)))
            root.tree.layoutSubtreeIfNeeded()
            root.tree.scroll(to: CGPoint(x: 0, y: 400))
            let filesScroll = root.tree.visibleContentRect.origin.y
            #expect(filesScroll > 0)

            controller.showChanges(nil)
            // A tab that was never scrolled starts at the top.
            #expect(root.tree.visibleContentRect.origin.y == 0)
            root.tree.scroll(to: CGPoint(x: 0, y: 200))
            let changesScroll = root.tree.visibleContentRect.origin.y
            #expect(changesScroll > 0)

            controller.showFiles(nil)
            #expect(root.tree.visibleContentRect.origin.y == filesScroll)
            controller.showChanges(nil)
            #expect(root.tree.visibleContentRect.origin.y == changesScroll)
        }

        @Test func choosingTheTabThatIsAlreadyShownChangesNothing() throws {
            let controller = controller()
            let root = try root(controller)
            root.tree.scroll(to: CGPoint(x: 0, y: 0))
            controller.showChanges(nil)
            #expect(controller.workspace.sidebarTab == .changes)
        }

        // MARK: what the main area shows

        @Test func theMainAreaSaysSoWhenNoFileIsOpenAndShowsAMessageForABinaryFile() throws {
            let controller = controller()
            let root = try root(controller)
            #expect(root.message == "no file open")
            #expect(root.codeView.isHidden)

            open(controller, ["data.bin"], mode: .diff)
            #expect(root.message == DocumentLoader.binaryMessage)
            #expect(root.codeView.isHidden)

            open(controller, ["README.md"])
            #expect(root.message == nil)
            #expect(!root.codeView.isHidden)

            controller.closeTab(nil)
            controller.closeTab(nil)
            #expect(root.message == "no file open")
        }

        @Test func theTitleIsTheFolderNameAndTheCountsAreShown() throws {
            let controller = controller()
            let root = try root(controller)
            #expect(root.title == folderName(Self.repo.path))
            #expect(root.sidebarTabs.changeCount == 6)
        }

        @Test func openingAnotherFolderReplacesTheWorkspaceAndClearsTheTabs() async throws {
            let controller = controller()
            let root = try root(controller)
            open(controller, ["README.md"])
            let other = Fixture.cleanRepo()

            controller.open(path: other.path)

            #expect(controller.workspace.tabs.isEmpty)
            #expect(await waitUntil { controller.workspace.snapshot != nil })
            #expect(controller.workspace.rootPath == other.path)
            #expect(root.title == folderName(other.path))
            #expect(root.message == "no file open")
            #expect(root.sidebarTabs.changeCount == 0)
        }

        @Test func openingAFolderThatIsNotARepoSaysSo() async throws {
            let controller = controller()
            let root = try root(controller)
            let folder = Fixture.plainFolder()
            controller.open(path: folder.path)
            #expect(await waitUntil { controller.workspace.snapshot != nil })
            #expect(root.tree.emptyMessage == "not a git repository")
        }

        // MARK: sidebar width

        private func resizeHandle(_ root: RootView) throws -> NSView {
            try #require(root.subviews.first { String(describing: type(of: $0)).contains("SidebarResizeHandle") })
        }

        @Test func draggingTheSidebarEdgeResizesItWithinLimitsAndRemembersTheWidth() throws {
            let key = RootView.sidebarWidthKey
            let saved = UserDefaults.standard.object(forKey: key)
            defer {
                if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
            let controller = controller()
            let root = try root(controller)
            root.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
            let handle = try resizeHandle(root)

            handle.mouseDragged(with: Event.drag(inWindowAt: CGPoint(x: 400.4, y: 100)))
            #expect(root.sidebarWidth == 400)
            #expect(UserDefaults.standard.double(forKey: key) == 400)

            // Not narrower than 160, and the code area keeps at least 240.
            handle.mouseDragged(with: Event.drag(inWindowAt: CGPoint(x: 20, y: 100)))
            #expect(root.sidebarWidth == 160)
            handle.mouseDragged(with: Event.drag(inWindowAt: CGPoint(x: 5000, y: 100)))
            #expect(root.sidebarWidth == 760)

            // The layout follows.
            root.layoutSubtreeIfNeeded()
            #expect(root.tree.frame.width == 760)
            #expect(root.codeView.frame.minX == 761)
        }

        @Test func aClickOnTheResizeHandleDoesNothing() throws {
            let controller = controller()
            let root = try root(controller)
            let before = root.sidebarWidth
            try resizeHandle(root).mouseDown(with: makeMouseDown())
            #expect(root.sidebarWidth == before)
        }
    }
}
