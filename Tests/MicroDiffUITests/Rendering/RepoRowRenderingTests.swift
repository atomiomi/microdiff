import AppKit
import MicroDiffCore
import Testing
@testable import MicroDiffUI

extension UITests {
    /// Repository rows: name on the left, branch on the right, nothing overlapping at any sidebar width.
    @MainActor
    struct RepoRowRenderingTests {
        private static let longName = "storefront-pricing-service"
        private static let longBranch = "feature/checkout-saved-carts"
        /// Left edge of the name: padding, repository icon, 6 pt.
        private let textX = Int(Theme.treePadding + Theme.iconSize + 6)

        private func repoRow(_ name: String, branch: String? = nil, sync: RepoSync? = nil) -> TreeRow {
            TreeRow(id: "0|r", kind: .repo, depth: 0, name: name, path: "", repoIndex: 0, branch: branch, sync: sync)
        }

        private func tree(_ rows: [TreeRow], width: Int) -> TreeView {
            let view = TreeView(frame: NSRect(x: 0, y: 0, width: width, height: 120))
            view.style = .changes
            view.setRows(rows)
            return view
        }

        private func render(_ row: TreeRow, width: Int) -> Bitmap {
            Render.canvas(tree([row], width: width))
        }

        private func textWidth(_ text: String, branch: Bool) -> Int {
            Int(TextCache.makeLine([TextRun(text, .fg)], branch ? .small : .regular).width.rounded(.up))
        }

        /// Runs of columns with ink in the row (the first row is the band at y 8...36), as closed ranges, left to right.
        /// Ink is anything that is not the band color; runs closer than `gap` columns are one.
        private func inkRuns(_ bitmap: Bitmap, from x0: Int, to x1: Int? = nil, gap: Int = 6) -> [ClosedRange<Int>] {
            let band = bitmap.rgb(2, 10)
            var runs: [ClosedRange<Int>] = []
            for x in x0..<(x1 ?? bitmap.width) {
                let ink = bitmap.count(notNear: band, in: PixelRegion(x: x, y: 8, width: 1, height: 28), tolerance: 6) > 0
                guard ink else { continue }
                if let last = runs.last, x - last.upperBound <= gap {
                    runs[runs.count - 1] = last.lowerBound...x
                } else {
                    runs.append(x...x)
                }
            }
            return runs
        }

        @Test(arguments: [288, 220, 160])
        func theNameEndsLeftOfTheBranchIconAndTheBranchStaysInItsShare(width: Int) {
            let bitmap = render(repoRow(Self.longName, branch: Self.longBranch), width: width)
            let runs = inkRuns(bitmap, from: textX)
            #expect(runs.count == 2, "a name, then the icon with the branch: \(runs)")
            guard runs.count == 2 else { return }
            let (name, branch) = (runs[0], runs[1])
            let budget = Double(width) - Double(Theme.treePadding) - Double(textX) - 24
            let nameFull = Double(textWidth(Self.longName, branch: false)), branchFull = Double(textWidth(Self.longBranch, branch: true))
            let shares = RepoRowText.shares(budget: budget, name: nameFull, branch: branchFull)
            let edge = width - Int(Theme.treePadding)
            #expect(name.upperBound < branch.lowerBound - 8 + 2, "8 pt between the name and the icon")
            #expect(name.upperBound <= textX + Int(shares.name.rounded(.up)))
            // The icon (12) and 4 pt come before the text, which is at most its share wide.
            #expect(branch.lowerBound >= edge - Int(shares.branch.rounded(.up)) - 16 - 1)
            #expect(branch.upperBound <= edge)
        }

        @Test func theExampleAtTheDefaultWidthDrawsTheMiddleShortenedTexts() {
            let long = render(repoRow(Self.longName, branch: Self.longBranch), width: 288)
            let short = render(repoRow("storefr…ervice", branch: "feature/…d-carts"), width: 288)
            let region = PixelRegion(x: 0, y: 8, width: 288, height: 28)
            #expect(long.count(in: region) { _, _ in true } == short.count(in: region) { _, _ in true })
            var different = 0
            for y in 8..<36 {
                for x in 0..<288 where long.rgb(x, y) != short.rgb(x, y) { different += 1 }
            }
            #expect(different == 0)
        }

        @Test func aRowThatFitsIsDrawnInFullAsBefore() {
            let bitmap = render(repoRow("micro-diff", branch: "main"), width: 288)
            let runs = inkRuns(bitmap, from: textX)
            #expect(runs.count == 2)
            let nameWidth = textWidth("micro-diff", branch: false)
            #expect(runs[0].lowerBound >= textX && runs[0].upperBound <= textX + nameWidth)
            #expect(runs[0].upperBound >= textX + nameWidth - 3, "all of it")
            #expect(runs[1].upperBound <= 288 - Int(Theme.treePadding))
        }

        @Test func aRowWithoutABranchIsCutAtTheEndAsBefore() {
            let bitmap = render(repoRow(String(repeating: "long-name-", count: 8)), width: 160)
            let runs = inkRuns(bitmap, from: textX, gap: 30)
            #expect(runs.count == 1)
            #expect(runs[0].upperBound <= 160 - Int(Theme.treePadding))
            #expect(runs[0].upperBound >= 160 - Int(Theme.treePadding) - 10, "uses the room it has")
        }

        // MARK: Tooltip

        @Test func theToolTipHasTheFullTextOfAShortenedRow() {
            let view = tree([repoRow(Self.longName, branch: Self.longBranch)], width: 288)
            #expect(view.toolTip(at: CGPoint(x: 60, y: 20)) == "\(Self.longName)  ·  \(Self.longBranch)")
        }

        @Test func aRowThatFitsHasNoToolTip() {
            let view = tree([repoRow("micro-diff", branch: "main")], width: 288)
            #expect(view.toolTip(at: CGPoint(x: 60, y: 20)) == nil)
        }

        @Test func onlyAShortenedBranchOrNameAlreadyGivesTheToolTip() {
            let view = tree([repoRow("app", branch: Self.longBranch + Self.longBranch)], width: 288)
            #expect(view.toolTip(at: CGPoint(x: 60, y: 20)) == "app  ·  \(Self.longBranch + Self.longBranch)")
        }

        @Test func rowsWithoutABranchAndOtherRowsHaveNoToolTip() {
            let file = TreeRow(id: "0|f|a", kind: .file, depth: 1, name: String(repeating: "x", count: 80), path: "a", repoIndex: 0)
            let view = tree([repoRow(String(repeating: "n", count: 80)), file], width: 288)
            #expect(view.toolTip(at: CGPoint(x: 60, y: 20)) == nil)
            #expect(view.toolTip(at: CGPoint(x: 60, y: 8 + 28 + 12)) == nil)
            #expect(view.toolTip(at: CGPoint(x: 60, y: 2)) == nil, "above the rows")
        }

        @Test func theToolTipFollowsTheWidth() {
            let view = tree([repoRow("service-api", branch: "release/2024-spring")], width: 288)
            #expect(view.toolTip(at: CGPoint(x: 60, y: 20)) == nil)
            view.frame = NSRect(x: 0, y: 0, width: 160, height: 120)
            view.layoutSubtreeIfNeeded()
            #expect(view.toolTip(at: CGPoint(x: 60, y: 20)) == "service-api  ·  release/2024-spring")
        }

        @Test func theViewsToolTipIsAskedByPositionAndFollowsTheRowsAndTheScroll() {
            let rows = (0..<12).map { repoRow($0 == 0 ? Self.longName : "repo-\($0)", branch: $0 == 0 ? Self.longBranch : "main") }
            let view = tree(rows, width: 288)
            // 8 pt of padding, then 28 pt bands with 10 pt between them: the first row is at y 8...36 on screen.
            #expect(view.toolTip(atCanvasPoint: CGPoint(x: 60, y: 20)) == "\(Self.longName)  ·  \(Self.longBranch)")
            #expect(view.toolTip(atCanvasPoint: CGPoint(x: 60, y: 8 + 28 + 10 + 12)) == nil)
            view.scroll(to: CGPoint(x: 0, y: 38))
            #expect(view.toolTip(atCanvasPoint: CGPoint(x: 60, y: 20)) == nil, "the first row has scrolled away")
            view.scroll(to: .zero)
            view.setRows([repoRow("app", branch: "main")])
            #expect(view.toolTip(atCanvasPoint: CGPoint(x: 60, y: 20)) == nil)
        }

        // MARK: Marks

        private let pull = RepoSync(upstream: "origin/main", pull: true, push: false, checkedAt: nil)
        private let push = RepoSync(upstream: "origin/main", pull: false, push: true)
        private let both = RepoSync(upstream: "origin/main", pull: true, push: true)

        private func arrowWidth(_ text: String) -> CGFloat {
            TextCache.makeLine([TextRun(text, .red)], .small).width
        }

        /// Pixels near the ink in `x0...x1` of the row.
        private func count(_ ink: Ink, _ bitmap: Bitmap, _ x0: Int, _ x1: Int) -> Int {
            bitmap.count(near: RGB(ink.cg), in: PixelRegion(x: x0, y: 8, width: max(0, x1 - x0 + 1), height: 28), tolerance: 25)
        }

        private func edge(_ width: Int) -> Int { width - Int(Theme.treePadding) }

        @Test func aPullMarkIsARedDownArrowAtTheRightEdge() {
            let bitmap = render(repoRow("app", branch: "main", sync: pull), width: 288)
            let right = edge(288), arrow = Int(arrowWidth("↓").rounded(.up))
            #expect(count(.red, bitmap, right - arrow - 1, right + 1) > 3)
            #expect(count(.red, bitmap, textX, right - arrow - 3) == 0, "nothing else is red")
            #expect(count(.green, bitmap, textX, 287) == 0)
        }

        @Test func aPushMarkIsAGreenUpArrowAtTheRightEdge() {
            let bitmap = render(repoRow("app", branch: "main", sync: push), width: 288)
            let right = edge(288), arrow = Int(arrowWidth("↑").rounded(.up))
            #expect(count(.green, bitmap, right - arrow - 1, right + 1) > 3)
            #expect(count(.green, bitmap, textX, right - arrow - 3) == 0)
            #expect(count(.red, bitmap, textX, 287) == 0)
        }

        @Test func bothMarksSitSideBySidePushOnTheEdgeAndASpaceBetween() {
            let bitmap = render(repoRow("app", branch: "main", sync: both), width: 288)
            let right = edge(288)
            let up = Int(arrowWidth("↑").rounded(.up)), down = Int(arrowWidth("↓").rounded(.up)), space = Int(arrowWidth(" ").rounded())
            let pushLeft = right - up
            let pullRight = pushLeft - space
            #expect(count(.green, bitmap, pushLeft - 1, right + 1) > 3)
            #expect(count(.red, bitmap, pullRight - down - 1, pullRight + 1) > 3)
            #expect(count(.red, bitmap, pushLeft - 1, 287) == 0)
            #expect(count(.green, bitmap, textX, pullRight + 1) == 0)
            let columns = inkRuns(bitmap, from: pullRight - down - 1, gap: 1)
            #expect(columns.count == 2, "one arrow, a space, the other: \(columns)")
        }

        @Test func theBranchEndsEightPointsBeforeTheMarks() {
            for sync in [pull, push, both] {
                let bitmap = render(repoRow("app", branch: "main", sync: sync), width: 288)
                let marks = 8 + (sync.pull ? arrowWidth("↓") : 0) + (sync.push ? arrowWidth("↑") : 0) + (sync.pull && sync.push ? arrowWidth(" ") : 0)
                let left = edge(288) - Int(marks.rounded(.up))
                #expect(inkRuns(bitmap, from: textX, to: left + 1).count == 2, "name, then icon and branch")
                // Where the gap is, the row is empty.
                let gap = inkRuns(bitmap, from: left + 1, to: left + 7, gap: 1)
                #expect(gap.isEmpty, "\(gap)")
            }
        }

        @Test(arguments: [288, 160])
        func theMarksTakeTheirRoomFromTheNameAndTheBranchAndNothingOverlaps(width: Int) {
            let sync = both
            let bitmap = render(repoRow(Self.longName, branch: Self.longBranch, sync: sync), width: width)
            let marks = Int((8 + arrowWidth("↓") + arrowWidth("↑") + arrowWidth(" ")).rounded(.up))
            let marksLeft = edge(width) - marks
            let runs = inkRuns(bitmap, from: textX, to: marksLeft + 1)
            #expect(runs.count == 2, "a name, then the icon with the branch: \(runs)")
            guard runs.count == 2 else { return }
            let budget = Double(width) - Double(Theme.treePadding) - Double(textX) - 24 - Double(marks)
            let shares = RepoRowText.shares(
                budget: budget, name: Double(textWidth(Self.longName, branch: false)), branch: Double(textWidth(Self.longBranch, branch: true)))
            #expect(runs[0].upperBound <= textX + Int(shares.name.rounded(.up)))
            #expect(runs[0].upperBound < runs[1].lowerBound - 8 + 2)
            #expect(runs[1].lowerBound >= marksLeft - Int(shares.branch.rounded(.up)) - 16 - 1)
            #expect(runs[1].upperBound <= marksLeft + 1)
            // The marks are whole and in place.
            #expect(count(.red, bitmap, marksLeft + 8, edge(width) - 1) > 3)
            #expect(count(.green, bitmap, marksLeft + 8, edge(width) + 1) > 3)
            // Less room than without marks.
            let plain = render(repoRow(Self.longName, branch: Self.longBranch), width: width)
            let plainRuns = inkRuns(plain, from: textX)
            #expect(runs[0].upperBound <= plainRuns[0].upperBound)
        }

        @Test func theShortenedTextsAreDrawnLikeTextsThatFitInTheSameRoom() {
            let width = 288
            let marks = 8 + arrowWidth("↓") + arrowWidth("↑") + arrowWidth(" ")
            let budget = Double(width) - Double(Theme.treePadding) - Double(textX) - 24 - Double(marks)
            let fit = RepoRowText.fit(
                name: Self.longName, branch: Self.longBranch, budget: budget,
                measureName: { Double(TextCache.makeLine([TextRun($0, .fg)], .regular).width) },
                measureBranch: { Double(TextCache.makeLine([TextRun($0, .dim)], .small).width) })
            #expect(fit.isShortened)
            let long = render(repoRow(Self.longName, branch: Self.longBranch, sync: both), width: width)
            let short = render(repoRow(fit.name, branch: fit.branch, sync: both), width: width)
            var different = 0
            for y in 8..<36 {
                for x in 0..<width where long.rgb(x, y) != short.rgb(x, y) { different += 1 }
            }
            #expect(different == 0)
        }

        @Test func withoutMarksTheRowIsDrawnExactlyAsBefore() {
            let none = RepoSync(upstream: "origin/main", pull: false, push: false)
            for (name, branch) in [("micro-diff", "main"), (Self.longName, Self.longBranch)] {
                for width in [288, 160] {
                    let plain = render(repoRow(name, branch: branch), width: width)
                    let empty = render(repoRow(name, branch: branch, sync: none), width: width)
                    var different = 0
                    for y in 0..<120 {
                        for x in 0..<width where plain.rgb(x, y) != empty.rgb(x, y) { different += 1 }
                    }
                    #expect(different == 0, "\(name) at \(width)")
                }
            }
        }

        @Test func aHeaderAloneLooksLikeTheHeaderOfASectionWithFiles() {
            let file = TreeRow(id: "1|f|a.txt", kind: .file, depth: 1, name: "a.txt", path: "a.txt", repoIndex: 0)
            for width in [288, 160] {
                let alone = Render.canvas(tree([repoRow(Self.longName, branch: Self.longBranch, sync: both)], width: width))
                let withFile = Render.canvas(tree([repoRow(Self.longName, branch: Self.longBranch, sync: both), file], width: width))
                var different = 0
                for y in 0..<36 {
                    for x in 0..<width where alone.rgb(x, y) != withFile.rgb(x, y) { different += 1 }
                }
                #expect(different == 0, "the band and what is in it, at \(width)")
            }
        }

        // MARK: Tooltip lines

        private let clock = Date(timeIntervalSince1970: 5_000_000)

        private func tip(_ row: TreeRow, width: Int = 288) -> String? {
            tree([row], width: width).toolTip(at: CGPoint(x: 60, y: 20), now: clock)
        }

        @Test func theToolTipHasOnlyTheLinesThatApplyInOrder() {
            let checked = RepoSync(upstream: "origin/main", pull: true, push: true, checkedAt: clock.addingTimeInterval(-120))
            let full = "\(Self.longName)  ·  \(Self.longBranch)"
            let pullLine = "to pull: new commits on origin/main (checked 2 minutes ago)"
            let pushLine = "to push: commits that are not on origin/main yet"
            #expect(tip(repoRow(Self.longName, branch: Self.longBranch, sync: checked)) == [full, pullLine, pushLine].joined(separator: "\n"))
            #expect(tip(repoRow("app", branch: "main", sync: checked)) == [pullLine, pushLine].joined(separator: "\n"))
            #expect(tip(repoRow(Self.longName, branch: Self.longBranch)) == full)
            #expect(tip(repoRow("app", branch: "main", sync: push)) == pushLine)
            #expect(tip(repoRow("app", branch: "main", sync: pull)) == "to pull: new commits on origin/main", "no check, no bracket")
            #expect(tip(repoRow(Self.longName, branch: Self.longBranch, sync: push)) == [full, pushLine].joined(separator: "\n"))
            #expect(tip(repoRow("app", branch: "main")) == nil)
        }

        @Test func theToolTipUsesTheClockItIsAskedWith() {
            let row = repoRow("app", branch: "main", sync: RepoSync(upstream: "origin/dev", pull: true, push: false, checkedAt: clock))
            let view = tree([row], width: 288)
            #expect(view.toolTip(at: CGPoint(x: 60, y: 20), now: clock) == "to pull: new commits on origin/dev (checked just now)")
            #expect(view.toolTip(at: CGPoint(x: 60, y: 20), now: clock.addingTimeInterval(3 * 3600)) ==
                "to pull: new commits on origin/dev (checked 3 hours ago)")
        }
    }
}
