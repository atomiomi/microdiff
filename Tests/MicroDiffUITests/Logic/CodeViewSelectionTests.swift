import AppKit
import MicroDiffCore
import MicroDiffTestSupport
import Testing
@testable import MicroDiffUI

extension UITests {
    /// What ends up on the pasteboard when the user selects text in the code view and copies it.
    /// (`selectedText` is what `copy` writes; the tests do not touch the real pasteboard.)
    @MainActor
    @Suite
    struct CodeViewSelectionTests {
        private static let repo = Fixture.changesRepo()
        private let rowHeight = Theme.lineHeight

        private func view(_ path: String, mode: ViewMode = .diff, height: CGFloat = 900) -> CodeView {
            let view = CodeView(frame: NSRect(x: 0, y: 0, width: 800, height: height))
            view.layoutSubtreeIfNeeded()
            view.setDocument(DocumentFixture.load(Self.repo, path, mode: mode), keepScroll: false)
            view.layoutSubtreeIfNeeded()
            return view
        }

        /// A point in row `row` (counted from the top), `characters` characters right of the code's left edge.
        private func at(row: Int, characters: Double) -> CGPoint {
            let x: CGFloat = Theme.codeX + CGFloat(characters) * Theme.codeCharWidth + 1
            let y: CGFloat = 8 + (CGFloat(row) + 0.5) * rowHeight
            return CGPoint(x: x, y: y)
        }

        private func drag(_ view: CodeView, from: CGPoint, to: CGPoint) {
            view.mouse(.down, at: from, event: Event.mouse())
            view.mouse(.dragged, at: to, event: Event.mouse(.leftMouseDragged))
            view.mouse(.up, at: to, event: Event.mouse(.leftMouseUp))
        }

        @Test func nothingIsSelectedUntilTheUserSelects() {
            let view = view("new/deep/fresh.txt")
            #expect(view.selectedText == nil)
            view.mouse(.down, at: at(row: 0, characters: 3), event: Event.mouse())
            #expect(view.selectedText == nil)
        }

        @Test func draggingInsideOneLineSelectsThoseCharacters() {
            let view = view("new/deep/fresh.txt")
            drag(view, from: at(row: 0, characters: 0), to: at(row: 0, characters: 5))
            #expect(view.selectedText == "fresh")
        }

        @Test func draggingAcrossLinesTakesTheEndOfTheFirstAndTheStartOfTheLast() {
            let view = view("new/deep/fresh.txt")
            drag(view, from: at(row: 0, characters: 6), to: at(row: 1, characters: 6))
            #expect(view.selectedText == "file\nsecond")
        }

        @Test func draggingBackwardsSelectsTheSameText() {
            let view = view("new/deep/fresh.txt")
            drag(view, from: at(row: 1, characters: 6), to: at(row: 0, characters: 6))
            #expect(view.selectedText == "file\nsecond")
        }

        @Test func draggingPastTheEndOfALineSelectsToTheEndOfIt() {
            let view = view("new/deep/fresh.txt")
            drag(view, from: at(row: 0, characters: 6), to: at(row: 0, characters: 60))
            #expect(view.selectedText == "file")
        }

        @Test func doubleClickSelectsOneWordAndTripleClickTheLine() {
            let view = view("new/deep/fresh.txt")
            view.mouse(.down, at: at(row: 1, characters: 2), event: Event.mouse(clicks: 2))
            #expect(view.selectedText == "second")
            view.mouse(.down, at: at(row: 1, characters: 2), event: Event.mouse(clicks: 3))
            #expect(view.selectedText == "second line")
        }

        @Test func doubleClickOnAPunctuationMarkSelectsJustThatMark() {
            let view = view("src/app.swift", mode: .file)
            // "let value1 = 1": the "=" is the 12th character (index 11).
            view.mouse(.down, at: at(row: 0, characters: 11.5), event: Event.mouse(clicks: 2))
            #expect(view.selectedText == "=")
            // Digits, letters and underscores make a word: "value1".
            view.mouse(.down, at: at(row: 0, characters: 6), event: Event.mouse(clicks: 2))
            #expect(view.selectedText == "value1")
        }

        @Test func shiftClickExtendsTheSelectionFromItsAnchor() {
            let view = view("new/deep/fresh.txt")
            view.mouse(.down, at: at(row: 0, characters: 0), event: Event.mouse())
            view.mouse(.down, at: at(row: 1, characters: 6), event: Event.mouse(modifiers: .shift))
            #expect(view.selectedText == "fresh file\nsecond")
        }

        @Test func selectAllTakesEveryLine() {
            let view = view("new/deep/fresh.txt")
            view.selectAll(nil)
            #expect(view.selectedText == "fresh file\nsecond line")
        }

        @Test func selectAllInADiffHasDeletedAndAddedLinesAndNoFoldRows() throws {
            let view = view("src/app.swift")
            view.selectAll(nil)
            let text = try #require(view.selectedText)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            // Both versions of a changed line are there, in diff order: deleted first.
            let old = try #require(lines.firstIndex(of: "let value20 = 20"))
            let new = try #require(lines.firstIndex(of: "let value20 = 2000"))
            #expect(old + 1 == new)
            // Folded lines are not copied, and a fold row adds nothing (no empty lines between hunks).
            #expect(!lines.contains("let value1 = 1"))
            #expect(!lines.contains(""))
        }

        @Test func selectionAcrossAFoldSkipsTheFoldRowButKeepsBothSides() throws {
            let view = view("src/app.swift")
            let document = DocumentFixture.load(Self.repo, "src/app.swift")
            // A fold with visible rows on both sides: the one between the two hunks.
            let folds = (0..<document.rows.rowCount).filter { document.rows.row(at: $0).kind == .fold }
            let foldRow = try #require(folds.first { $0 > 0 && $0 + 2 < document.rows.rowCount })
            // Two lines below the fold first, then a drag that crosses the fold.
            let below = foldRow + 1
            drag(view, from: at(row: below, characters: 0), to: at(row: below + 1, characters: 4))
            let forward = try #require(view.selectedText)
            #expect(forward.split(separator: "\n", omittingEmptySubsequences: false).count == 2)

            drag(view, from: at(row: foldRow - 1, characters: 0), to: at(row: foldRow + 1, characters: 3))
            let across = try #require(view.selectedText)
            let parts = across.split(separator: "\n", omittingEmptySubsequences: false)
            // Row above the fold, the fold itself (skipped), the row below: two lines.
            #expect(parts.count == 2)
            #expect(parts[1].count == 3)
        }

        @Test func removingTheDocumentClearsTheSelection() {
            let view = view("new/deep/fresh.txt")
            view.selectAll(nil)
            #expect(view.selectedText != nil)
            view.setDocument(nil, keepScroll: false)
            #expect(view.selectedText == nil)
        }
    }
}
