import AppKit
import MicroDiffCore
import MicroDiffTestSupport
import Testing
@testable import MicroDiffUI

extension UITests {
    // MARK: - TreeView

    @MainActor
    @Suite
    struct TreeViewTests {
        private let background = RGB(Theme.background)

        private func fileRow(_ name: String, depth: Int = 1, change: FileChange? = nil) -> TreeRow {
            TreeRow(
                id: TreeRow.makeID(repoIndex: 0, kind: .file, path: name), kind: .file, depth: depth, name: name, path: name,
                repoIndex: change == nil ? -1 : 0, change: change)
        }

        private func repoRow(gapBefore: Bool = false, id: String = "0|r|") -> TreeRow {
            TreeRow(id: id, kind: .repo, depth: 0, name: "project", path: "", repoIndex: 0, isExpanded: true, branch: "main", gapBefore: gapBefore)
        }

        private func dirRow(_ name: String) -> TreeRow {
            TreeRow(id: TreeRow.makeID(repoIndex: 0, kind: .directory, path: name), kind: .directory, depth: 1, name: name, path: name, repoIndex: 0)
        }

        private func tree(_ rows: [TreeRow], style: TreeView.Style = .files, height: CGFloat = 300) -> TreeView {
            let view = TreeView(frame: NSRect(x: 0, y: 0, width: 280, height: height))
            view.style = style
            view.setRows(rows)
            view.layoutSubtreeIfNeeded()
            return view
        }

        private func rowTop(_ index: Int) -> Int { 8 + index * 24 }

        /// Top of row `index` (1 or more) when row 0 is the root row, which is 28 pt tall in both styles.
        private func rowTopBelowRoot(_ index: Int) -> Int { 8 + 28 + (index - 1) * 24 }

        @Test func contentHeightIsPaddingPlusRowHeights() {
            let empty: CGFloat = 16
            let five: CGFloat = 16 + 28 + 4 * 24
            #expect(tree([]).contentSize.height == empty)
            #expect(tree([repoRow()] + (1...4).map { fileRow("f\($0)") }).contentSize.height == five)
        }

        @Test func contentHeightGrowsWithTheRowCount() {
            let few = tree((1...3).map { fileRow("f\($0)") }).contentSize.height
            let many = tree((1...10).map { fileRow("f\($0)") }).contentSize.height
            #expect(many == few + 7 * 24)
        }

        @Test func repoRowsAreTallerAndSeparatedByAGapInBothStyles() {
            // Same heights in both sidebar tabs, so rows do not jump when switching between them.
            let rows = [repoRow(), fileRow("a"), repoRow(gapBefore: true, id: "1|r|"), fileRow("b")]
            let expected: CGFloat = 8 + 28 + 24 + 10 + 28 + 24 + 8
            #expect(tree(rows, style: .changes).contentSize.height == expected)
            #expect(tree(rows, style: .files).contentSize.height == expected)
        }

        @Test func contentSizeFollowsTheViewWidth() {
            let view = tree([fileRow("a")])
            view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
            view.layoutSubtreeIfNeeded()
            #expect(view.contentSize.width == 400)
        }

        @Test func selectedFileRowIsPaintedWithTheSelectionColor() {
            let rows = [repoRow()] + (1...4).map { fileRow("f\($0).txt") }
            let view = tree(rows)
            view.selectedID = rows[3].id
            let bitmap = Render.canvas(view)

            let selected = RGB.composite(Theme.rowSelected, over: Theme.background)
            let band = PixelRegion(x: 0, y: rowTopBelowRoot(3), width: 280, height: 24)
            // The left margin of the row has nothing but the fill.
            let margin = PixelRegion(x: 0, y: rowTopBelowRoot(3), width: 10, height: 24)
            #expect(bitmap.isUniform(selected, in: margin))
            #expect(bitmap.count(near: selected, in: band) > 280 * 24 / 2)
            for other in [1, 2, 4] {
                #expect(bitmap.isUniform(background, in: PixelRegion(x: 0, y: rowTopBelowRoot(other), width: 10, height: 24)), "row \(other)")
            }
        }

        @Test func withoutASelectionNoRowIsFilled() {
            let rows = [repoRow()] + (1...4).map { fileRow("f\($0).txt") }
            let bitmap = Render.canvas(tree(rows))
            let margin = PixelRegion(x: 0, y: 0, width: 10, height: 300)
            #expect(bitmap.isUniform(background, in: margin))
        }

        @Test func selectingTheRepoRowDoesNotPaintIt() {
            let rows = [repoRow(), fileRow("f")]
            let view = tree(rows)
            view.selectedID = rows[0].id
            #expect(Render.canvas(view).isUniform(background, in: PixelRegion(x: 0, y: 0, width: 10, height: 300)))
        }

        @Test func repoRowIsABandInTheChangesStyleOnly() {
            let rows = [repoRow(), fileRow("f")]
            let band = RGB.composite(Theme.band, over: Theme.background)
            let corner = PixelRegion(x: 0, y: 8, width: 8, height: 28)
            #expect(Render.canvas(tree(rows, style: .changes)).isUniform(band, in: corner))
            #expect(Render.canvas(tree(rows, style: .files)).isUniform(background, in: corner))
        }

        @Test func changeLetterIsDrawnOnTheRightOfAChangedRow() {
            let rows = [fileRow("changed.txt", change: FileChange(path: "changed.txt", kind: .modified)), fileRow("plain.txt")]
            let bitmap = Render.canvas(tree(rows))
            let right = { (row: Int) in PixelRegion(x: 240, y: self.rowTop(row), width: 26, height: 24) }
            #expect(bitmap.count(near: RGB(Ink.yellow.cg), in: right(0), tolerance: 40) > 5)
            #expect(bitmap.isUniform(background, in: right(1)))
        }

        @Test func rowsAreDrawnWithIconAndName() {
            let bitmap = Render.canvas(tree([fileRow("hello.txt")]))
            let row = PixelRegion(x: 10, y: rowTop(0), width: 200, height: 24)
            #expect(bitmap.count(notNear: background, in: row) > 50)
        }

        @Test func emptyMessageRendersTextBelowTheRows() {
            let rows = [repoRow(), fileRow("a")]
            let view = tree(rows)
            let below = PixelRegion(x: 0, y: 8 + 28 + 24, width: 280, height: 236)
            #expect(Render.canvas(view).isUniform(background, in: below))

            view.emptyMessage = "no changes"
            let withMessage = Render.canvas(view)
            #expect(withMessage.count(notNear: background, in: below) > 30)
            // And the rows themselves stay as they were.
            #expect(withMessage.count(notNear: background, in: PixelRegion(x: 0, y: 0, width: 280, height: 8 + 28 + 24)) > 50)
        }

        @Test func emptyMessageIsCenteredHorizontally() {
            let view = tree([])
            view.emptyMessage = "not a git repository"
            let bitmap = Render.canvas(view)
            let left = bitmap.count(notNear: background, in: PixelRegion(x: 0, y: 0, width: 140, height: 300))
            let right = bitmap.count(notNear: background, in: PixelRegion(x: 140, y: 0, width: 140, height: 300))
            #expect(left > 20 && right > 20)
            #expect(abs(left - right) < max(left, right) / 2)
        }

        @Test func scrollRowToVisibleBringsALowRowIntoView() {
            let rows = (0..<60).map { fileRow(String(format: "file%02d.txt", $0)) }
            let view = tree(rows, height: 200)
            #expect(view.visibleContentRect.minY == 0)

            view.scrollRowToVisible(id: rows[50].id)
            let top = CGFloat(rowTop(50))
            #expect(view.visibleContentRect.minY <= top)
            #expect(view.visibleContentRect.maxY >= top + 24)
        }

        @Test func onlyRowsInViewAreDrawnWhenScrolled() {
            let rows = (0..<60).map { fileRow(String(format: "file%02d.txt", $0)) }
            let view = tree(rows, height: 200)
            view.selectedID = rows[50].id
            let selected = RGB.composite(Theme.rowSelected, over: Theme.background)
            let margin = PixelRegion(x: 0, y: 0, width: 10, height: 200)
            #expect(Render.canvas(view).isUniform(background, in: margin))

            view.scrollRowToVisible(id: rows[50].id)
            #expect(Render.canvas(view).count(near: selected, in: margin) == 10 * 24)
        }

        @Test func scrollRowToVisibleIgnoresUnknownIDs() {
            let view = tree((0..<60).map { fileRow("f\($0)") }, height: 200)
            view.scrollRowToVisible(id: "nope")
            #expect(view.visibleContentRect.minY == 0)
        }

        // MARK: Mouse and keyboard

        @Test func clickingAFileRowSelectsItAndOpensItAsAPreview() {
            let rows = [repoRow(), dirRow("src"), fileRow("a.txt")]
            let view = tree(rows)
            var opened: [(String, Bool)] = []
            view.onOpen = { opened.append(($0.id, $1)) }
            view.mouse(.down, at: CGPoint(x: 50, y: CGFloat(rowTop(2) + 10)), event: Event.mouse())
            #expect(opened.count == 1)
            #expect(opened[0].0 == rows[2].id)
            #expect(opened[0].1 == false)
            #expect(view.selectedID == rows[2].id)
        }

        @Test func doubleClickingAFileRowPinsIt() {
            let rows = [repoRow(), fileRow("a.txt")]
            let view = tree(rows)
            var pins: [Bool] = []
            view.onOpen = { pins.append($1) }
            view.mouse(.down, at: CGPoint(x: 50, y: CGFloat(rowTop(1) + 10)), event: Event.mouse(clicks: 2))
            #expect(pins == [true])
        }

        @Test func clickingARepoOrFolderRowToggles() {
            let rows = [repoRow(), dirRow("src"), fileRow("a.txt")]
            let view = tree(rows)
            var toggled: [String] = []
            var opened = 0
            view.onToggle = { toggled.append($0.id) }
            view.onOpen = { _, _ in opened += 1 }
            view.mouse(.down, at: CGPoint(x: 50, y: CGFloat(rowTop(0) + 10)), event: Event.mouse())
            view.mouse(.down, at: CGPoint(x: 50, y: CGFloat(rowTop(1) + 10)), event: Event.mouse())
            #expect(toggled == [rows[0].id, rows[1].id])
            #expect(opened == 0)
            #expect(view.selectedID == nil)
        }

        @Test func clickingBelowTheRowsDoesNothing() {
            let view = tree([fileRow("a.txt")])
            var calls = 0
            view.onOpen = { _, _ in calls += 1 }
            view.onToggle = { _ in calls += 1 }
            view.mouse(.down, at: CGPoint(x: 50, y: 250), event: Event.mouse())
            view.mouse(.down, at: CGPoint(x: 50, y: 2), event: Event.mouse())
            #expect(calls == 0)
        }

        @Test func downArrowSelectsTheNextFileSkippingFoldersAsAPreview() {
            let rows = [repoRow(), dirRow("src"), fileRow("a.txt"), dirRow("lib"), fileRow("b.txt")]
            let view = tree(rows)
            var opened: [(String, Bool)] = []
            view.onOpen = { opened.append(($0.id, $1)) }

            view.keyDown(with: Event.key(125))
            #expect(view.selectedID == rows[2].id)
            view.keyDown(with: Event.key(125))
            #expect(view.selectedID == rows[4].id)
            view.keyDown(with: Event.key(125))
            #expect(view.selectedID == rows[4].id)
            #expect(opened.map(\.0) == [rows[2].id, rows[4].id])
            #expect(opened.allSatisfy { !$0.1 })
        }

        @Test func upArrowMovesBackAndStartsAtTheLastFile() {
            let rows = [repoRow(), fileRow("a.txt"), dirRow("lib"), fileRow("b.txt")]
            let view = tree(rows)
            view.keyDown(with: Event.key(126))
            #expect(view.selectedID == rows[3].id)
            view.keyDown(with: Event.key(126))
            #expect(view.selectedID == rows[1].id)
            view.keyDown(with: Event.key(126))
            #expect(view.selectedID == rows[1].id)
        }

        @Test func returnPinsTheSelectedFileAndDoesNothingWithoutSelection() {
            let rows = [repoRow(), fileRow("a.txt")]
            let view = tree(rows)
            var opened: [(String, Bool)] = []
            view.onOpen = { opened.append(($0.id, $1)) }
            view.keyDown(with: Event.key(36))
            #expect(opened.isEmpty)
            view.selectedID = rows[1].id
            view.keyDown(with: Event.key(36))
            #expect(opened.count == 1 && opened[0].1)
        }
    }

    // MARK: - CodeView

    @MainActor
    @Suite
    struct CodeViewTests {
        private static let repo = Fixture.changesRepo()
        private let background = RGB(Theme.background)

        /// Height of one code row in points (the app's line height).
        private var rowHeight: Int { Int(Theme.lineHeight) }

        private func codeView(_ document: TextDocument?, width: CGFloat = 700, height: CGFloat = 300) -> CodeView {
            let view = CodeView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            view.layoutSubtreeIfNeeded()
            view.setDocument(document, keepScroll: false)
            view.layoutSubtreeIfNeeded()
            return view
        }

        private func row(_ y: Int) -> PixelRegion { PixelRegion(x: 400, y: y, width: 200, height: 1) }

        @Test func rendersTextPixelsForADocument() {
            let view = codeView(DocumentFixture.load(Self.repo, "new/deep/fresh.txt"))
            let bitmap = Render.canvas(view)
            let text = PixelRegion(x: Theme.codeX.intRounded, y: 8, width: 120, height: 40)
            #expect(bitmap.count(notNear: background, in: text) > 30)
            #expect(bitmap.count(near: RGB(Ink.code.cg), in: text, tolerance: 12) > 10)
        }

        @Test func drawsLineNumbersInTheGutter() {
            let view = codeView(DocumentFixture.load(Self.repo, "new/deep/fresh.txt"))
            let gutter = PixelRegion(x: 2, y: 8, width: 46, height: 40)
            #expect(Render.canvas(view).count(near: RGB(Ink.lineNumber.cg), in: gutter, tolerance: 20) > 5)
        }

        @Test func nothingIsDrawnWithoutADocument() {
            let view = codeView(nil)
            #expect(Render.canvas(view).isUniform(background, in: PixelRegion(x: 0, y: 0, width: 700, height: 300)))
            #expect(view.contentSize == .zero)
        }

        @Test func plainDocumentStartsWithEightPointsOfBackground() {
            let view = codeView(DocumentFixture.load(Self.repo, "new/deep/fresh.txt"))
            let bitmap = Render.canvas(view)
            #expect(bitmap.isUniform(background, in: PixelRegion(x: 0, y: 0, width: 700, height: 8)))
            let expected: CGFloat = 8 + 2 * Theme.lineHeight + 8
            #expect(view.contentSize.height == expected)
        }

        @Test func documentWhoseFirstRowIsAFoldStartsFlushAtTheTop() throws {
            let document = DocumentFixture.load(Self.repo, "src/app.swift")
            #expect(document.rows.row(at: 0).kind == .fold)
            let view = codeView(document)
            let band = RGB.composite(Theme.band, over: Theme.background)
            let bitmap = Render.canvas(view)
            #expect(bitmap.isUniform(band, in: row(0)))
            #expect(bitmap.isUniform(band, in: row(25)))
            // 26 pt of band, then the next row.
            #expect(!bitmap.isUniform(band, in: PixelRegion(x: 0, y: 26, width: 700, height: 4)))
            #expect(view.contentSize.height == CGFloat(document.rows.contentHeight) + 8)
        }

        @Test func foldRowShowsItsUnchangedLinesLabel() {
            let document = DocumentFixture.load(Self.repo, "src/app.swift")
            let view = codeView(document)
            let label = PixelRegion(x: Theme.codeX.intRounded, y: 0, width: 160, height: 26)
            let band = RGB.composite(Theme.band, over: Theme.background)
            #expect(Render.canvas(view).count(notNear: band, in: label) > 30)
        }

        @Test func diffDocumentWithAChangedFirstLineStartsWithBackgroundThenATintedRow() {
            let document = DocumentFixture.load(Self.repo, "src/other.swift")
            #expect(document.rows.row(at: 0).kind != .fold)
            let bitmap = Render.canvas(codeView(document))
            #expect(bitmap.isUniform(background, in: PixelRegion(x: 0, y: 0, width: 700, height: 8)))
            let deleted = RGB.composite(Theme.deletedRow, over: Theme.background)
            let added = RGB.composite(Theme.addedRow, over: Theme.background)
            #expect(bitmap.isUniform(deleted, in: PixelRegion(x: 600, y: 8, width: 90, height: rowHeight)))
            #expect(bitmap.isUniform(added, in: PixelRegion(x: 600, y: 8 + rowHeight, width: 90, height: rowHeight)))
            // Bands are the design's red and green at 12% over the window background.
            func band(_ hex: UInt32) -> RGB { RGB.composite(Theme.rgb(hex, 0.12), over: RGB(hex: 0x22262c)) }
            #expect(deleted == band(0xe17177))
            #expect(added == band(0x94c580))
        }

        @Test func gutterBarsAreGreenForAddedAndRedForDeletedRows() {
            let bitmap = Render.canvas(codeView(DocumentFixture.load(Self.repo, "src/other.swift")))
            #expect(bitmap.isUniform(RGB(Ink.red.cg), in: PixelRegion(x: 0, y: 8, width: 2, height: rowHeight)))
            #expect(bitmap.isUniform(RGB(Ink.green.cg), in: PixelRegion(x: 0, y: 8 + rowHeight, width: 2, height: rowHeight)))
            #expect(bitmap.isUniform(RGB(hex: 0xe17177), in: PixelRegion(x: 0, y: 8, width: 2, height: rowHeight)))
            #expect(bitmap.isUniform(RGB(hex: 0x94c580), in: PixelRegion(x: 0, y: 8 + rowHeight, width: 2, height: rowHeight)))
            #expect(bitmap.isUniform(background, in: PixelRegion(x: 0, y: 8 + 2 * rowHeight, width: 2, height: rowHeight)))
        }

        @Test func wordLevelChangesGetAStrongerTint() {
            let bitmap = Render.canvas(codeView(DocumentFixture.load(Self.repo, "src/other.swift")))
            let word = RGB.composite(Theme.addedWord, over: RGB.composite(Theme.addedRow, over: Theme.background))
            #expect(bitmap.count(near: word, in: PixelRegion(x: 0, y: 8 + rowHeight, width: 400, height: rowHeight), tolerance: 4) > 20)
        }

        @Test func readModeMarksChangedLinesInTheGutterOnly() {
            let document = DocumentFixture.load(Self.repo, "src/app.swift", mode: .read)
            #expect(document.kind == .file)
            let view = codeView(document)
            let bitmap = Render.canvas(view)
            #expect(bitmap.isUniform(RGB(Ink.yellow.cg), in: PixelRegion(x: 0, y: 8 + 19 * rowHeight, width: 2, height: rowHeight)))
            #expect(bitmap.isUniform(background, in: PixelRegion(x: 0, y: 8, width: 2, height: rowHeight)))
        }

        @Test func deletedFileShowsAllOldLinesAsDeletedRows() {
            let document = DocumentFixture.load(Self.repo, "docs/old.txt")
            #expect(document.kind == .deleted)
            let deleted = RGB.composite(Theme.deletedRow, over: Theme.background)
            let bitmap = Render.canvas(codeView(document))
            #expect(bitmap.isUniform(deleted, in: PixelRegion(x: 600, y: 8, width: 90, height: 40)))
        }

        @Test func tabsInCodeDoNotBreakDrawing() {
            let repo = TestRepo()
            repo.write("tabs.txt", "\tindented\n\t\tmore\n")
            let view = codeView(DocumentFixture.load(repo, "tabs.txt"))
            #expect(Render.canvas(view).count(notNear: background, in: PixelRegion(x: 60, y: 8, width: 300, height: 40)) > 30)
        }

        @Test func veryLongLinesAreCutForDisplay() {
            let repo = TestRepo()
            repo.write("long.txt", String(repeating: "x", count: 50_000) + "\nshort\n")
            let view = codeView(DocumentFixture.load(repo, "long.txt"))
            let widest = Theme.codeX + 4000 * Theme.codeCharWidth + 32
            #expect(view.contentSize.width <= widest + 1)
            _ = Render.canvas(view)
        }

        @Test func contentWidthFitsTheLongestLine() {
            let repo = TestRepo()
            repo.write("wide.txt", String(repeating: "y", count: 300) + "\n")
            let view = codeView(DocumentFixture.load(repo, "wide.txt"), width: 400)
            #expect(view.contentSize.width >= Theme.codeX + 300 * Theme.codeCharWidth)
        }

        @Test func emptyFileRendersNothingAndCanBeClicked() throws {
            let repo = TestRepo()
            repo.write("empty.txt", "")
            let view = codeView(DocumentFixture.load(repo, "empty.txt"))
            #expect(Render.canvas(view).isUniform(background, in: PixelRegion(x: 0, y: 0, width: 700, height: 300)))
            view.mouse(.down, at: CGPoint(x: 100, y: 20), event: Event.mouse())
            view.selectAll(nil)
            #expect(Render.canvas(view).isUniform(background, in: PixelRegion(x: 0, y: 0, width: 700, height: 300)))
        }

        @Test func clickingOutsideTheRowsDoesNotCrashAndSelectsNothingVisible() {
            let view = codeView(DocumentFixture.load(Self.repo, "new/deep/fresh.txt"))
            for point in [CGPoint(x: 100, y: 1), CGPoint(x: 100, y: 280), CGPoint(x: 5, y: 18), CGPoint(x: 690, y: 18)] {
                view.mouse(.down, at: point, event: Event.mouse())
                view.mouse(.up, at: point, event: Event.mouse(.leftMouseUp))
            }
            let selection = RGB.composite(Theme.textSelection, over: Theme.background)
            #expect(Render.canvas(view).count(near: selection, tolerance: 6) == 0)
        }

        @Test func unicodeAndLongLinesDrawWithoutTrouble() {
            let repo = TestRepo()
            repo.write("u.txt", "caf\u{e9} \u{1F600} \u{4E2D}\u{6587}\nline two\r\nlast without newline")
            let document = DocumentFixture.load(repo, "u.txt")
            #expect(document.rows.rowCount == 3)
            let bitmap = Render.canvas(codeView(document))
            #expect(bitmap.count(notNear: background, in: PixelRegion(x: 60, y: 8, width: 300, height: 60)) > 100)
        }

        // MARK: Scroll

        @Test func setDocumentScrollsToTheGivenOffset() {
            let view = CodeView(frame: NSRect(x: 0, y: 0, width: 700, height: 300))
            view.layoutSubtreeIfNeeded()
            view.setDocument(DocumentFixture.load(Self.repo, "src/app.swift", mode: .read), keepScroll: false, scroll: CGPoint(x: 0, y: 120))
            #expect(view.scrollOffset == CGPoint(x: 0, y: 120))
        }

        @Test func keepScrollLeavesTheViewWhereItIs() {
            let view = codeView(DocumentFixture.load(Self.repo, "src/app.swift", mode: .read))
            view.scroll(to: CGPoint(x: 0, y: 200))
            view.setDocument(DocumentFixture.load(Self.repo, "src/app.swift", mode: .read), keepScroll: true)
            #expect(view.scrollOffset.y == 200)
            view.setDocument(DocumentFixture.load(Self.repo, "src/app.swift", mode: .read), keepScroll: false)
            #expect(view.scrollOffset.y == 0)
        }

        @Test func scrollOffsetIsClampedToTheContent() {
            let view = codeView(DocumentFixture.load(Self.repo, "src/app.swift", mode: .read))
            view.scroll(to: CGPoint(x: 0, y: 100_000))
            #expect(view.scrollOffset.y == view.contentSize.height - 300)
            view.scroll(to: CGPoint(x: 0, y: -50))
            #expect(view.scrollOffset.y == 0)
        }

        @Test func scrollingReportsTheNewOffset() {
            let view = codeView(DocumentFixture.load(Self.repo, "src/app.swift", mode: .read))
            var offsets: [CGPoint] = []
            view.onScroll = { offsets.append($0) }
            view.scroll(to: CGPoint(x: 0, y: 80))
            #expect(offsets.last == CGPoint(x: 0, y: 80))
        }

        @Test func scrolledViewDrawsTheRowsThatAreInView() {
            let view = codeView(DocumentFixture.load(Self.repo, "src/app.swift", mode: .read))
            let marked = PixelRegion(x: 0, y: 8 + 19 * rowHeight - 200, width: 2, height: rowHeight)
            view.scroll(to: CGPoint(x: 0, y: 200))
            let bitmap = Render.canvas(view)
            #expect(bitmap.isUniform(RGB(Ink.yellow.cg), in: marked))
        }

        @Test func keyboardScrollsByLinesPagesAndToTheEnds() {
            let view = codeView(DocumentFixture.load(Self.repo, "src/app.swift", mode: .read))
            view.keyDown(with: Event.key(125))
            #expect(view.scrollOffset.y == Theme.lineHeight)
            view.keyDown(with: Event.key(126))
            #expect(view.scrollOffset.y == 0)
            view.keyDown(with: Event.key(121))
            let page: CGFloat = 300 - 2 * Theme.lineHeight
            #expect(view.scrollOffset.y == page)
            view.keyDown(with: Event.key(119))
            #expect(view.scrollOffset.y == view.contentSize.height - 300)
            view.keyDown(with: Event.key(115))
            #expect(view.scrollOffset.y == 0)
        }

        // MARK: Mouse

        @Test func clickingAFoldRowAsksToExpandItFromItsFirstHiddenLine() throws {
            let document = DocumentFixture.load(Self.repo, "src/app.swift")
            let view = codeView(document)
            var expanded: [Int] = []
            view.onExpandFold = { expanded.append($0) }
            view.mouse(.down, at: CGPoint(x: 100, y: 10), event: Event.mouse())
            #expect(expanded == [document.foldRows[0].line])
        }

        @Test func draggingAcrossTextPaintsASelection() {
            let view = codeView(DocumentFixture.load(Self.repo, "new/deep/fresh.txt"))
            let x = Theme.codeX
            view.mouse(.down, at: CGPoint(x: x + 2, y: 18), event: Event.mouse())
            view.mouse(.dragged, at: CGPoint(x: x + 5 * Theme.codeCharWidth + 1, y: 18), event: Event.mouse(.leftMouseDragged))
            view.mouse(.up, at: CGPoint(x: x + 5 * Theme.codeCharWidth + 1, y: 18), event: Event.mouse(.leftMouseUp))

            let selection = RGB.composite(Theme.textSelection, over: Theme.background)
            let bitmap = Render.canvas(view)
            let first = PixelRegion(x: 0, y: 8, width: 700, height: rowHeight)
            let count = bitmap.count(near: selection, in: first, tolerance: 6)
            // About five characters wide, one line tall, minus the glyphs on top.
            #expect(count > Int(4 * Theme.codeCharWidth) * 8)
            #expect(count < Int(7 * Theme.codeCharWidth) * rowHeight)
            #expect(bitmap.count(near: selection, in: PixelRegion(x: 0, y: 8 + rowHeight, width: 700, height: rowHeight), tolerance: 6) == 0)
        }

        @Test func clickWithoutDraggingSelectsNothing() {
            let view = codeView(DocumentFixture.load(Self.repo, "new/deep/fresh.txt"))
            view.mouse(.down, at: CGPoint(x: Theme.codeX + 30, y: 18), event: Event.mouse())
            let selection = RGB.composite(Theme.textSelection, over: Theme.background)
            #expect(Render.canvas(view).count(near: selection, tolerance: 6) == 0)
        }

        @Test func doubleClickSelectsTheWordUnderThePointer() {
            let view = codeView(DocumentFixture.load(Self.repo, "new/deep/fresh.txt"))
            view.mouse(.down, at: CGPoint(x: Theme.codeX + 2 * Theme.codeCharWidth, y: 18), event: Event.mouse(clicks: 2))
            let selection = RGB.composite(Theme.textSelection, over: Theme.background)
            let count = Render.canvas(view).count(near: selection, in: PixelRegion(x: 0, y: 8, width: 700, height: rowHeight), tolerance: 6)
            // "fresh" is five characters.
            #expect(count > Int(4 * Theme.codeCharWidth) * 8)
            #expect(count < Int(6 * Theme.codeCharWidth) * rowHeight)
        }

        @Test func tripleClickSelectsTheWholeLine() {
            let view = codeView(DocumentFixture.load(Self.repo, "new/deep/fresh.txt"))
            view.mouse(.down, at: CGPoint(x: Theme.codeX + 2 * Theme.codeCharWidth, y: 18), event: Event.mouse(clicks: 3))
            let selection = RGB.composite(Theme.textSelection, over: Theme.background)
            let bitmap = Render.canvas(view)
            let count = bitmap.count(near: selection, in: PixelRegion(x: 0, y: 8, width: 700, height: rowHeight), tolerance: 6)
            // "fresh file" is ten characters.
            #expect(count > Int(8 * Theme.codeCharWidth) * 8)
            #expect(bitmap.count(near: selection, in: PixelRegion(x: 0, y: 8 + rowHeight, width: 700, height: rowHeight), tolerance: 6) == 0)
        }

        @Test func selectAllSelectsEveryRow() {
            let view = codeView(DocumentFixture.load(Self.repo, "new/deep/fresh.txt"))
            view.selectAll(nil)
            let selection = RGB.composite(Theme.textSelection, over: Theme.background)
            let bitmap = Render.canvas(view)
            #expect(bitmap.count(near: selection, in: PixelRegion(x: 0, y: 8, width: 700, height: rowHeight), tolerance: 6) > 50)
            #expect(bitmap.count(near: selection, in: PixelRegion(x: 0, y: 8 + rowHeight, width: 700, height: rowHeight), tolerance: 6) > 50)
        }

        @Test func settingANewDocumentClearsTheSelection() {
            let view = codeView(DocumentFixture.load(Self.repo, "new/deep/fresh.txt"))
            view.selectAll(nil)
            view.setDocument(DocumentFixture.load(Self.repo, "new/deep/fresh.txt"), keepScroll: false)
            let selection = RGB.composite(Theme.textSelection, over: Theme.background)
            #expect(Render.canvas(view).count(near: selection, tolerance: 6) == 0)
        }
    }

}
private extension CGFloat {
    var intRounded: Int { Int(self.rounded()) }
}

// MARK: - FileTabBarView

@MainActor
@Suite
struct FileTabBarViewTests {
    private let active = RGB(Theme.background)
    private let inactive = RGB(Theme.inactive)
    private let line = RGB(Theme.line)

    private func tabs(_ names: [String], preview: Set<Int> = [], kinds: [Int: ChangeKind] = [:]) -> [FileTab] {
        names.enumerated().map { FileTab(title: $1, kind: kinds[$0], isPreview: preview.contains($0)) }
    }

    private func bar(_ tabs: [FileTab], active: Int?, mode: ViewMode = .diff, width: CGFloat = 800) -> FileTabBarView {
        let view = FileTabBarView(frame: NSRect(x: 0, y: 0, width: width, height: Theme.tabBarHeight))
        view.update(tabs: tabs, activeIndex: active, mode: mode)
        return view
    }

    @Test func activeTabHasTheBackgroundColorAndTheRestOfTheBarTheInactiveColor() {
        let view = bar(tabs(["one.swift", "two.swift"]), active: 0)
        let bitmap = Render.tabBar(view)
        // Tabs are 150 pt wide while they fit: [0, 150) active, [150, 300) inactive, then the empty bar.
        #expect(bitmap.isUniform(active, in: PixelRegion(x: 2, y: 0, width: 8, height: 36)))
        #expect(bitmap.isUniform(active, in: PixelRegion(x: 140, y: 0, width: 8, height: 36)))
        #expect(bitmap.isUniform(inactive, in: PixelRegion(x: 156, y: 0, width: 8, height: 36)))
        #expect(bitmap.isUniform(inactive, in: PixelRegion(x: 310, y: 0, width: 200, height: 36)))
    }

    @Test func theBarHasALineUnderItExceptUnderTheActiveTab() {
        let bitmap = Render.tabBar(bar(tabs(["one.swift", "two.swift"]), active: 0))
        #expect(bitmap.isUniform(line, in: PixelRegion(x: 310, y: 36, width: 200, height: 1)))
        #expect(bitmap.isUniform(line, in: PixelRegion(x: 156, y: 36, width: 100, height: 1)))
        #expect(bitmap.isUniform(active, in: PixelRegion(x: 2, y: 36, width: 100, height: 1)))
    }

    @Test func inactiveTabsAreSeparatedByALine() {
        let bitmap = Render.tabBar(bar(tabs(["a.rs", "b.rs", "c.rs"]), active: 0))
        #expect(bitmap.isUniform(line, in: PixelRegion(x: 150, y: 0, width: 1, height: 36)))
        #expect(bitmap.isUniform(line, in: PixelRegion(x: 300, y: 0, width: 1, height: 36)))
    }

    @Test func activeTabInTheMiddleIsTheOneThatIsFilled() {
        let bitmap = Render.tabBar(bar(tabs(["a.rs", "b.rs", "c.rs"]), active: 1))
        #expect(bitmap.isUniform(active, in: PixelRegion(x: 152, y: 0, width: 8, height: 36)))
        #expect(bitmap.isUniform(inactive, in: PixelRegion(x: 4, y: 0, width: 8, height: 36)))
        #expect(bitmap.isUniform(inactive, in: PixelRegion(x: 304, y: 0, width: 8, height: 36)))
    }

    @Test func tabTitleStatusLetterAndCloseButtonAreDrawn() {
        let view = bar(tabs(["one.swift"], kinds: [0: .modified]), active: 0)
        let bitmap = Render.tabBar(view)
        let middle = PixelRegion(x: 10, y: 4, width: 130, height: 28)
        #expect(bitmap.count(notNear: active, in: middle) > 60)
        #expect(bitmap.count(near: RGB(Ink.yellow.cg), in: middle, tolerance: 30) > 3)
    }

    @Test func modeSwitchIsPinnedAtTheRightAndHighlightsTheCurrentMode() {
        let diffWidth = Int(TextCache.shared.line("diff", .regular, .fg).width)
        let right = PixelRegion(x: 700, y: 4, width: 100, height: 28)
        let diffMode = Render.tabBar(bar(tabs(["a.rs"]), active: 0, mode: .diff))
        let readMode = Render.tabBar(bar(tabs(["a.rs"]), active: 0, mode: .read))
        let fg = RGB(Ink.fg.cg)
        // "diff" is bright in diff mode, "read" is bright in read mode: the bright pixels move.
        let bright = { (b: Bitmap, x: Int) in b.count(near: fg, in: PixelRegion(x: x, y: 4, width: 40, height: 28), tolerance: 25) }
        let editMode = Render.tabBar(bar(tabs(["a.rs"]), active: 0, mode: .edit))
        let editX = 800 - 16 - diffWidth
        let readX = editX - Int(Theme.charWidth * 2) - diffWidth
        let diffX = readX - Int(Theme.charWidth * 2) - diffWidth
        #expect(bright(diffMode, diffX) > bright(readMode, diffX))
        #expect(bright(readMode, readX) > bright(diffMode, readX))
        #expect(bright(editMode, editX) > bright(readMode, editX))
        #expect(diffMode.count(notNear: inactive, in: right) > 40)
    }

    @Test func emptyBarShowsNoControls() {
        let bitmap = Render.tabBar(bar([], active: nil))
        #expect(bitmap.isUniform(inactive, in: PixelRegion(x: 0, y: 0, width: 800, height: 36)))
        #expect(bitmap.isUniform(line, in: PixelRegion(x: 0, y: 36, width: 800, height: 1)))
    }

    @Test func previewTabsRenderLikeTabsWithADifferentFace() {
        let normal = Render.tabBar(bar(tabs(["name.swift"]), active: 0))
        let preview = Render.tabBar(bar(tabs(["name.swift"], preview: [0]), active: 0))
        let area = PixelRegion(x: 0, y: 0, width: 150, height: 36)
        #expect(preview.count(notNear: active, in: area) > 30)
        #expect(normal.count(notNear: active, in: area) > 30)
    }

    @Test func thirtyTabsRenderAndShowTheOverflowCount() {
        let names = (0..<30).map { String(format: "file%02d.swift", $0) }
        let view = bar(tabs(names), active: 29)
        let bitmap = Render.tabBar(view)
        // The overflow button ("30" and a chevron) sits left of the mode switch.
        #expect(bitmap.count(notNear: inactive, in: PixelRegion(x: 600, y: 4, width: 90, height: 28)) > 30)
        // The active tab is scrolled into view: some of the strip has the active (background) color.
        #expect(bitmap.count(near: active, in: PixelRegion(x: 0, y: 0, width: 580, height: 36)) > 500)
    }

    @Test func activeTabIsRevealedAgainAfterTheActiveIndexChanges() {
        let names = (0..<30).map { String(format: "file%02d.swift", $0) }
        let view = bar(tabs(names), active: 29)
        _ = Render.tabBar(view)

        view.update(tabs: tabs(names), activeIndex: 0, mode: .diff)
        let bitmap = Render.tabBar(view)
        #expect(bitmap.isUniform(active, in: PixelRegion(x: 2, y: 0, width: 8, height: 36)))
    }

    @Test func updateStoresWhatItWasGiven() {
        let view = bar(tabs(["a", "b"]), active: 1, mode: .read)
        #expect(view.tabs.map(\.title) == ["a", "b"])
        #expect(view.activeIndex == 1)
        #expect(view.mode == .read)
    }

    // MARK: Mouse

    @Test func clickingATabSelectsItAndDoubleClickingPinsIt() {
        let view = bar(tabs(["a.rs", "b.rs"]), active: 0)
        var selected: [Int] = []
        var pinned: [Int] = []
        view.onSelect = { selected.append($0) }
        view.onPin = { pinned.append($0) }
        view.mouseDown(with: Event.mouse(at: CGPoint(x: 200, y: 18)))
        view.mouseDown(with: Event.mouse(at: CGPoint(x: 200, y: 18), clicks: 2))
        #expect(selected == [1])
        #expect(pinned == [1])
    }

    @Test func clickingTheModeSwitchChangesTheMode() {
        let view = bar(tabs(["a.rs"]), active: 0)
        var modes: [ViewMode] = []
        view.onMode = { modes.append($0) }
        let diffWidth = TextCache.shared.line("diff", .regular, .fg).width
        let readWidth = TextCache.shared.line("read", .regular, .fg).width
        let editWidth = TextCache.shared.line("edit", .regular, .fg).width
        let editX = 800 - 16 - editWidth
        let readX = editX - Theme.charWidth * 2 - readWidth
        let diffX = readX - Theme.charWidth * 2 - diffWidth
        view.mouseDown(with: Event.mouse(at: CGPoint(x: readX + 2, y: 18)))
        view.mouseDown(with: Event.mouse(at: CGPoint(x: diffX + 2, y: 18)))
        view.mouseDown(with: Event.mouse(at: CGPoint(x: editX + 2, y: 18)))
        #expect(modes == [.read, .diff, .edit])
    }

    @Test func clickingTheEmptyPartOfTheBarDoesNothing() {
        let view = bar(tabs(["a.rs"]), active: 0)
        var calls = 0
        view.onSelect = { _ in calls += 1 }
        view.onPin = { _ in calls += 1 }
        view.onClose = { _ in calls += 1 }
        view.onMode = { _ in calls += 1 }
        view.mouseDown(with: Event.mouse(at: CGPoint(x: 400, y: 18)))
        #expect(calls == 0)
    }

    @Test func middleClickClosesATab() throws {
        let view = bar(tabs(["a.rs", "b.rs"]), active: 0)
        var closed: [Int] = []
        view.onClose = { closed.append($0) }
        let click = try #require(Event.middleClick(at: CGPoint(x: 200, y: 18)))
        view.otherMouseDown(with: click)
        #expect(closed == [1])
    }
}


// MARK: - SidebarTabsView

@MainActor
struct SidebarTabsViewTests {
    private func render(_ selected: SidebarTab, count: Int = 3) -> Bitmap {
        let view = SidebarTabsView(frame: NSRect(x: 0, y: 0, width: 288, height: Theme.tabBarHeight))
        view.selected = selected
        view.changeCount = count
        return Bitmap.render(width: 288, height: Int(Theme.tabBarHeight), background: Theme.background) { ctx in
            let saved = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            view.draw(view.bounds)
            NSGraphicsContext.current = saved
        }
    }

    @Test func theSelectedTabKeepsTheBackgroundAndTheOtherIsDarker() {
        let active = RGB(Theme.background)
        let inactive = RGB(Theme.inactive)
        let changes = render(.changes)
        #expect(changes.isUniform(active, in: PixelRegion(x: 2, y: 0, width: 8, height: 36)))
        #expect(changes.isUniform(inactive, in: PixelRegion(x: 150, y: 0, width: 8, height: 36)))
        let files = render(.files)
        #expect(files.isUniform(inactive, in: PixelRegion(x: 2, y: 0, width: 8, height: 36)))
        #expect(files.isUniform(active, in: PixelRegion(x: 150, y: 0, width: 8, height: 36)))
    }

    @Test func labelsAreDrawnInBothTabs() {
        let bitmap = render(.changes)
        #expect(bitmap.count(notNear: RGB(Theme.background), in: PixelRegion(x: 30, y: 4, width: 90, height: 28)) > 30)
        #expect(bitmap.count(notNear: RGB(Theme.inactive), in: PixelRegion(x: 180, y: 4, width: 70, height: 28)) > 20)
    }

    @Test func changeCountIsPartOfTheChangesLabel() {
        let few = render(.changes, count: 3)
        let many = render(.changes, count: 1234)
        let area = PixelRegion(x: 0, y: 4, width: 144, height: 28)
        #expect(many.count(notNear: RGB(Theme.background), in: area) > few.count(notNear: RGB(Theme.background), in: area))
    }
}
