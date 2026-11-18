import AppKit
import MicroDiffCore
import MicroDiffTestSupport
import Testing
@testable import MicroDiffUI

extension UITests {
/// What edit mode adds to the look: the third word of the switch, the unsaved dot, the changed-on-disk strip,
/// and an editor whose text and line numbers sit exactly where the read view puts them.
@MainActor
@Suite
struct EditChromeTests {
    private let inactive = RGB(Theme.inactive)

    private func bar(
        _ tabs: [FileTab], active: Int? = 0, mode: ViewMode = .diff, canEdit: Bool = true, width: CGFloat = 800
    ) -> FileTabBarView {
        let view = FileTabBarView(frame: NSRect(x: 0, y: 0, width: width, height: Theme.tabBarHeight))
        view.update(tabs: tabs, activeIndex: active, mode: mode, canEdit: canEdit)
        return view
    }

    private func tab(_ title: String, unsaved: Bool = false) -> FileTab {
        FileTab(title: title, kind: nil, isPreview: false, isUnsaved: unsaved)
    }

    // MARK: The switch

    @Test func theSwitchIsThreeWordsWideAndTheStripGivesUpThatMuch() {
        #expect(abs(Theme.charWidth - 7.2) < 0.01, "the design assumes 7.2 pt characters")
        let picture = Render.tabBar(bar([tab("a.rs")]))
        // 16 + 28.8 + 14.4 + 28.8 + 14.4 + 28.8 + 16 = 147.2: the strip ends with a divider at 800 - 147.2 = 652.8.
        #expect(picture.count(near: RGB(Theme.line), in: PixelRegion(x: 653, y: 0, width: 1, height: 36), tolerance: 4) == 36)
        #expect(picture.isUniform(inactive, in: PixelRegion(x: 600, y: 0, width: 50, height: 36)))
        #expect(picture.isUniform(inactive, in: PixelRegion(x: 655, y: 0, width: 14, height: 36)), "16 pt padding before diff")
    }

    @Test func eachWordLightsUpForItsMode() {
        let words = [("diff", 669), ("read", 712), ("edit", 755)]
        for (index, mode) in [ViewMode.diff, .read, .edit].enumerated() {
            let picture = Render.tabBar(bar([tab("a.rs")], mode: mode))
            for (wordIndex, word) in words.enumerated() {
                let region = PixelRegion(x: word.1, y: 4, width: 28, height: 28)
                let lit = picture.count(near: RGB(Ink.fg.cg), in: region, tolerance: 25)
                if wordIndex == index { #expect(lit > 20, "\(word.0) lit in \(mode)") } else { #expect(lit == 0, "\(word.0) not lit in \(mode)") }
            }
        }
    }

    @Test func aFileThatCannotBeEditedDrawsEditInTheLineNumberColor() {
        let region = PixelRegion(x: 755, y: 4, width: 28, height: 28)
        let dimmed = Render.tabBar(bar([tab("a.bin")], mode: .read, canEdit: false))
        let normal = Render.tabBar(bar([tab("a.rs")], mode: .read))
        #expect(dimmed.count(near: RGB(Ink.lineNumber.cg), in: region, tolerance: 6) > 10)
        #expect(dimmed.count(near: RGB(Ink.dim.cg), in: region, tolerance: 6) == 0)
        #expect(normal.count(near: RGB(Ink.dim.cg), in: region, tolerance: 6) > 10)
    }

    @Test func aDimmedEditIgnoresClicksAndShowsNoHand() {
        let view = bar([tab("a.bin")], mode: .read, canEdit: false)
        let window = hostInWindow(view, width: 800, height: 37)
        var modes: [ViewMode] = []
        view.onMode = { modes.append($0) }
        let editX = 800 - 16 - Theme.charWidth * 2
        view.mouseDown(with: makeMouseDown(in: view, at: point(editX, 18), window: window))
        #expect(modes.isEmpty)
        #expect(kind(view.cursor(at: point(editX, 18))) == .arrow)
        #expect(kind(view.cursor(at: point(editX - Theme.charWidth * 6, 18))) == .hand, "file still reacts")

        view.update(tabs: [tab("a.rs")], activeIndex: 0, mode: .read, canEdit: true)
        view.mouseDown(with: makeMouseDown(in: view, at: point(editX, 18), window: window))
        #expect(modes == [.edit])
        #expect(kind(view.cursor(at: point(editX, 18))) == .hand)
    }

    // MARK: The unsaved dot

    /// The close box of tab `index` (150 pt tabs): 18 pt, 8 pt from the tab's right edge.
    private func box(_ index: Int) -> PixelRegion { PixelRegion(x: 150 * index + 124, y: 9, width: 18, height: 18) }
    /// The 8 pt dot in the middle of a box.
    private func dot(_ index: Int) -> PixelRegion { PixelRegion(x: 150 * index + 130, y: 15, width: 6, height: 6) }

    @Test func anUnsavedTabShowsADotInsteadOfTheX() {
        let picture = Render.tabBar(bar([tab("a.rs", unsaved: true), tab("b.rs", unsaved: true), tab("c.rs")]))
        #expect(picture.count(near: RGB(Ink.fg.cg), in: dot(0), tolerance: 6) >= 30, "the open tab's dot is bright")
        #expect(picture.count(near: RGB(Ink.dim.cg), in: dot(1), tolerance: 6) >= 30, "a background tab's dot is quiet")
        // The dot is round and small: the corners of the box stay empty.
        #expect(picture.isUniform(RGB(Theme.background), in: PixelRegion(x: 124, y: 9, width: 4, height: 4)))
        #expect(picture.isUniform(inactive, in: box(2)), "a clean background tab shows nothing")
        let clean = Render.tabBar(bar([tab("a.rs")]))
        #expect(clean.count(near: RGB(Ink.fg.cg), in: dot(0), tolerance: 6) < 10, "a clean open tab shows its x")
    }

    @Test func thePointerOverAnUnsavedTabBringsTheXBack() {
        let view = bar([tab("a.rs", unsaved: true), tab("b.rs", unsaved: true)])
        let window = hostInWindow(view, width: 800, height: 37)
        let resting = Render.tabBar(view)
        view.mouseMoved(with: makeMouseMoved(in: view, at: point(200, 18), window: window))
        let hovered = Render.tabBar(view)
        #expect(resting.count(near: RGB(Ink.dim.cg), in: dot(1), tolerance: 6) >= 30)
        #expect(hovered.count(near: RGB(Ink.dim.cg), in: dot(1), tolerance: 6) < 30)
        #expect(hovered.count(notNear: inactive, in: box(1)) > 4, "the x")
        #expect(hovered.count(near: RGB(Ink.fg.cg), in: dot(0), tolerance: 6) >= 30, "the open tab keeps its dot")

        var closed: [Int] = []
        view.onClose = { closed.append($0) }
        view.mouseDown(with: makeMouseDown(in: view, at: point(283, 18), window: window))
        #expect(closed == [1], "the x under the pointer closes the tab, as before")
    }

    @Test func theDotKeepsEverythingElseInPlace() {
        let saved = Render.tabBar(bar([tab("a.rs"), tab("b.rs")]))
        let unsaved = Render.tabBar(bar([tab("a.rs", unsaved: true), tab("b.rs", unsaved: true)]))
        let titles = PixelRegion(x: 0, y: 0, width: 120, height: 36)
        #expect(saved.count(notNear: RGB(Theme.background), in: titles) == unsaved.count(notNear: RGB(Theme.background), in: titles))
    }

    // MARK: The changed-on-disk strip

    private func strip(_ conflict: DiskConflict, width: CGFloat = 800) -> (DiskChangeStrip, Bitmap) {
        let view = DiskChangeStrip(frame: NSRect(x: 0, y: 0, width: width, height: Theme.foldHeight))
        view.conflict = conflict
        let picture = Bitmap.render(width: Int(width), height: Int(Theme.foldHeight)) { ctx in
            let saved = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            view.draw(view.bounds)
            NSGraphicsContext.current = saved
        }
        return (view, picture)
    }

    @Test func theStripHasABandAYellowBarAQuietMessageAndTwoBrightWords() throws {
        let (view, picture) = strip(.changed)
        let band = RGB.composite(Theme.band, over: Theme.background)
        #expect(picture.isUniform(RGB(Ink.yellow.cg), in: PixelRegion(x: 0, y: 0, width: 2, height: 28)))
        #expect(picture.isUniform(band, in: PixelRegion(x: 2, y: 0, width: 60, height: 28)), "nothing before x = 66")
        #expect(picture.count(near: RGB(Ink.dim.cg), in: PixelRegion(x: 66, y: 4, width: 200, height: 20), tolerance: 20) > 20)
        // "keep mine" ends 16 pt from the right edge; "reload" sits 14.4 pt before it.
        let keepMine = view.keepMineRect
        #expect(abs(keepMine.maxX - 784) < 0.01 && abs(keepMine.width - 9 * 7.2) < 0.01)
        let reload = try #require(view.reloadRect)
        #expect(abs(keepMine.minX - reload.maxX - 14.4) < 0.01 && abs(reload.width - 6 * 7.2) < 0.01)
        #expect(picture.count(near: RGB(Ink.fg.cg), in: PixelRegion(x: Int(reload.minX), y: 4, width: Int(reload.width), height: 20), tolerance: 20) > 10)
        #expect(picture.count(near: RGB(Ink.fg.cg), in: PixelRegion(x: Int(keepMine.minX), y: 4, width: Int(keepMine.width), height: 20), tolerance: 20) > 10)
        #expect(view.message == "this file changed on disk")
    }

    @Test func theDeletedStripOffersOnlyKeepMine() {
        let (view, picture) = strip(.deleted)
        #expect(view.reloadRect == nil)
        #expect(view.message == "this file was deleted on disk")
        let beforeKeepMine = PixelRegion(x: Int(view.keepMineRect.minX) - 60, y: 4, width: 55, height: 20)
        #expect(picture.isUniform(RGB.composite(Theme.band, over: Theme.background), in: beforeKeepMine))
    }

    @Test func theStripWordsReactToClicksAndShowAHand() {
        let (view, _) = strip(.changed)
        let window = hostInWindow(view, width: 800, height: Theme.foldHeight)
        var calls: [String] = []
        view.onReload = { calls.append("reload") }
        view.onKeepMine = { calls.append("keep") }
        let reload = view.reloadRect!, keepMine = view.keepMineRect
        for x in [reload.midX, keepMine.midX, 300, keepMine.maxX + 10] {
            view.mouseDown(with: makeMouseDown(in: view, at: point(x, 14), window: window))
        }
        #expect(calls == ["reload", "keep"])
        #expect(kind(view.cursor(at: point(reload.midX, 14))) == .hand)
        #expect(kind(view.cursor(at: point(keepMine.midX, 14))) == .hand)
        #expect(kind(view.cursor(at: point(300, 14))) == .arrow)

        view.conflict = .deleted
        view.mouseDown(with: makeMouseDown(in: view, at: point(reload.midX, 14), window: window))
        #expect(calls == ["reload", "keep"])
        #expect(kind(view.cursor(at: point(reload.midX, 14))) == .arrow)
    }

    // MARK: The editor against the read view

    private func render(_ repo: TestRepo, _ file: String, mode: ViewMode) throws -> (Bitmap, Int) {
        Render.prepareApplication()
        let size = CGSize(width: 800, height: 480)
        let controller = MainWindowController(path: repo.path)
        let data = try #require(controller.renderSnapshot(size: size, sidebarTab: .files, open: [file], mode: mode))
        let bitmap = try #require(Bitmap.decode(png: data))
        return (bitmap, bitmap.width / Int(size.width))
    }

    /// Bounding box of the pixels that are not the background, in pixels: (minX, minY, maxX, maxY).
    private func inkBox(_ picture: Bitmap, _ region: PixelRegion) -> [Int] {
        var box = [Int.max, Int.max, -1, -1]
        let background = RGB(Theme.background)
        for y in region.y..<(region.y + region.height) {
            for x in region.x..<(region.x + region.width) where !picture.rgb(x, y).isClose(to: background, tolerance: 8) {
                box = [min(box[0], x), min(box[1], y), max(box[2], x), max(box[3], y)]
            }
        }
        return box
    }

    @Test func theFirstLineAndItsNumberLandOnTheSamePixelsInReadAndEditMode() throws {
        let repo = TestRepo()
        repo.write("notes.txt", "use crate::git::{Repo, Status};\nsecond line\n\tthird with a tab\n")
        repo.commitAll("first")
        let (file, scale) = try render(repo, "notes.txt", mode: .read)
        let (edit, editScale) = try render(repo, "notes.txt", mode: .edit)
        #expect(scale == editScale)
        // Title bar 28 + line 1 + tab bar 37 = 66; the first row is 8 pt further down; the main area starts at 289.
        let rowTop = (66 + 8) * scale
        let text = PixelRegion(x: (289 + 60) * scale, y: rowTop, width: 360 * scale, height: 22 * scale)
        let number = PixelRegion(x: 289 * scale, y: rowTop, width: 58 * scale, height: 22 * scale)
        #expect(inkBox(file, text)[0] < Int.max, "the first line is drawn")
        #expect(inkBox(file, text) == inkBox(edit, text))
        #expect(inkBox(file, number) == inkBox(edit, number))
        // Plain text has no syntax colors in the read view either: the line is the same, pixel for pixel.
        var same = true
        for y in text.y..<(text.y + text.height) {
            for x in text.x..<(text.x + text.width) where !file.rgb(x, y).isClose(to: edit.rgb(x, y), tolerance: 2) { same = false }
        }
        #expect(same)
        // The third line starts with a tab: four columns, like the read view.
        let third = PixelRegion(x: (289 + 60) * scale, y: rowTop + 44 * scale, width: 360 * scale, height: 22 * scale)
        #expect(inkBox(file, third) == inkBox(edit, third))
    }

    @Test func theChangeBarsLandOnTheSamePixelsInReadAndEditMode() throws {
        let repo = TestRepo()
        repo.write("notes.txt", numberedText(20))
        repo.commitAll("first")
        var lines = (1...20).map { "line \($0)" }
        lines[2] = "line three, changed"
        lines.insert(contentsOf: ["added one", "added two"], at: 8)
        repo.write("notes.txt", lines.joined(separator: "\n") + "\n")
        let (read, scale) = try render(repo, "notes.txt", mode: .read)
        let (edit, _) = try render(repo, "notes.txt", mode: .edit)
        // The 2 pt bar at the left edge of the main area, over all rows on screen.
        let bars = PixelRegion(x: 289 * scale, y: 66 * scale, width: 4 * scale, height: (480 - 66) * scale)
        #expect(read.count(near: RGB(Ink.yellow.cg), in: bars) == 22 * 2 * scale * scale, "line 3: modified")
        #expect(read.count(near: RGB(Ink.green.cg), in: bars) == 44 * 2 * scale * scale, "lines 9 and 10: added")
        var same = true
        for y in bars.y..<(bars.y + bars.height) {
            for x in bars.x..<(bars.x + bars.width) where !read.rgb(x, y).isClose(to: edit.rgb(x, y), tolerance: 1) { same = false }
        }
        #expect(same)
    }

    @Test func theEditorHasNoSyntaxColors() throws {
        let repo = TestRepo()
        repo.write("main.swift", "let value = \"text\" // comment\n")
        repo.commitAll("first")
        let (file, scale) = try render(repo, "main.swift", mode: .read)
        let (edit, _) = try render(repo, "main.swift", mode: .edit)
        let row = PixelRegion(x: (289 + 66) * scale, y: 74 * scale, width: 300 * scale, height: 22 * scale)
        let keyword = RGB(hex: SyntaxPalette.active.keyword)
        #expect(file.count(near: keyword, in: row, tolerance: 20) > 10)
        #expect(edit.count(near: keyword, in: row, tolerance: 20) == 0)
        #expect(edit.count(near: RGB(Ink.code.cg), in: row, tolerance: 10) > 50)
    }

    @Test func theStripPushesTheEditorTextDown() throws {
        let repo = editRepo()
        let controller = editController(repo.path)
        controller.openForEdit("a.txt")
        controller.showEdit(nil)
        controller.type("mine ")
        repo.write("a.txt", "theirs\n")
        controller.workspace.scanNow()
        controller.rootView.layoutSubtreeIfNeeded()
        let lines = controller.editor?.visibleLineNumbers() ?? []
        #expect(lines.first.map { [$0.line, Int($0.y)] } == [0, 8])
        #expect(controller.editor?.scrollView.frame.minY == Theme.foldHeight)
    }
}
}
