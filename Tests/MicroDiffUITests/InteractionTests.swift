import MicroDiffCore
import MicroDiffTestSupport
import Testing

@testable import MicroDiffUI

/// Clicks land on the right thing: these check the hit-testing math of the hand-drawn views.
@MainActor
@Suite("Interaction")
struct InteractionTests {
    // Changes-style layout: 8 pt top padding, repo band 28 pt, then 24 pt rows.
    private let rows = [
        TreeRow(id: "0|r|", kind: .repo, depth: 0, name: "repo", path: "", repoIndex: 0, isExpanded: true, branch: "main"),
        TreeRow(id: "0|d|src", kind: .directory, depth: 1, name: "src", path: "src", repoIndex: 0, isExpanded: true),
        TreeRow(id: "0|f|src/a.rs", kind: .file, depth: 2, name: "a.rs", path: "src/a.rs", repoIndex: 0,
                change: FileChange(path: "src/a.rs", kind: .modified)),
        TreeRow(id: "0|f|src/b.rs", kind: .file, depth: 2, name: "b.rs", path: "src/b.rs", repoIndex: 0,
                change: FileChange(path: "src/b.rs", kind: .added)),
    ]

    @Test("a click on a file row opens it as a preview; a double click keeps it")
    func treeFileClick() {
        let tree = makeTreeView()
        tree.setRows(rows)
        var opened: [(String, Bool)] = []
        tree.onOpen = { row, pin in opened.append((row.id, pin)) }

        // Rows start at y = 8 (band), 36, 60, 84.
        tree.mouse(.down, at: point(100, 70), event: makeMouseDown())
        tree.mouse(.down, at: point(100, 95), event: makeMouseDown(clickCount: 2))

        #expect(opened.map(\.0) == ["0|f|src/a.rs", "0|f|src/b.rs"])
        #expect(opened.map(\.1) == [false, true])
        #expect(tree.selectedID == "0|f|src/b.rs")
    }

    @Test("a click on a repo or folder row toggles it and opens nothing")
    func treeFolderClick() {
        let tree = makeTreeView()
        tree.setRows(rows)
        var toggled: [String] = []
        var opened = 0
        tree.onToggle = { toggled.append($0.id) }
        tree.onOpen = { _, _ in opened += 1 }

        tree.mouse(.down, at: point(100, 20), event: makeMouseDown())
        tree.mouse(.down, at: point(100, 45), event: makeMouseDown())

        #expect(toggled == ["0|r|", "0|d|src"])
        #expect(opened == 0)
    }

    @Test("clicks in the padding above the rows and in the empty space below do nothing")
    func treeEmptySpaceClick() {
        let tree = makeTreeView()
        tree.setRows(rows)
        var calls = 0
        tree.onToggle = { _ in calls += 1 }
        tree.onOpen = { _, _ in calls += 1 }

        tree.mouse(.down, at: point(100, 3), event: makeMouseDown())
        tree.mouse(.down, at: point(100, 300), event: makeMouseDown())

        #expect(calls == 0)
    }

    @Test("the gap between two repo sections is not clickable")
    func treeGapBetweenRepos() {
        let tree = makeTreeView()
        var second = rows[0]
        second.id = "1|r|"
        second.repoIndex = 1
        second.gapBefore = true
        tree.setRows([rows[0], second])
        var toggled: [String] = []
        tree.onToggle = { toggled.append($0.id) }

        // First band is 8...36, then a 10 pt gap, second band is 46...74.
        tree.mouse(.down, at: point(50, 40), event: makeMouseDown())
        #expect(toggled.isEmpty)
        tree.mouse(.down, at: point(50, 50), event: makeMouseDown())
        #expect(toggled == ["1|r|"])
    }

    @Test("rows sit at the same height in both sidebar tabs, so nothing jumps when switching")
    func sameRowPositionsInBothStyles() {
        var openedPerStyle: [[String]] = []
        for style in [TreeView.Style.changes, .files] {
            let tree = makeTreeView()
            tree.style = style
            tree.setRows(rows)
            var opened: [String] = []
            tree.onOpen = { row, _ in opened.append(row.id) }
            // Root row 8...36, then 24 pt rows: 36, 60, 84.
            for y in [37.0, 59.0, 61.0, 83.0, 85.0, 107.0] {
                tree.mouse(.down, at: point(100, y), event: makeMouseDown())
            }
            openedPerStyle.append(opened)
        }
        #expect(openedPerStyle[0] == ["0|f|src/a.rs", "0|f|src/a.rs", "0|f|src/b.rs", "0|f|src/b.rs"])
        #expect(openedPerStyle[1] == openedPerStyle[0])
    }

    @Test("a click on a fold row asks to expand that fold")
    func foldClick() throws {
        let repo = TestRepo()
        let lines = (1...60).map { "line \($0)" }
        repo.write("a.txt", lines.joined(separator: "\n") + "\n")
        repo.commitAll("first")
        var edited = lines
        edited[29] = "changed"
        repo.write("a.txt", edited.joined(separator: "\n") + "\n")

        let snapshot = RepoScanner().scan(root: repo.path)
        let change = try #require(snapshot.repos.first?.changes.first)
        let content = DocumentLoader().load(DocumentRequest(path: repo.path + "/a.txt", repo: snapshot.repos[0], change: change))
        guard case let .text(document) = content else {
            Issue.record("expected a text document")
            return
        }
        #expect(document.rows.row(at: 0).kind == .fold)

        let view = makeCodeView()
        view.setDocument(document, keepScroll: false)
        var expanded: [Int] = []
        view.onExpandFold = { expanded.append($0) }

        // The first fold (lines 1...26) sits flush at the top, 28 pt tall.
        view.mouse(.down, at: point(200, 10), event: makeMouseDown())
        #expect(expanded == [0])

        // A click on a normal line expands nothing.
        view.mouse(.down, at: point(200, 40), event: makeMouseDown())
        #expect(expanded == [0])
    }

    @Test("clicking a tab selects it, the close button closes it, a double click keeps it")
    func tabBarClicks() {
        let bar = FileTabBarView(frame: .zero)
        let window = hostInWindow(bar, width: 900, height: 37)
        bar.update(
            tabs: [FileTab(title: "a.rs", kind: .modified, isPreview: false), FileTab(title: "b.rs", kind: nil, isPreview: true),
                   FileTab(title: "c.rs", kind: nil, isPreview: false)],
            activeIndex: 0, mode: .diff)
        bar.display()

        var selected: [Int] = []
        var pinned: [Int] = []
        var closed: [Int] = []
        bar.onSelect = { selected.append($0) }
        bar.onPin = { pinned.append($0) }
        bar.onClose = { closed.append($0) }

        // Three tabs of 150 pt each.
        bar.mouseDown(with: makeMouseDown(in: bar, at: point(225, 18), window: window))
        bar.mouseDown(with: makeMouseDown(in: bar, at: point(375, 18), clickCount: 2, window: window))
        #expect(selected == [1])
        #expect(pinned == [2])

        // The active tab's content "a.rs M x" is centered in 0...150; the close button is its last 12 pt.
        var closeX: Double?
        for x in stride(from: 80.0, through: 140.0, by: 2.0) where closed.isEmpty {
            selected.removeAll()
            bar.mouseDown(with: makeMouseDown(in: bar, at: point(x, 18), window: window))
            if !closed.isEmpty { closeX = x }
        }
        #expect(closed == [0])
        #expect(closeX != nil)
    }

    @Test("the close box sits at the tab's right edge and lights up under the pointer")
    func closeBoxHover() {
        let bar = FileTabBarView(frame: .zero)
        let window = hostInWindow(bar, width: 900, height: 37)
        bar.update(
            tabs: [FileTab(title: "a.rs", kind: .modified, isPreview: false), FileTab(title: "b.rs", kind: nil, isPreview: false)],
            activeIndex: 0, mode: .diff)

        // Tabs are 150 pt wide; the box is 18 pt, 8 pt from the right edge, centered in the 36 pt bar.
        let activeBox = PixelRegion(x: 124, y: 9, width: 18, height: 18)
        let otherBox = PixelRegion(x: 274, y: 9, width: 18, height: 18)
        let lit = RGB.composite(Theme.closeHover, over: Theme.background)
        let litOnInactive = RGB.composite(Theme.closeHover, over: Theme.inactive)

        // Resting: the open tab shows its x (some pixels), no box; the other tab shows nothing there.
        var picture = Render.tabBar(bar)
        #expect(picture.count(notNear: RGB(Theme.background), in: activeBox) > 4)
        #expect(picture.count(near: lit, in: activeBox) == 0)
        #expect(picture.isUniform(RGB(Theme.inactive), in: otherBox))

        // Pointer on the other tab, away from its box: the x appears, still no box.
        bar.mouseMoved(with: makeMouseMoved(in: bar, at: point(200, 18), window: window))
        picture = Render.tabBar(bar)
        #expect(picture.count(notNear: RGB(Theme.inactive), in: otherBox) > 4)
        #expect(picture.count(near: litOnInactive, in: otherBox) < 40)

        // Pointer on that box: it gets a background.
        bar.mouseMoved(with: makeMouseMoved(in: bar, at: point(283, 18), window: window))
        picture = Render.tabBar(bar)
        #expect(picture.count(near: litOnInactive, in: otherBox) > 150)

        // Pointer on the open tab's box.
        bar.mouseMoved(with: makeMouseMoved(in: bar, at: point(133, 18), window: window))
        picture = Render.tabBar(bar)
        #expect(picture.count(near: lit, in: activeBox) > 150)
        #expect(picture.isUniform(RGB(Theme.inactive), in: otherBox))
    }

    @Test("the diff / read / edit switch reports the mode that was clicked")
    func modeSwitch() {
        let bar = FileTabBarView(frame: .zero)
        let window = hostInWindow(bar, width: 900, height: 37)
        bar.update(tabs: [FileTab(title: "a.rs", kind: .modified, isPreview: false)], activeIndex: 0, mode: .diff)
        bar.display()

        var modes: [ViewMode] = []
        bar.onMode = { modes.append($0) }

        // The switch is right-aligned with 16 pt padding: "diff", two characters of space, "read", two more, "edit".
        let editX = 900 - 16 - Theme.charWidth * 2
        let readX = editX - Theme.charWidth * 6
        let diffX = readX - Theme.charWidth * 6
        bar.mouseDown(with: makeMouseDown(in: bar, at: point(readX, 18), window: window))
        bar.mouseDown(with: makeMouseDown(in: bar, at: point(diffX, 18), window: window))
        bar.mouseDown(with: makeMouseDown(in: bar, at: point(editX, 18), window: window))
        #expect(modes == [.read, .diff, .edit])
    }

    @Test("with no tabs the bar ignores clicks")
    func emptyBarIgnoresClicks() {
        let bar = FileTabBarView(frame: .zero)
        let window = hostInWindow(bar, width: 900, height: 37)
        bar.update(tabs: [], activeIndex: nil, mode: .diff)
        var calls = 0
        bar.onSelect = { _ in calls += 1 }
        bar.onMode = { _ in calls += 1 }
        bar.onClose = { _ in calls += 1 }

        for x in stride(from: 10.0, to: 900.0, by: 60.0) {
            bar.mouseDown(with: makeMouseDown(in: bar, at: point(x, 18), window: window))
        }
        #expect(calls == 0)
    }

    // MARK: Cursors

    @Test("tree rows show a pointing hand; padding, gaps and empty space show the arrow")
    func treeCursor() {
        let tree = makeTreeView()
        var second = rows[0]
        second.id = "1|r|"
        second.gapBefore = true
        tree.setRows(rows + [second])
        // Rows: 8...36 root, 36, 60, 84 (to 108), a 10 pt gap, second root 118...146.
        #expect(kind(tree.cursor(at: point(50, 3))) == .arrow)
        #expect(kind(tree.cursor(at: point(50, 20))) == .hand)
        #expect(kind(tree.cursor(at: point(50, 45))) == .hand)
        #expect(kind(tree.cursor(at: point(50, 90))) == .hand)
        #expect(kind(tree.cursor(at: point(50, 112))) == .arrow)
        #expect(kind(tree.cursor(at: point(50, 130))) == .hand)
        #expect(kind(tree.cursor(at: point(50, 300))) == .arrow)
    }

    @Test("in the code view fold rows are clickable, code is text, the gutter and empty space are plain")
    func codeCursor() throws {
        let repo = TestRepo()
        let lines = (1...60).map { "line \($0)" }
        repo.write("a.txt", lines.joined(separator: "\n") + "\n")
        repo.commitAll("first")
        var edited = lines
        edited[29] = "changed"
        repo.write("a.txt", edited.joined(separator: "\n") + "\n")
        let snapshot = RepoScanner().scan(root: repo.path)
        let change = try #require(snapshot.repos.first?.changes.first)
        guard case let .text(document) = DocumentLoader().load(
            DocumentRequest(path: repo.path + "/a.txt", repo: snapshot.repos[0], change: change))
        else {
            Issue.record("expected a text document")
            return
        }

        let view = makeCodeView()
        #expect(kind(view.cursor(at: point(200, 40))) == .arrow, "nothing shown yet")

        view.setDocument(document, keepScroll: false)
        // Fold band at 0...28, then 22 pt lines.
        #expect(kind(view.cursor(at: point(200, 10))) == .hand)
        #expect(kind(view.cursor(at: point(20, 10))) == .hand, "the whole fold row is clickable")
        #expect(kind(view.cursor(at: point(200, 40))) == .text)
        #expect(kind(view.cursor(at: point(20, 40))) == .arrow, "line numbers")
        #expect(kind(view.cursor(at: point(200, 480))) == .arrow, "below the last row")
    }

    @Test("in the tab bar everything clickable shows a pointing hand, the empty strip does not")
    func tabBarCursor() {
        let bar = FileTabBarView(frame: .zero)
        _ = hostInWindow(bar, width: 900, height: 37)
        bar.update(
            tabs: [FileTab(title: "a.rs", kind: .modified, isPreview: false), FileTab(title: "b.rs", kind: nil, isPreview: false)],
            activeIndex: 0, mode: .diff)

        let editX = 900 - 16 - Theme.charWidth * 2
        let readX = editX - Theme.charWidth * 6
        let diffX = readX - Theme.charWidth * 6
        #expect(kind(bar.cursor(at: point(60, 18))) == .hand)
        #expect(kind(bar.cursor(at: point(133, 18))) == .hand, "close box")
        #expect(kind(bar.cursor(at: point(220, 18))) == .hand)
        #expect(kind(bar.cursor(at: point(500, 18))) == .arrow, "empty strip")
        #expect(kind(bar.cursor(at: point(readX, 18))) == .hand)
        #expect(kind(bar.cursor(at: point(diffX, 18))) == .hand)
        #expect(kind(bar.cursor(at: point(editX, 18))) == .hand)

        bar.update(tabs: [], activeIndex: nil, mode: .diff)
        for x in stride(from: 10.0, to: 900.0, by: 80.0) {
            #expect(kind(bar.cursor(at: point(x, 18))) == .arrow)
        }
    }

    @Test("the title bar double-click setting maps to the right action", arguments: [
        ("Maximize", TitleBarDoubleClick.zoom), ("Fill", .zoom), ("Minimize", .minimize), ("None", .nothing),
    ])
    func titleBarSetting(value: String, expected: TitleBarDoubleClick) {
        #expect(TitleBarDoubleClick(setting: value) == expected)
    }

    @Test("without a setting a double click on the title bar zooms, like the system default")
    func titleBarDefault() {
        #expect(TitleBarDoubleClick(setting: nil) == .zoom)
    }

    @Test("a double click on the title strip zooms the window; one lower down does not")
    func titleStripDoubleClickZooms() {
        let window = makeAppWindow()
        let root = window.contentView!
        let small = window.frame

        // Below the title strip (in the tab bar): nothing happens to the window.
        root.mouseDown(with: makeMouseDown(in: root, at: point(600, 60), clickCount: 2, window: window))
        #expect(window.frame == small)

        root.mouseDown(with: makeMouseDown(in: root, at: point(600, 12), clickCount: 2, window: window))
        // The action follows this Mac's setting; when it is "zoom" (the default) the window must have grown.
        if TitleBarDoubleClick.systemSetting == .zoom {
            #expect(window.frame.width > small.width)
            // A second double click goes back to the size before.
            root.mouseDown(with: makeMouseDown(in: root, at: point(600, 12), clickCount: 2, window: window))
            #expect(window.frame.size == small.size)
        }
    }

    @Test("the title strip is hit by clicks next to the window buttons, so it can act as a title bar")
    func titleStripReceivesClicks() {
        let window = makeAppWindow()
        let frameView = window.contentView!.superview!
        let hit = frameView.hitTest(point(300, Double(frameView.bounds.height) - 10))
        #expect(hit === window.contentView)
    }

    @Test("the sidebar tabs split the width in two")
    func sidebarTabs() {
        let tabs = SidebarTabsView(frame: .zero)
        let window = hostInWindow(tabs, width: 288, height: 37)
        var picked: [SidebarTab] = []
        tabs.onSelect = { picked.append($0) }

        tabs.mouseDown(with: makeMouseDown(in: tabs, at: point(200, 18), window: window))
        tabs.mouseDown(with: makeMouseDown(in: tabs, at: point(40, 18), window: window))
        #expect(picked == [.files, .changes])
    }
}
