import AppKit
import MicroDiffCore
import Testing
@testable import MicroDiffUI

extension UITests {
    /// What the tree looks like when it is scrolled sideways.
    @MainActor
    struct TreeHorizontalScrollRenderingTests {
        typealias T = TreeHorizontalScrollTests
        private let background = RGB(Theme.background)
        private let width = Int(T.width)
        private let letter = TextCache.shared.line("M", .small, .dim).width

        private func top(_ index: Int) -> Int { 8 + index * 24 }
        private func midY(_ index: Int) -> Int { top(index) + 12 }
        private var edge: CGFloat { T.width - Theme.treePadding }
        private var markerLeft: Int { Int((edge - letter).rounded(.down)) }

        private func render(_ tree: TreeView, x: CGFloat) -> Bitmap {
            tree.scroll(to: CGPoint(x: x, y: 0))
            return Render.canvas(tree)
        }

        private func distance(_ a: RGB, _ b: RGB) -> Int { abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) }

        /// Total difference from a color over a rectangle.
        private func glow(_ bitmap: Bitmap, x: Int, row: Int, width w: Int, over color: RGB) -> Int {
            var total = 0
            for yy in top(row)..<(top(row) + 24) {
                for xx in x..<(x + w) { total += distance(bitmap.rgb(xx, yy), color) }
            }
            return total
        }

        // MARK: no range, nothing new

        @Test func rowsThatFitDrawNoPatchEvenNextToAMarker() {
            // A name that ends just before the marker gap: no range, and the marker's background is not drawn at all.
            let tree = T.tree([T.file("a" + String(repeating: "x", count: 22), change: .modified)])
            #expect(T.range(tree) == 0)
            let bitmap = Render.canvas(tree)
            let reference = Render.canvas(T.tree([T.file("a" + String(repeating: "x", count: 22), change: .modified)]))
            #expect(bitmap.count(notNear: background, in: PixelRegion(x: 0, y: 0, width: width, height: 60)) ==
                reference.count(notNear: background, in: PixelRegion(x: 0, y: 0, width: width, height: 60)))
            // The letter is where it always was.
            #expect(bitmap.count(near: RGB(Ink.yellow.cg), in: PixelRegion(x: markerLeft - 1, y: top(0), width: 10, height: 24), tolerance: 12) > 3)
        }

        // MARK: scrolled content

        private var deepRows: [TreeRow] {
            [T.dir("one", depth: 1), T.dir("two", depth: 2), T.dir("three", depth: 3),
             T.file(String(repeating: "q", count: 55) + ".txt", depth: 4), T.file("tiny", depth: 4)]
        }

        @Test func namesIconsAndGuidesMoveWithTheScroll() {
            let rows = deepRows
            let tree = T.tree(rows)
            let shift = 50
            #expect(T.range(tree) >= CGFloat(shift))
            let base = render(tree, x: 0)
            let moved = render(tree, x: CGFloat(shift))
            // The tiny row has no marker and ends early: its whole picture is the same, shifted.
            for y in top(4)..<(top(4) + 24) {
                for x in 0..<(width - shift) {
                    #expect(moved.rgb(x, y) == base.rgb(x + shift, y), "pixel \(x),\(y)")
                    if moved.rgb(x, y) != base.rgb(x + shift, y) { return }
                }
            }
        }

        @Test func guidesMoveWithTheScroll() {
            let tree = T.tree(deepRows)
            let guide = RGB(Theme.guide)
            let guideX = Int(Theme.treePadding + 7)
            let base = render(tree, x: 0)
            #expect(base.rgb(guideX, midY(3)).isClose(to: guide))
            let moved = render(tree, x: 5)
            #expect(moved.rgb(guideX, midY(3)).isClose(to: background))
            #expect(moved.rgb(guideX - 5, midY(3)).isClose(to: guide))
        }

        // MARK: marker

        private var markedRows: [TreeRow] {
            [T.file(String(repeating: "W", count: 70) + ".txt", change: .modified), T.file("plain.txt")]
        }

        @Test func theMarkerStaysAtTheVisibleRightEdge() {
            let tree = T.tree(markedRows)
            let atStart = render(tree, x: 0)
            let mid = render(tree, x: 100)
            let end = render(tree, x: T.range(tree))
            let region = PixelRegion(x: markerLeft, y: top(0), width: width - markerLeft, height: 24)
            let ink = RGB(Ink.yellow.cg)
            #expect(atStart.count(near: ink, in: region, tolerance: 14) > 3)
            for other in [mid, end] {
                for y in region.y..<(region.y + region.height) {
                    for x in region.x..<(region.x + region.width) where other.rgb(x, y) != atStart.rgb(x, y) {
                        Issue.record("marker pixel \(x),\(y) differs: \(other.rgb(x, y)) vs \(atStart.rgb(x, y))")
                        return
                    }
                }
            }
        }

        @Test func aNamePassingUnderTheMarkerIsHiddenByAPatchOfTheBackground() {
            let tree = T.tree(markedRows)
            let mid = render(tree, x: 100)
            // Right of the letter, up to the edge: plain background, no name.
            #expect(mid.isUniform(background, in: PixelRegion(x: markerLeft + Int(letter.rounded(.up)) + 1, y: top(0), width: 10, height: 24)))
            // Just left of the letter: also (the patch starts 2 pt before it).
            #expect(mid.isUniform(background, in: PixelRegion(x: markerLeft - 1, y: top(0), width: 1, height: 24), tolerance: 6))
        }

        @Test func theFadeGoesFromTheNameToTheBackground() {
            let tree = T.tree(markedRows)
            let mid = render(tree, x: 100)
            // Four bands of 3 points, from far left (full name) to right next to the patch: text gets weaker, never a hard edge.
            let start = markerLeft - 2 - 12
            let bands = (0..<4).map { glow(mid, x: start + $0 * 3, row: 0, width: 3, over: background) }
            #expect(bands[0] > bands[1] && bands[1] > bands[2] && bands[2] > bands[3], "bands \(bands)")
            let clear = glow(mid, x: start - 3, row: 0, width: 3, over: background)
            #expect(clear > bands[0], "clear \(clear) vs \(bands)")
            // Fade is gradual: the first band keeps at least a third of the text strength.
            #expect(bands[0] * 3 > clear)
        }

        @Test func atTheFarRightTheEndOfTheLongestNameIsClearOfTheMarker() {
            let tree = T.tree(markedRows)
            let end = render(tree, x: T.range(tree))
            // The 14 points left of the marker hold nothing of the name, and the name does end on screen.
            #expect(end.isUniform(background, in: PixelRegion(x: markerLeft - 13, y: top(0), width: 12, height: 24), tolerance: 6))
            #expect(end.count(notNear: background, in: PixelRegion(x: markerLeft - 40, y: top(0), width: 26, height: 24)) > 20)
        }

        @Test func theLetterOfANestedRepoFolderStaysPinned() {
            let nested = TreeRow(
                id: "0|d|n", kind: .directory, depth: 1, name: String(repeating: "N", count: 70), path: "n", repoIndex: 0,
                dirMark: .modified, isNestedRepo: true)
            let tree = T.tree([nested, T.file("x")])
            let atStart = render(tree, x: 0)
            let end = render(tree, x: T.range(tree))
            let region = PixelRegion(x: markerLeft, y: top(0), width: width - markerLeft, height: 24)
            #expect(atStart.count(near: RGB(Ink.yellow.cg), in: region, tolerance: 14) > 3)
            for y in region.y..<(region.y + region.height) {
                for x in region.x..<(region.x + region.width) where end.rgb(x, y) != atStart.rgb(x, y) {
                    Issue.record("nested repo marker pixel \(x),\(y) differs")
                    return
                }
            }
            #expect(end.isUniform(background, in: PixelRegion(x: markerLeft - 13, y: top(0), width: 12, height: 24), tolerance: 6))
        }

        @Test func theDotOfAFolderStaysPinnedToo() {
            let rows = [T.dir(String(repeating: "D", count: 70), mark: .added), T.file("x")]
            let tree = T.tree(rows)
            let dot = RGB.composite(Ink.green.cg.copy(alpha: 0.85)!, over: background)
            for x in [CGFloat(0), 100, T.range(tree)] {
                let bitmap = render(tree, x: x)
                #expect(bitmap.rgb(width - 14 - 4, midY(0)).isClose(to: dot, tolerance: 4))
                #expect(bitmap.isUniform(background, in: PixelRegion(x: width - 12, y: top(0), width: 12, height: 24)))
            }
        }

        // MARK: fills

        @Test func theSelectionFillSpansTheWholeWidthWhenScrolled() {
            let rows = markedRows
            let tree = T.tree(rows)
            tree.selectedID = rows[0].id
            let selection = RGB.composite(Theme.rowSelected, over: Theme.background)
            let bitmap = render(tree, x: 100)
            // Far edges and the patch area carry the fill color, not the plain background.
            for x in [0, 1, 2, width - 1, width - 2, width - 3] {
                #expect(bitmap.rgb(x, top(0) + 1).isClose(to: selection), "x \(x)")
            }
            #expect(bitmap.isUniform(selection, in: PixelRegion(x: markerLeft + Int(letter.rounded(.up)) + 1, y: top(0), width: 10, height: 24)))
            // The row below is not filled.
            #expect(bitmap.rgb(width - 2, top(1) + 1).isClose(to: background))
        }

        @Test func theSelectedRowsFadeEndsInTheFillColorNotInThePlainBackground() {
            let rows = markedRows
            let tree = T.tree(rows)
            tree.selectedID = rows[0].id
            let selection = RGB.composite(Theme.rowSelected, over: Theme.background)
            let end = render(tree, x: T.range(tree))
            #expect(end.isUniform(selection, in: PixelRegion(x: markerLeft - 13, y: top(0), width: 12, height: 24), tolerance: 6))
        }

        @Test func theHoverFillSpansTheWholeWidthWhenScrolled() {
            let rows = markedRows
            let tree = T.tree(rows)
            tree.scroll(to: CGPoint(x: 100, y: 0))
            tree.mouse(.moved, at: CGPoint(x: 150, y: top(0) + 5), event: Event.mouse(.mouseMoved))
            let hover = RGB.composite(Theme.rowHover, over: Theme.background)
            let bitmap = Render.canvas(tree)
            #expect(bitmap.rgb(1, top(0) + 1).isClose(to: hover))
            #expect(bitmap.isUniform(hover, in: PixelRegion(x: width - 8, y: top(0), width: 8, height: 24)))
        }

        // MARK: repository rows

        @Test func repositoryRowsDoNotMove() {
            let rows = [T.repo("project"), T.dir("one"), T.file(String(repeating: "q", count: 80), depth: 2), T.repo("second", branch: "feature/x")]
            let tree = T.tree(rows, style: .changes)
            let base = render(tree, x: 0)
            let moved = render(tree, x: 90)
            #expect(T.range(tree) > 90)
            // Band row at the top, and the second one (below the gap-less list): same pixels.
            let first = PixelRegion(x: 0, y: 0, width: width, height: 8 + 28)
            func same(_ region: PixelRegion) -> Bool {
                for y in region.y..<(region.y + region.height) {
                    for x in region.x..<(region.x + region.width) where base.rgb(x, y) != moved.rgb(x, y) { return false }
                }
                return true
            }
            #expect(same(first))
            let secondTop = 8 + 28 + 24 * 2
            #expect(same(PixelRegion(x: 0, y: secondTop, width: width, height: 28)))
            // And they are not empty: the band has a name.
            #expect(moved.count(notNear: RGB.composite(Theme.band, over: Theme.background), in: PixelRegion(x: 30, y: 8, width: 100, height: 28)) > 20)
        }

        @Test func theFilesTabRootRowDoesNotMoveEither() {
            let rows = [T.repo("project"), T.file(String(repeating: "q", count: 80), depth: 1)]
            let tree = T.tree(rows, style: .files)
            let base = render(tree, x: 0)
            let moved = render(tree, x: 60)
            for y in 8..<(8 + 28) {
                for x in 0..<width where base.rgb(x, y) != moved.rgb(x, y) {
                    Issue.record("root row pixel \(x),\(y) moved")
                    return
                }
            }
        }
    }
}
