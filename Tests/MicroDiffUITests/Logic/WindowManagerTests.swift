import AppKit
import MicroDiffCore
import MicroDiffTestSupport
import Testing
@testable import MicroDiffUI

extension UITests {
    /// One app, many windows: requests from later starts, finding the window of a folder, the key window,
    /// closing, cascading. Windows are made but never shown.
    @MainActor
    @Suite(.serialized)
    struct WindowManagerTests {
        private func manager() -> WindowManager {
            _ = NSApplication.shared
            let manager = WindowManager(showsWindows: false)
            manager.markReady()
            return manager
        }

        /// Opens and waits for the answer (it is asynchronous when git has to find the repository root).
        @discardableResult
        private func open(_ manager: WindowManager, _ folder: String, files: [String] = [], mode: ViewMode? = nil) async -> WindowManager.OpenResult? {
            var result: WindowManager.OpenResult?
            manager.open(folder: folder, files: files, mode: mode) { result = $0 }
            _ = await waitUntil { result != nil }
            return result
        }

        private func controller(_ result: WindowManager.OpenResult?) -> MainWindowController? {
            switch result {
            case let .opened(controller)?, let .focused(controller)?: controller
            default: nil
            }
        }

        private func isOpened(_ result: WindowManager.OpenResult?) -> Bool {
            if case .opened? = result { true } else { false }
        }

        private func isFocused(_ result: WindowManager.OpenResult?) -> Bool {
            if case .focused? = result { true } else { false }
        }

        // MARK: requests

        @Test func aRequestForAnotherFolderOpensASecondWindowWithItsOwnWorkspace() async throws {
            let first = Fixture.changesRepo()
            let second = Fixture.cleanRepo()
            let manager = manager()
            let a = try #require(controller(await open(manager, first.path)))
            let resultB = await open(manager, second.path)
            #expect(isOpened(resultB))
            let b = try #require(controller(resultB))
            #expect(manager.controllers.count == 2)
            #expect(a !== b)
            #expect(a.workspace !== b.workspace)
            #expect(a.window !== b.window)
            await waitIdle(a.workspace)
            await waitIdle(b.workspace)
            #expect(a.workspace.snapshot?.totalChangeCount ?? 0 > 0)
            #expect(b.workspace.snapshot?.totalChangeCount == 0)
        }

        @Test func theSameFolderOrRepositoryFocusesTheExistingWindow() async throws {
            let repo = Fixture.changesRepo()
            let manager = manager()
            let window = try #require(controller(await open(manager, repo.path)))
            await waitIdle(window.workspace)

            let again = await open(manager, repo.path)
            #expect(isFocused(again))
            #expect(controller(again) === window)
            // A folder inside the repository: git finds the same root.
            let inside = await open(manager, repo.path + "/src")
            #expect(isFocused(inside))
            #expect(controller(inside) === window)
            // The same folder written differently.
            let dotted = await open(manager, repo.path + "/src/../")
            #expect(controller(dotted) === window)
            #expect(manager.controllers.count == 1)
        }

        @Test func aFolderReachedThroughASymlinkFindsItsWindow() async throws {
            let repo = Fixture.changesRepo()
            let links = TempDir()
            let link = links.path + "/link"
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: repo.path)
            let manager = manager()
            let window = try #require(controller(await open(manager, repo.path)))
            #expect(controller(await open(manager, link)) === window)
            #expect(manager.controllers.count == 1)
        }

        @Test func aFileRequestOpensTheFileAsATabInTheExistingWindow() async throws {
            let repo = Fixture.changesRepo()
            let manager = manager()
            let window = try #require(controller(await open(manager, repo.path)))
            await waitIdle(window.workspace)

            let result = await open(manager, repo.path + "/src", files: [repo.path + "/src/app.swift"])
            #expect(controller(result) === window)
            #expect(await waitUntil { window.workspace.tabPaths == [repo.path + "/src/app.swift"] })
            // Relative paths are relative to the repository root, like `--open`.
            await open(manager, repo.path, files: ["README.md"], mode: .read)
            #expect(await waitUntil { window.workspace.tabPaths.contains(repo.path + "/README.md") })
            #expect(window.workspace.tabs.last?.mode == .read)
        }

        @Test func aFileRequestForANewFolderOpensTheTabOnceTheFirstScanIsIn() async throws {
            let repo = Fixture.changesRepo()
            let manager = manager()
            let window = try #require(controller(await open(manager, repo.path, files: [repo.path + "/src/other.swift"])))
            #expect(await waitUntil { window.workspace.tabPaths == [repo.path + "/src/other.swift"] })
            #expect(window.workspace.tabs.first?.change != nil)
        }

        @Test func aFolderThatDoesNotExistIsRefusedWithoutAWindow() async throws {
            let repo = Fixture.changesRepo()
            let manager = manager()
            for folder in ["/no/such/folder/anywhere", repo.path + "/README.md", "relative/path"] {
                let result = await open(manager, folder)
                guard case .refused? = result else {
                    Issue.record("\(folder) was not refused")
                    continue
                }
            }
            #expect(manager.controllers.isEmpty)
        }

        @Test func anEmptyFolderOnlyBringsTheFrontWindowForward() async throws {
            let repo = Fixture.cleanRepo()
            let manager = manager()
            guard case .refused? = await open(manager, "") else {
                Issue.record("nothing to bring forward, but not refused")
                return
            }
            let window = try #require(controller(await open(manager, repo.path)))
            let result = await open(manager, "")
            #expect(isFocused(result))
            #expect(controller(result) === window)
        }

        @Test func requestsThatArriveBeforeLaunchingFinishedWaitForIt() async throws {
            let repo = Fixture.cleanRepo()
            _ = NSApplication.shared
            let manager = WindowManager(showsWindows: false)
            var result: WindowManager.OpenResult?
            manager.handle(InstanceRequest(folder: repo.path)) { result = $0 }
            try await Task.sleep(for: .milliseconds(20))
            #expect(result == nil)
            #expect(manager.controllers.isEmpty)
            manager.markReady()
            #expect(await waitUntil { result != nil })
            #expect(isOpened(result))
            #expect(manager.controllers.count == 1)
        }

        @Test func aRequestCarriesItsModeToTheTab() async throws {
            let repo = Fixture.changesRepo()
            let manager = manager()
            var result: WindowManager.OpenResult?
            manager.handle(InstanceRequest(folder: repo.path, openFiles: ["src/app.swift"], mode: "read")) { result = $0 }
            #expect(await waitUntil { result != nil })
            let window = try #require(controller(result))
            #expect(await waitUntil { !window.workspace.tabs.isEmpty })
            #expect(window.workspace.tabs.first?.mode == .read)
        }

        @Test func aRequestInEditModeOpensTheFileInTheEditor() async throws {
            let repo = Fixture.changesRepo()
            let manager = manager()
            var result: WindowManager.OpenResult?
            manager.handle(InstanceRequest(folder: repo.path, openFiles: ["src/other.swift"], mode: "edit")) { result = $0 }
            #expect(await waitUntil { result != nil })
            let window = try #require(controller(result))
            #expect(await waitUntil { !window.workspace.tabs.isEmpty })
            #expect(window.workspace.tabs.first?.mode == .edit)
            #expect(window.rootView.editor?.textView.string == "let other = 10\nlet more = 2\n")
        }

        // MARK: key window and menu

        @Test func menuCommandsGoToTheKeyWindow() async throws {
            let first = Fixture.changesRepo()
            let second = Fixture.changesRepo()
            _ = NSApplication.shared
            let manager = WindowManager(showsWindows: false)
            manager.markReady()
            let delegate = AppDelegate(options: LaunchOptions(arguments: ["MicroDiff"]), prescan: nil, windows: manager)
            let a = try #require(controller(await open(manager, first.path)))
            let b = try #require(controller(await open(manager, second.path)))
            a.workspace.scanNow()
            b.workspace.scanNow()

            // The newest window is in front.
            #expect(manager.keyController === b)
            a.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: a.window))
            #expect(manager.keyController === a)
            delegate.showFiles(nil)
            #expect(a.workspace.sidebarTab == .files)
            #expect(b.workspace.sidebarTab == .changes)

            b.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: b.window))
            b.workspace.openFile(second.path + "/src/app.swift", mode: .diff, pin: true, synchronously: true)
            delegate.showRead(nil)
            #expect(b.workspace.tabs.first?.mode == .read)
            delegate.closeTab(nil)
            #expect(b.workspace.tabs.isEmpty)
            #expect(a.workspace.sidebarTab == .files)
        }

        @Test func theMenuHasAWindowMenuWithTheStandardItems() throws {
            _ = NSApplication.shared
            let delegate = AppDelegate(options: LaunchOptions(arguments: ["MicroDiff"]), prescan: nil, windows: WindowManager(showsWindows: false))
            let menu = delegate.makeMenu()
            let window = try #require(menu.items.first { $0.title == "Window" }?.submenu)
            let titles = window.items.map(\.title)
            #expect(titles.contains("Minimize"))
            #expect(titles.contains("Zoom"))
            #expect(titles.contains("Bring All to Front"))
            let cycle = try #require(window.items.first { $0.title == "Cycle Through Windows" })
            #expect(cycle.keyEquivalent == "`")
            #expect(window.items.first { $0.title == "Minimize" }?.keyEquivalent == "m")
            let file = try #require(menu.items.first { $0.title == "File" }?.submenu)
            let close = try #require(file.items.first { $0.title == "Close Window" })
            #expect(close.keyEquivalent == "w")
            #expect(close.keyEquivalentModifierMask == [.command, .shift])
        }

        @Test func cycleThroughWindowsDoesNothingWithOneWindow() async throws {
            let manager = manager()
            let repo = Fixture.cleanRepo()
            let window = try #require(controller(await open(manager, repo.path)))
            manager.cycleWindows()
            #expect(manager.keyController === window)
        }

        // MARK: closing

        @Test func closingOneOfSeveralWindowsFreesItAndLeavesTheOthersWorking() async throws {
            let first = Fixture.changesRepo()
            let second = Fixture.changesRepo()
            let manager = manager()
            let keep = try #require(controller(await open(manager, first.path)))
            await waitIdle(keep.workspace)
            let refs = try await openAndClose(manager, second)
            #expect(manager.controllers.count == 1)
            #expect(manager.controllers.first === keep)
            let gone = await eventually { refs.allSatisfy { $0.1.isGone } }
            #expect(gone, "still alive: \(refs.filter { !$0.1.isGone }.map(\.0))")

            // The other window still scans and follows changes.
            first.write("later.txt", "new\n")
            keep.workspace.refresh()
            #expect(await waitUntil { keep.workspace.snapshot?.repos.first?.changes.contains { $0.path == "later.txt" } ?? false })
            #expect(manager.keyController === keep)
        }

        /// Opens a window with a running watcher and an open file, closes it, and returns weak references to its parts.
        private func openAndClose(_ manager: WindowManager, _ repo: TestRepo) async throws -> [(String, WeakRef<AnyObject>)] {
            let closing = try #require(controller(await open(manager, repo.path)))
            await waitIdle(closing.workspace)
            closing.workspace.openFile(repo.path + "/src/app.swift", mode: .diff, pin: true, synchronously: true)
            let watcher: FSWatcher? = storedProperty(closing.workspace, "watcher")
            #expect(watcher != nil)
            let refs: [(String, WeakRef<AnyObject>)] = [
                ("controller", WeakRef(closing)), ("window", WeakRef(closing.window)), ("workspace", WeakRef(closing.workspace)),
                ("watcher", WeakRef(watcher)),
            ]
            closing.window.close()
            return refs
        }

        @Test func closingTheLastWindowAsksToQuit() async throws {
            let repo = Fixture.cleanRepo()
            let manager = manager()
            let delegate = AppDelegate(options: LaunchOptions(arguments: ["MicroDiff"]), prescan: nil, windows: manager)
            let window = try #require(controller(await open(manager, repo.path)))
            window.window.close()
            #expect(manager.controllers.isEmpty)
            #expect(manager.keyController == nil)
            #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        }

        // MARK: placement

        @Test func newWindowsAreCascadedFromTheWindowInFront() async throws {
            let first = Fixture.cleanRepo()
            let second = Fixture.cleanRepo()
            let third = Fixture.cleanRepo()
            let manager = manager()
            let a = try #require(controller(await open(manager, first.path)))
            let visible = (a.window.screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let start = CGRect(x: visible.minX + 40, y: visible.maxY - 40 - 500, width: 700, height: 500)
            a.window.setFrame(start, display: false)
            let b = try #require(controller(await open(manager, second.path)))
            #expect(b.window.frame == start.offsetBy(dx: 26, dy: -26))
            let c = try #require(controller(await open(manager, third.path)))
            #expect(c.window.frame == start.offsetBy(dx: 52, dy: -52))
        }

        @Test func cascadeStepsDownAndRight() {
            let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
            let frame = WindowManager.cascadedFrame(after: CGRect(x: 100, y: 300, width: 600, height: 400), visible: visible, occupied: [])
            #expect(frame == CGRect(x: 126, y: 274, width: 600, height: 400))
        }

        @Test func cascadeWrapsToTheTopLeftAtTheScreenEdge() {
            let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
            let low = WindowManager.cascadedFrame(after: CGRect(x: 100, y: 30, width: 600, height: 400), visible: visible, occupied: [])
            #expect(low == CGRect(x: 0, y: 500, width: 600, height: 400))
            let right = WindowManager.cascadedFrame(after: CGRect(x: 830, y: 300, width: 600, height: 400), visible: visible, occupied: [])
            #expect(right.origin == CGPoint(x: 0, y: 500))
        }

        @Test func cascadeNeverPutsAWindowExactlyOnAnother() {
            let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
            let reference = CGRect(x: 100, y: 300, width: 600, height: 400)
            // Something already sits one step down.
            let frame = WindowManager.cascadedFrame(after: reference, visible: visible, occupied: [CGPoint(x: 126, y: 674)])
            #expect(frame.origin == CGPoint(x: 152, y: 248))
        }

        @Test func cascadeShrinksAWindowBiggerThanTheScreen() {
            let visible = CGRect(x: 0, y: 0, width: 800, height: 600)
            let frame = WindowManager.cascadedFrame(after: CGRect(x: 0, y: 0, width: 1200, height: 900), visible: visible, occupied: [])
            #expect(frame.size == CGSize(width: 800, height: 600))
            #expect(visible.contains(frame))
        }

        @Test func containsMeansTheSameFolderOrInsideIt() {
            #expect(WindowManager.contains("/a/b", "/a/b"))
            #expect(WindowManager.contains("/a/b", "/a/b/c"))
            #expect(!WindowManager.contains("/a/b", "/a/bc"))
            #expect(!WindowManager.contains("/a/b", "/a"))
        }
    }
}
