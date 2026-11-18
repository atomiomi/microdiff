import AppKit
import MicroDiffCore
import MicroDiffTestSupport
import Testing
@testable import MicroDiffUI

/// Sideways scrolling of the sidebar tree: content width, input, position handling.
extension UITests {
    @MainActor
    @Suite
    struct TreeHorizontalScrollTests {
        static let width: CGFloat = 280

        static func file(_ name: String, depth: Int = 1, change: ChangeKind? = nil, oldPath: String? = nil) -> TreeRow {
            TreeRow(
                id: "0|f|\(depth)|\(name)", kind: .file, depth: depth, name: name, path: name, repoIndex: change == nil ? -1 : 0,
                change: change.map { FileChange(path: name, oldPath: oldPath, kind: $0, isUntracked: $0 == .added) })
        }

        static func dir(_ name: String, depth: Int = 1, mark: ChangeKind? = nil) -> TreeRow {
            TreeRow(id: "0|d|\(depth)|\(name)", kind: .directory, depth: depth, name: name, path: name, repoIndex: 0, dirMark: mark)
        }

        static func repo(_ name: String, branch: String? = "main") -> TreeRow {
            TreeRow(id: "0|r|\(name)", kind: .repo, depth: 0, name: name, path: "", repoIndex: 0, isExpanded: true, branch: branch)
        }

        static func tree(_ rows: [TreeRow], style: TreeView.Style = .files, height: CGFloat = 300) -> TreeView {
            let tree = TreeView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            tree.style = style
            tree.setRows(rows)
            tree.layoutSubtreeIfNeeded()
            return tree
        }

        static func hosted(_ rows: [TreeRow], style: TreeView.Style = .files) -> (TreeView, NSWindow) {
            let tree = TreeView(frame: .zero)
            tree.style = style
            let window = hostInWindow(tree, width: width, height: 300)
            tree.setRows(rows)
            tree.layoutSubtreeIfNeeded()
            return (tree, window)
        }

        static func range(_ tree: TreeView) -> CGFloat {
            max(0, (tree.scrollView.documentView?.frame.width ?? 0) - tree.visibleContentRect.width)
        }

        static func x(_ tree: TreeView) -> CGFloat { tree.visibleContentRect.origin.x }

        private static let pad = Theme.treePadding
        private func textX(depth: Int) -> CGFloat { Self.pad + CGFloat(depth) * Theme.treeIndent + Theme.iconSize + 6 }
        private let letterWidth = TextCache.shared.line("0", .small, .dim).width

        // MARK: content width

        @Test func everythingThatFitsHasNoRange() {
            let tree = Self.tree([Self.dir("src"), Self.file("main.swift", depth: 2), Self.file("README.md")])
            #expect(Self.range(tree) == 0)
            tree.scroll(to: CGPoint(x: 50, y: 0))
            #expect(Self.x(tree) == 0)
        }

        @Test func aDeepRowSetsTheWidth() {
            let tree = Self.tree([Self.file("a.txt", depth: 12), Self.file("b.txt")])
            let expected = textX(depth: 12) + 5 * Theme.charWidth + Theme.treePadding
            #expect(abs(tree.contentWidth - expected) < 0.01)
            #expect(Self.range(tree) > 0)
            #expect(abs(Self.range(tree) - (expected - Self.width)) < 0.01)
        }

        @Test func aLongNameSetsTheWidth() {
            let name = String(repeating: "n", count: 60) + ".txt"
            let tree = Self.tree([Self.file(name), Self.file("short")])
            let expected = textX(depth: 1) + 64 * Theme.charWidth + Theme.treePadding
            #expect(abs(tree.contentWidth - expected) < 0.01)
        }

        @Test func aFolderNameCountsToo() {
            let name = String(repeating: "d", count: 30) + "/" + String(repeating: "e", count: 30)
            let tree = Self.tree([Self.dir(name)])
            #expect(abs(tree.contentWidth - (textX(depth: 1) + 61 * Theme.charWidth + Theme.treePadding)) < 0.01)
        }

        @Test func aMarkerAddsItsRoom() {
            let name = String(repeating: "m", count: 40)
            let plain = Self.tree([Self.file(name)]).contentWidth
            let letter = Self.tree([Self.file(name, change: .modified)]).contentWidth
            #expect(letter > plain)
            #expect(abs(letter - plain - (14 + letterWidth)) < 0.01)
            let dot = Self.tree([Self.dir(name, mark: .added)], style: .files).contentWidth
            #expect(abs(dot - plain - (14 + 7)) < 0.01)
            // No dots in the changes tab.
            let none = Self.tree([Self.dir(name, mark: .added)], style: .changes).contentWidth
            #expect(abs(none - plain) < 0.01)
        }

        @Test func aNestedRepoFolderReservesALetterLikeASubmodule() {
            let nested = TreeRow(
                id: "0|d|n", kind: .directory, depth: 1, name: "vendored", path: "vendored", repoIndex: 0, dirMark: .modified,
                isNestedRepo: true)
            #expect(abs(Self.tree([nested]).contentWidth - Self.tree([Self.dir("vendored")]).contentWidth - (14 + letterWidth)) < 0.01)
            #expect(TreeView.markerWidth(of: nested, tab: .files) == letterWidth)
            #expect(TreeView.markerWidth(of: nested, tab: .changes) == 0)
        }

        /// The width reserved for a marker must agree with the marker the style really draws.
        @Test func markerRoomAgreesWithTheRowStyle() {
            let rows = [
                Self.file("a", change: .modified), Self.file("a", change: .added), Self.file("a", change: .deleted),
                Self.file("a", change: .renamed), Self.file("a"), Self.dir("d"), Self.dir("d", mark: .added),
                TreeRow(id: "s", kind: .directory, depth: 1, name: "s", path: "s", repoIndex: 0, isSubmodule: true, dirMark: .modified),
                TreeRow(id: "n", kind: .directory, depth: 1, name: "n", path: "n", repoIndex: 0, dirMark: .added, isNestedRepo: true),
                Self.repo("r"),
            ]
            for tab in [TreeView.Style.changes, .files] {
                for row in rows {
                    let width: CGFloat
                    switch TreeRowStyle(row: row, tab: tab, isSelected: false).marker {
                    case .none: width = 0
                    case .dot: width = 7
                    case let .letter(text, _): width = CGFloat(text.count) * letterWidth
                    }
                    #expect(TreeView.markerWidth(of: row, tab: tab) == width, "\(row.name) \(tab)")
                }
            }
        }

        @Test func aNameWithOtherCharactersIsMeasured() {
            let name = "日本語のファイル名.txt"
            let tree = Self.tree([Self.file(name)])
            let measured = TextCache.makeLine([TextRun(name, .fg)], .regular).width
            #expect(abs(tree.contentWidth - (textX(depth: 1) + measured + Theme.treePadding)) < 0.01)
        }

        @Test func aRenamedRowCountsItsOldName() {
            let tree = Self.tree([Self.file("new_name.txt", change: .renamed, oldPath: "dir/old_name_is_long.txt")])
            let text = "old_name_is_long.txt → new_name.txt"
            let measured = TextCache.makeLine([TextRun(text, .fg)], .regular).width
            #expect(abs(tree.contentWidth - (textX(depth: 1) + measured + 14 + letterWidth + Theme.treePadding)) < 0.01)
        }

        @Test func repositoryRowsDoNotCount() {
            let tree = Self.tree([Self.repo(String(repeating: "r", count: 200)), Self.file("a.txt")])
            #expect(Self.range(tree) == 0)
            #expect(tree.contentWidth < Self.width)
            let onlyRepo = Self.tree([Self.repo(String(repeating: "r", count: 200))])
            #expect(onlyRepo.contentWidth == 0)
        }

        @Test func theWidthFollowsTheTabStyle() {
            let name = String(repeating: "m", count: 30)
            let rows = [Self.dir(name, mark: .modified)]
            let tree = Self.tree(rows, style: .changes)
            let before = tree.contentWidth
            tree.style = .files
            #expect(tree.contentWidth > before)
        }

        @Test func aWiderSidebarRemovesTheRange() {
            let tree = Self.tree([Self.file(String(repeating: "x", count: 50))])
            #expect(Self.range(tree) > 0)
            tree.frame.size.width = 700
            tree.layoutSubtreeIfNeeded()
            #expect(Self.range(tree) == 0)
        }

        // MARK: position

        private let wide = [Self.file(String(repeating: "w", count: 70)), Self.file("short")]

        @Test func thePositionSurvivesARefresh() {
            let tree = Self.tree(wide)
            tree.scroll(to: CGPoint(x: 60, y: 0))
            #expect(Self.x(tree) == 60)
            tree.setRows(wide + [Self.file("one more")])
            #expect(Self.x(tree) == 60)
            tree.setRows(wide)
            #expect(Self.x(tree) == 60)
        }

        @Test func thePositionIsClampedWhenTheContentGetsNarrower() {
            let tree = Self.tree(wide)
            tree.scroll(to: CGPoint(x: 1000, y: 0))
            let end = Self.x(tree)
            #expect(end == Self.range(tree))
            tree.setRows([Self.file(String(repeating: "w", count: 50))])
            #expect(Self.x(tree) == Self.range(tree))
            #expect(Self.x(tree) < end)
            #expect(Self.x(tree) > 0)
        }

        @Test func thePositionGoesBackToZeroWhenEverythingFits() {
            let tree = Self.tree(wide)
            tree.scroll(to: CGPoint(x: 40, y: 0))
            tree.setRows([Self.file("a")])
            #expect(Self.x(tree) == 0)
            #expect(Self.range(tree) == 0)
        }

        @Test func switchingTheStyleClampsToo() {
            let rows = [Self.dir(String(repeating: "m", count: 30), mark: .modified)]
            let tree = Self.tree(rows, style: .files)
            tree.scroll(to: CGPoint(x: 1000, y: 0))
            let end = Self.x(tree)
            tree.style = .changes
            #expect(Self.x(tree) <= Self.range(tree))
            #expect(Self.x(tree) <= end)
        }

        @Test func revealingARowOnlyMovesVertically() {
            let rows = (0..<60).map { Self.file("file\($0)" + String(repeating: "z", count: $0 == 40 ? 70 : 1)) }
            let tree = Self.tree(rows)
            tree.scroll(to: CGPoint(x: 30, y: 0))
            tree.scrollRowToVisible(id: rows[50].id)
            #expect(tree.visibleContentRect.origin.y > 0)
            #expect(Self.x(tree) == 30)
            tree.scrollRowToVisible(id: rows[0].id)
            #expect(tree.visibleContentRect.origin.y == 0)
            #expect(Self.x(tree) == 30)
        }

        @Test func arrowKeysOnlyMoveVertically() {
            let rows = (0..<60).map { Self.file("file\($0)" + String(repeating: "z", count: $0 == 40 ? 70 : 1)) }
            let tree = Self.tree(rows)
            tree.selectedID = rows[0].id
            tree.scroll(to: CGPoint(x: 30, y: 0))
            for _ in 0..<30 { tree.keyDown(with: Event.key(125)) }
            #expect(tree.selectedID == rows[30].id)
            #expect(tree.visibleContentRect.origin.y > 0)
            #expect(Self.x(tree) == 30)
            for _ in 0..<30 { tree.keyDown(with: Event.key(126)) }
            #expect(Self.x(tree) == 30)
        }

        // MARK: input

        private func scrollEvent(dx: Int32 = 0, dy: Int32 = 0, shift: Bool = false) throws -> NSEvent {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
            if shift { cg.flags.insert(.maskShift) }
            return try #require(NSEvent(cgEvent: cg))
        }

        @Test func aHorizontalSwipeScrollsSideways() throws {
            let (tree, _) = Self.hosted(wide)
            tree.scrollView.scrollWheel(with: try scrollEvent(dx: -40))
            let moved = Self.x(tree)
            #expect(moved > 0)
            tree.scrollView.scrollWheel(with: try scrollEvent(dx: 15))
            #expect(Self.x(tree) < moved)
        }

        @Test func aMostlyVerticalScrollDoesNotDriftSideways() throws {
            let rows = (0..<60).map { Self.file("file\($0)" + String(repeating: "z", count: $0 == 5 ? 70 : 1)) }
            let (tree, _) = Self.hosted(rows)
            tree.scrollView.scrollWheel(with: try scrollEvent(dx: -4, dy: -40))
            #expect(Self.x(tree) == 0)
        }

        @Test func shiftWithTheVerticalWheelScrollsSideways() throws {
            let (tree, _) = Self.hosted(wide)
            tree.scrollView.scrollWheel(with: try scrollEvent(dy: -40, shift: true))
            #expect(Self.x(tree) > 0)
            #expect(tree.visibleContentRect.origin.y == 0)
        }

        @Test func shiftWheelDoesNothingWithoutARange() throws {
            let rows = (0..<60).map { Self.file("f\($0)") }
            let (tree, _) = Self.hosted(rows)
            tree.scrollView.scrollWheel(with: try scrollEvent(dy: -40, shift: true))
            #expect(Self.x(tree) == 0)
        }

        @Test func aHorizontalSwipeWithoutARangeDoesNothing() throws {
            let (tree, _) = Self.hosted([Self.file("a")])
            tree.scrollView.scrollWheel(with: try scrollEvent(dx: -40))
            #expect(Self.x(tree) == 0)
        }

        @Test func theHorizontalScrollerIsAThinOverlayThatHidesItself() {
            let tree = Self.tree(wide)
            let scroll = tree.scrollView
            #expect(scroll.hasHorizontalScroller)
            #expect(scroll.scrollerStyle == .overlay)
            #expect(scroll.autohidesScrollers)
            #expect(scroll.hasVerticalScroller)
        }

        // MARK: pointer

        @Test func aClickWhileScrolledSidewaysSelectsTheRowUnderThePointer() throws {
            let (tree, window) = Self.hosted(wide + [Self.file("third")])
            tree.scroll(to: CGPoint(x: 80, y: 0))
            var opened: [String] = []
            tree.onOpen = { row, _ in opened.append(row.name) }
            // Second row: y from 32 to 56.
            let spot = point(120, 44)
            let canvas = try #require(window.topmostView(atWindowPoint: tree.convert(spot, to: nil)))
            canvas.mouseDown(with: makeMouseDown(in: tree, at: spot, window: window))
            #expect(opened == ["short"])
            #expect(tree.selectedID == wide[1].id)
        }

        @Test func hoverWhileScrolledSidewaysHitsTheRightRow() throws {
            let (tree, _) = Self.hosted(wide + [Self.file("third")])
            tree.scroll(to: CGPoint(x: 80, y: 0))
            // The point is in content coordinates, 80 to the right of the view point.
            tree.mouse(.moved, at: CGPoint(x: 80 + 100, y: 8 + 24 * 2 + 5), event: Event.mouse(.mouseMoved))
            let bitmap = Render.canvas(tree)
            let hover = RGB.composite(Theme.rowHover, over: Theme.background)
            #expect(bitmap.rgb(2, 8 + 24 * 2 + 12).isClose(to: hover))
            #expect(bitmap.rgb(Int(Self.width) - 2, 8 + 24 * 2 + 12).isClose(to: hover))
            #expect(bitmap.rgb(Int(Self.width) - 2, 8 + 24 + 12).isClose(to: RGB(Theme.background)))
        }

        // MARK: sidebar tabs

        @Test func eachSidebarTabKeepsItsOwnHorizontalPosition() throws {
            let repo = TestRepo()
            let deep = (0..<9).map { "d\($0)" }.joined(separator: "/")
            repo.write("\(deep)/\(String(repeating: "files-tab-long-", count: 4)).txt", "x\n")
            repo.write("keep.txt", "x\n")
            repo.commitAll("base")
            repo.write("short.txt", "new\n")
            repo.write("\(String(repeating: "changes-tab-name-", count: 5)).txt", "new\n")
            _ = NSApplication.shared
            let controller = MainWindowController(path: repo.path)
            controller.workspace.scanNow()
            let root = try #require(controller.window.contentView as? RootView)
            root.frame = NSRect(x: 0, y: 0, width: 1180, height: 400)
            root.layoutSubtreeIfNeeded()

            let tree = root.tree
            tree.layoutSubtreeIfNeeded()
            #expect(Self.range(tree) > 0)
            tree.scroll(to: CGPoint(x: 25, y: 0))
            let changesX = Self.x(tree)
            #expect(changesX == 25)

            controller.showFiles(nil)
            tree.layoutSubtreeIfNeeded()
            // Another tab that was never scrolled starts at the left.
            #expect(Self.x(tree) == 0)
            for _ in 0..<12 {
                guard let closed = controller.workspace.sidebarRows().first(where: { $0.kind == .directory && !$0.isExpanded }) else { break }
                controller.workspace.toggle(closed)
            }
            tree.layoutSubtreeIfNeeded()
            tree.scroll(to: CGPoint(x: 70, y: 0))
            #expect(Self.x(tree) == 70)

            controller.showChanges(nil)
            #expect(Self.x(tree) == changesX)
            controller.showFiles(nil)
            #expect(Self.x(tree) == 70)
        }
    }
}
