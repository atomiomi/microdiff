import AppKit
import MicroDiffCore
import MicroDiffTestSupport
import Testing
@testable import MicroDiffUI

extension UITests {
    /// `⌘B`: the sidebar goes away and comes back. The windows are never shown, and the remembered choice lives in a
    /// throwaway UserDefaults suite, never in the user's own.
    @MainActor
    @Suite
    struct SidebarToggleTests {
        private static let repo = Fixture.changesRepo()
        private static let key = RootView.sidebarHiddenKey

        private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
            let name = "microdiff-tests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            try body(defaults)
        }

        private func controller(_ path: String = SidebarToggleTests.repo.path, defaults: UserDefaults?) -> MainWindowController {
            _ = NSApplication.shared
            let controller = MainWindowController(path: path, defaults: defaults)
            controller.window.setContentSize(NSSize(width: 1000, height: 600))
            controller.workspace.scanNow()
            controller.rootView.layoutSubtreeIfNeeded()
            return controller
        }

        private func frames(_ root: RootView) -> [CGRect] {
            [root.sidebarTabs.frame, root.tree.frame, root.tabBar.frame, root.codeView.frame]
        }

        // MARK: menu

        @Test func theMenuItemIsCommandBAndItsTitleSaysWhatItWillDo() throws {
            _ = NSApplication.shared
            try withDefaults { defaults in
                let manager = WindowManager(showsWindows: false, defaults: defaults)
                let delegate = AppDelegate(options: LaunchOptions(arguments: ["MicroDiff"]), prescan: nil, windows: manager)
                let controller = manager.makeWindow(path: Self.repo.path)
                let view = try #require(delegate.makeMenu().items.first { $0.title == "View" }?.submenu)
                let item = try #require(view.items.first { $0.action == #selector(AppDelegate.toggleSidebar(_:)) })
                #expect(item.keyEquivalent == "b")
                #expect(item.keyEquivalentModifierMask == [.command])
                #expect(item.title == "Hide Sidebar")

                #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
                #expect(controller.sidebarHidden)
                #expect(delegate.validateMenuItem(item))
                #expect(item.title == "Show Sidebar")

                #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
                #expect(!controller.sidebarHidden)
                #expect(delegate.validateMenuItem(item))
                #expect(item.title == "Hide Sidebar")
            }
        }

        // MARK: layout

        @Test func hidingGivesTheMainAreaTheWholeWindowAndShowingRestoresTheFrames() {
            let controller = controller(defaults: nil)
            let root = controller.rootView
            root.setSidebarWidthTemporarily(300)
            root.layoutSubtreeIfNeeded()
            let before = frames(root)
            #expect(root.codeView.frame.minX == 301)

            controller.toggleSidebar(nil)
            #expect(controller.sidebarHidden)
            #expect(root.sidebarTabs.isHidden && root.tree.isHidden)
            let width = root.bounds.width
            #expect(root.tabBar.frame.minX == 0 && root.tabBar.frame.width == width)
            #expect(root.codeView.frame.minX == 0 && root.codeView.frame.width == width)
            #expect(root.subviews.filter { !$0.isHidden }.allSatisfy { $0.frame.minX >= 0 })

            controller.toggleSidebar(nil)
            #expect(!controller.sidebarHidden)
            #expect(!root.sidebarTabs.isHidden && !root.tree.isHidden)
            #expect(frames(root) == before)
            #expect(root.sidebarWidth == 300)
        }

        @Test func theEditorFillsTheWindowToo() {
            let repo = editRepo()
            let controller = controller(repo.path, defaults: nil)
            controller.openForEdit("a.txt", mode: .diff)
            controller.showEdit(nil)
            let root = controller.rootView
            let shown = root.editor?.frame
            #expect(shown == root.codeView.frame)

            controller.toggleSidebar(nil)
            #expect(root.editor?.frame == CGRect(x: 0, y: root.codeView.frame.minY, width: root.bounds.width, height: root.codeView.frame.height))
            #expect(root.editor?.frame == root.codeView.frame)

            controller.toggleSidebar(nil)
            #expect(root.editor?.frame == shown)
        }

        @Test func theMessageStaysCenteredInTheWiderMainArea() {
            let controller = controller(defaults: nil)
            let root = controller.rootView
            #expect(root.message == "no file open")
            func messageMid() -> CGFloat? { root.subviews.first { !$0.isHidden && $0.frame.height == Theme.lineHeight }?.frame.midX }
            #expect(abs((messageMid() ?? 0) - (root.bounds.width + root.sidebarWidth + 1) / 2) <= 1)
            controller.toggleSidebar(nil)
            #expect(abs((messageMid() ?? 0) - root.bounds.width / 2) <= 1)
        }

        // MARK: what survives

        @Test func theTabTheScrollPositionAndTheFolderStatesSurviveHideAndShow() throws {
            let repo = TestRepo()
            for index in 0..<80 { repo.write("dir/file\(index).txt", "x\n") }
            repo.write("other/a.txt", "x\n")
            repo.commitAll("many")
            for index in 0..<80 { repo.write("dir/file\(index).txt", "y\n") }
            let controller = controller(repo.path, defaults: nil)
            let root = controller.rootView
            root.frame = NSRect(x: 0, y: 0, width: 1000, height: 400)
            root.layoutSubtreeIfNeeded()

            controller.showFiles(nil)
            controller.workspace.toggle(try #require(controller.workspace.row(path: "dir", kind: .directory)))
            root.tree.layoutSubtreeIfNeeded()
            root.tree.scroll(to: CGPoint(x: 0, y: 400))
            let scroll = root.tree.visibleContentRect.origin
            #expect(scroll.y > 0)
            let rows = controller.workspace.sidebarRows()
            let expanded = rows.filter(\.isExpanded).map(\.id)
            #expect(!expanded.isEmpty)

            controller.toggleSidebar(nil)
            controller.toggleSidebar(nil)

            #expect(controller.workspace.sidebarTab == .files)
            #expect(root.sidebarTabs.selected == .files)
            #expect(root.tree.visibleContentRect.origin == scroll)
            #expect(controller.workspace.sidebarRows() == rows)
            #expect(controller.workspace.sidebarRows().filter(\.isExpanded).map(\.id) == expanded)
        }

        @Test func aChangeThatArrivesWhileHiddenIsThereWhenShown() {
            let repo = Fixture.changesRepo()
            let controller = controller(repo.path, defaults: nil)
            let root = controller.rootView
            let count = root.sidebarTabs.changeCount
            controller.toggleSidebar(nil)

            repo.write("brand-new.txt", "hello\n")
            controller.workspace.scanNow()
            controller.toggleSidebar(nil)

            #expect(root.sidebarTabs.changeCount == count + 1)
            #expect(root.tree.rows.contains { $0.name == "brand-new.txt" })
        }

        // MARK: ⌘1 and ⌘2

        @Test func commandOneAndTwoShowTheSidebarOnTheirTab() {
            let controller = controller(defaults: nil)
            let root = controller.rootView

            controller.toggleSidebar(nil)
            controller.showFiles(nil)
            #expect(!controller.sidebarHidden)
            #expect(controller.workspace.sidebarTab == .files)
            #expect(root.sidebarTabs.selected == .files)
            #expect(root.tree.frame.width == root.sidebarWidth)

            controller.toggleSidebar(nil)
            controller.showChanges(nil)
            #expect(!controller.sidebarHidden)
            #expect(controller.workspace.sidebarTab == .changes)

            controller.toggleSidebar(nil)
            controller.showChanges(nil)
            #expect(!controller.sidebarHidden)
            #expect(controller.workspace.sidebarTab == .changes)
        }

        // MARK: keyboard focus

        @Test func theKeyboardLeavesTheSidebarWhenItHides() {
            let controller = controller(defaults: nil)
            controller.workspace.openFile(Self.repo.path + "/README.md", mode: .read, pin: true, synchronously: true)
            let window = controller.window
            #expect(window.makeFirstResponder(controller.rootView.tree))
            controller.toggleSidebar(nil)
            #expect(window.firstResponder === controller.rootView.codeView)
        }

        @Test func inEditModeTheKeyboardGoesToTheEditor() {
            let repo = editRepo()
            let controller = controller(repo.path, defaults: nil)
            controller.openForEdit("a.txt", mode: .diff)
            controller.showEdit(nil)
            #expect(controller.window.makeFirstResponder(controller.rootView.tree))
            #expect(!controller.isEditorFirstResponder)
            controller.toggleSidebar(nil)
            #expect(controller.isEditorFirstResponder)
        }

        @Test func withNoFileOpenTheTreeStillLetsGoOfTheKeyboard() {
            let controller = controller(defaults: nil)
            #expect(controller.window.makeFirstResponder(controller.rootView.tree))
            controller.toggleSidebar(nil)
            #expect(controller.window.firstResponder !== controller.rootView.tree)
        }

        @Test func focusElsewhereStaysWhereItIs() {
            let controller = controller(defaults: nil)
            controller.window.makeFirstResponder(nil)
            controller.toggleSidebar(nil)
            #expect(controller.window.firstResponder !== controller.rootView.codeView)
        }

        // MARK: the preference

        @Test func hiddenIsRememberedForTheNextWindow() {
            withDefaults { defaults in
                #expect(!controller(defaults: defaults).sidebarHidden)
                let first = controller(defaults: defaults)
                first.toggleSidebar(nil)
                #expect(defaults.bool(forKey: Self.key))

                let second = controller(defaults: defaults)
                #expect(second.sidebarHidden)
                #expect(second.rootView.tree.isHidden)
                #expect(second.rootView.codeView.frame.minX == 0)

                second.toggleSidebar(nil)
                #expect(!defaults.bool(forKey: Self.key))
                #expect(!controller(defaults: defaults).sidebarHidden)
            }
        }

        @Test func aWindowWithoutDefaultsNeitherReadsNorWritesIt() {
            withDefaults { defaults in
                defaults.set(true, forKey: Self.key)
                let controller = controller(defaults: nil)
                #expect(!controller.sidebarHidden)
                controller.toggleSidebar(nil)
                #expect(controller.sidebarHidden)
                #expect(defaults.bool(forKey: Self.key))
            }
            withDefaults { defaults in
                let controller = controller(defaults: nil)
                controller.toggleSidebar(nil)
                #expect(defaults.object(forKey: Self.key) == nil)
            }
        }

        @Test func snapshotBenchmarkAndSoakRunsGetNoDefaultsButALiveRunDoes() {
            _ = NSApplication.shared
            func hasDefaults(_ arguments: [String]) -> Bool {
                AppDelegate(options: LaunchOptions(arguments: ["MicroDiff"] + arguments), prescan: nil).windows.defaults != nil
            }
            #expect(hasDefaults(["/repo"]))
            #expect(!hasDefaults(["/repo", "--snapshot", "out.png", "--sidebar", "hidden"]))
            #expect(!hasDefaults(["/repo", "--bench"]))
            #expect(!hasDefaults(["/repo", "--soak", "5"]))
        }

        @Test func aSnapshotWithSidebarHiddenRendersWithoutTheSidebarAndLeavesTheSettingAlone() {
            withDefaults { defaults in
                Render.prepareApplication()
                let controller = MainWindowController(path: Self.repo.path, defaults: nil)
                #expect(controller.renderSnapshot(size: CGSize(width: 800, height: 480), sidebarTab: .changes, open: [], mode: nil, sidebarHidden: true) != nil)
                #expect(controller.sidebarHidden)
                #expect(controller.rootView.codeView.frame.minX == 0)
                #expect(defaults.object(forKey: Self.key) == nil)
            }
        }
    }
}
