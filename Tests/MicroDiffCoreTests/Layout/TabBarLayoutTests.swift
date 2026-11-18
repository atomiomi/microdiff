import MicroDiffCore
import Testing

@Suite("TabBarLayout")
struct TabBarLayoutTests {
    private func layout(
        _ widths: [Double], viewport: Double, fixed: Double = 150, active: Int? = nil, scroll: Double = 0
    ) -> TabBarLayout {
        TabBarLayout.compute(naturalWidths: widths, viewportWidth: viewport, fixedWidth: fixed, activeIndex: active, scrollX: scroll)
    }

    private func xs(_ layout: TabBarLayout) -> [Double] { layout.frames.map(\.x) }
    private func widths(_ layout: TabBarLayout) -> [Double] { layout.frames.map(\.width) }

    /// The tab is completely inside the visible part of the strip.
    private func isFullyVisible(_ layout: TabBarLayout, _ index: Int, viewport: Double) -> Bool {
        let frame = layout.frames[index]
        return frame.x >= layout.scrollX && frame.maxX <= layout.scrollX + viewport
    }

    // MARK: widths

    @Test func tabsThatFitAreAllTheFixedWidth() {
        let result = layout([80, 90, 100], viewport: 600)
        #expect(widths(result) == [150, 150, 150])
        #expect(xs(result) == [0, 150, 300])
        #expect(result.contentWidth == 450)
        #expect(!result.overflows)
        #expect(result.scrollX == 0)
    }

    @Test func aLongNameGetsItsNaturalWidthWhileOthersStayFixed() {
        let result = layout([80, 220, 100], viewport: 800)
        #expect(widths(result) == [150, 220, 150])
        #expect(xs(result) == [0, 150, 370])
        #expect(result.contentWidth == 520)
        #expect(!result.overflows)
    }

    @Test func tabsSwitchToNaturalWidthsWhenFixedWidthsDoNotFit() {
        // Fixed would need 600, natural needs 340.
        let result = layout([80, 90, 100, 70], viewport: 380)
        #expect(widths(result) == [80, 90, 100, 70])
        #expect(xs(result) == [0, 80, 170, 270])
        #expect(result.contentWidth == 340)
        #expect(!result.overflows)
        #expect(result.scrollX == 0)
    }

    @Test func fixedWidthsThatFitExactlyAreUsed() {
        let result = layout([10, 20], viewport: 300)
        #expect(widths(result) == [150, 150])
        #expect(!result.overflows)
    }

    @Test func fixedWidthsOnePointTooWideFallBackToNaturalWidths() {
        let result = layout([10, 20], viewport: 299)
        #expect(widths(result) == [10, 20])
    }

    @Test func naturalWidthsThatFitExactlyDoNotOverflow() {
        let result = layout([100, 100, 100], viewport: 300)
        #expect(widths(result) == [100, 100, 100])
        #expect(!result.overflows)
        #expect(result.scrollX == 0)
    }

    @Test func naturalWidthsOnePointTooWideOverflow() {
        let result = layout([100, 100, 101], viewport: 300)
        #expect(result.overflows)
        #expect(result.contentWidth == 301)
    }

    @Test func customFixedWidth() {
        let result = layout([30, 60], viewport: 400, fixed: 100)
        #expect(widths(result) == [100, 100])
        let wide = layout([30, 160], viewport: 400, fixed: 100)
        #expect(widths(wide) == [100, 160])
    }

    @Test func framesAreContiguousAndStartAtZero() {
        let result = layout([120, 30, 400, 75], viewport: 200)
        #expect(result.frames.first?.x == 0)
        for (left, right) in zip(result.frames, result.frames.dropFirst()) {
            #expect(left.maxX == right.x)
        }
        #expect(result.frames.last?.maxX == result.contentWidth)
    }

    @Test func frameMaxXIsXPlusWidth() {
        let frame = layout([30], viewport: 100, fixed: 30).frames[0]
        #expect(frame.maxX == frame.x + frame.width)
        #expect(frame.maxX == 30)
    }

    // MARK: scrolling

    @Test func overflowingStripReportsOverflowAndContentWidth() {
        let result = layout([200, 200, 200], viewport: 450)
        #expect(result.overflows)
        #expect(result.contentWidth == 600)
        #expect(widths(result) == [200, 200, 200])
    }

    @Test func scrollIsClampedToTheContentRange() {
        #expect(layout([200, 200, 200], viewport: 450, scroll: 1000).scrollX == 150)
        #expect(layout([200, 200, 200], viewport: 450, scroll: -50).scrollX == 0)
        #expect(layout([200, 200, 200], viewport: 450, scroll: 150).scrollX == 150)
        #expect(layout([200, 200, 200], viewport: 450, scroll: 100).scrollX == 100)
    }

    @Test func noActiveTabKeepsTheGivenScrollClamped() {
        #expect(layout([200, 200, 200, 200], viewport: 300, active: nil, scroll: 123).scrollX == 123)
        #expect(layout([200, 200, 200, 200], viewport: 300, active: nil, scroll: 9999).scrollX == 500)
    }

    @Test func scrollIsZeroWhenEverythingFits() {
        #expect(layout([100, 100], viewport: 500, scroll: 300).scrollX == 0)
        #expect(layout([100, 100], viewport: 500, active: 1, scroll: 300).scrollX == 0)
    }

    @Test func activeTabLeftOfTheViewportIsBroughtIntoView() {
        let result = layout([200, 200, 200, 200, 200], viewport: 400, active: 1, scroll: 300)
        #expect(result.scrollX == 200)
        #expect(isFullyVisible(result, 1, viewport: 400))
    }

    @Test func activeTabPartlyLeftOfTheViewportIsBroughtFullyIntoView() {
        let result = layout([200, 200, 200, 200, 200], viewport: 400, active: 1, scroll: 250)
        #expect(result.scrollX == 200)
    }

    @Test func activeTabRightOfTheViewportIsBroughtIntoViewAtTheRightEdge() {
        let result = layout([200, 200, 200, 200, 200], viewport: 400, active: 3, scroll: 0)
        #expect(result.scrollX == 400)
        #expect(isFullyVisible(result, 3, viewport: 400))
    }

    @Test func activeTabPartlyRightOfTheViewportIsBroughtFullyIntoView() {
        let result = layout([200, 200, 200, 200, 200], viewport: 400, active: 2, scroll: 100)
        #expect(result.scrollX == 200)
        #expect(isFullyVisible(result, 2, viewport: 400))
    }

    @Test func activeTabAlreadyInViewDoesNotMoveTheStrip() {
        let result = layout([200, 200, 200, 200, 200], viewport: 400, active: 2, scroll: 200)
        #expect(result.scrollX == 200)
        let touching = layout([200, 200, 200, 200, 200], viewport: 400, active: 1, scroll: 200)
        #expect(touching.scrollX == 200)
    }

    @Test func firstAndLastTabScrollToTheEnds() {
        #expect(layout([200, 200, 200, 200, 200], viewport: 400, active: 0, scroll: 600).scrollX == 0)
        #expect(layout([200, 200, 200, 200, 200], viewport: 400, active: 4, scroll: 0).scrollX == 600)
    }

    @Test func activeIndexOutOfRangeIsIgnored() {
        #expect(layout([200, 200, 200], viewport: 300, active: 7, scroll: 120).scrollX == 120)
        #expect(layout([200, 200, 200], viewport: 300, active: -1, scroll: 120).scrollX == 120)
    }

    @Test func tabWiderThanTheViewportShowsItsStart() {
        let widths: [Double] = [300, 900, 300]
        #expect(layout(widths, viewport: 400, active: 1, scroll: 0).scrollX == 300)
        // Scrolled past the start: back to the start.
        #expect(layout(widths, viewport: 400, active: 1, scroll: 1000).scrollX == 300)
        // Already at the start: stays.
        #expect(layout(widths, viewport: 400, active: 1, scroll: 300).scrollX == 300)
        // Scrolled to the right of the tab's start but inside it: back to the start.
        #expect(layout(widths, viewport: 400, active: 1, scroll: 500).scrollX == 300)
    }

    @Test func wideFirstTabShowsItsStart() {
        let result = layout([900, 100], viewport: 400, active: 0, scroll: 300)
        #expect(result.scrollX == 0)
    }

    @Test func tabExactlyAsWideAsTheViewportFillsIt() {
        let result = layout([100, 400, 100], viewport: 400, active: 1, scroll: 0)
        #expect(result.scrollX == 100)
        #expect(isFullyVisible(result, 1, viewport: 400))
    }

    // MARK: degenerate input

    @Test func zeroTabs() {
        let result = layout([], viewport: 500, active: 0, scroll: 40)
        #expect(result.frames.isEmpty)
        #expect(result.contentWidth == 0)
        #expect(result.scrollX == 0)
        #expect(!result.overflows)
        #expect(result.index(atViewportX: 0) == nil)
        #expect(result.index(atViewportX: 100) == nil)
    }

    @Test func zeroTabsInAZeroWidthViewport() {
        let result = layout([], viewport: 0)
        #expect(!result.overflows)
        #expect(result.contentWidth == 0)
    }

    @Test func zeroWidthViewportOverflowsAndShowsTheStartOfTheActiveTab() {
        let result = layout([100, 100, 100], viewport: 0, active: 1, scroll: 0)
        #expect(result.overflows)
        #expect(widths(result) == [100, 100, 100])
        #expect(result.scrollX == 100)
    }

    @Test func negativeViewportBehavesLikeZero() {
        let negative = layout([100, 100, 100], viewport: -50, active: 2, scroll: 40)
        let zero = layout([100, 100, 100], viewport: 0, active: 2, scroll: 40)
        #expect(negative == zero)
        #expect(negative.overflows)
        #expect(negative.scrollX >= 0 && negative.scrollX <= negative.contentWidth)
    }

    @Test func negativeViewportWithoutTabsIsHarmless() {
        let result = layout([], viewport: -10, active: nil, scroll: -5)
        #expect(result.scrollX == 0)
        #expect(!result.overflows)
    }

    @Test func singleTab() {
        let fits = layout([40], viewport: 300, active: 0)
        #expect(widths(fits) == [150])
        let tooWide = layout([500], viewport: 300, active: 0, scroll: 200)
        #expect(widths(tooWide) == [500])
        #expect(tooWide.overflows)
        #expect(tooWide.scrollX == 0)
    }

    @Test func zeroWidthNaturalTabsDoNotBreakTheStrip() {
        let result = layout([0, 0, 0], viewport: 100, active: 1)
        #expect(widths(result) == [0, 0, 0])
        #expect(!result.overflows)
        #expect(result.scrollX == 0)
        #expect(widths(layout([0, 0, 0], viewport: 1000)) == [150, 150, 150])
    }

    // MARK: hit testing

    @Test func hitTestInsideEachTab() {
        let result = layout([80, 90, 100], viewport: 600)
        #expect(result.index(atViewportX: 1) == 0)
        #expect(result.index(atViewportX: 75) == 0)
        #expect(result.index(atViewportX: 200) == 1)
        #expect(result.index(atViewportX: 400) == 2)
    }

    @Test func hitTestOnBoundariesBelongsToTheTabOnTheRight() {
        let result = layout([80, 90, 100], viewport: 600)
        #expect(result.index(atViewportX: 0) == 0)
        #expect(result.index(atViewportX: 149.999) == 0)
        #expect(result.index(atViewportX: 150) == 1)
        #expect(result.index(atViewportX: 299.999) == 1)
        #expect(result.index(atViewportX: 300) == 2)
        #expect(result.index(atViewportX: 449.999) == 2)
    }

    @Test func hitTestBeforeTheFirstAndAfterTheLastTab() {
        let result = layout([80, 90, 100], viewport: 600)
        #expect(result.index(atViewportX: -0.001) == nil)
        #expect(result.index(atViewportX: -100) == nil)
        #expect(result.index(atViewportX: 450) == nil)
        #expect(result.index(atViewportX: 599) == nil)
        #expect(result.index(atViewportX: 10_000) == nil)
    }

    @Test func hitTestWithAScrollOffset() {
        let result = layout([200, 200, 200, 200], viewport: 300, active: nil, scroll: 250)
        #expect(result.scrollX == 250)
        #expect(result.index(atViewportX: 0) == 1)
        #expect(result.index(atViewportX: 149) == 1)
        #expect(result.index(atViewportX: 150) == 2)
        #expect(result.index(atViewportX: 299) == 2)
    }

    @Test func hitTestAtTheEndOfAScrolledStrip() {
        let result = layout([200, 200, 200, 200], viewport: 300, active: 3)
        #expect(result.scrollX == 500)
        #expect(result.index(atViewportX: 299) == 3)
        #expect(result.index(atViewportX: 0) == 2)
        #expect(result.index(atViewportX: 300) == nil)
    }

    @Test func hitTestFindsEveryTabInALongStrip() {
        let naturals = (0..<200).map { Double(40 + $0 % 7 * 13) }
        let result = layout(naturals, viewport: 500)
        for (index, frame) in result.frames.enumerated() {
            #expect(result.index(atViewportX: frame.x - result.scrollX) == index)
            #expect(result.index(atViewportX: frame.x + frame.width / 2 - result.scrollX) == index)
            #expect(result.index(atViewportX: frame.maxX - 0.5 - result.scrollX) == index)
        }
    }

    @Test func hitTestSkipsZeroWidthTabs() {
        let collapsed = layout([50, 0, 50], viewport: 80)
        #expect(widths(collapsed) == [50, 0, 50])
        #expect(collapsed.index(atViewportX: 49) == 0)
        #expect(collapsed.index(atViewportX: 50) == 2)
    }

    // MARK: properties over many inputs

    @Test func invariantsHoldForRandomInputs() {
        var rng = SeededGenerator(seed: 42)
        for _ in 0..<5000 {
            let count = Int.random(in: 0...12, using: &rng)
            let naturals = (0..<count).map { _ in Double(Int.random(in: 20...400, using: &rng)) }
            let viewport = Double(Int.random(in: -50...1500, using: &rng))
            let active: Int? = Bool.random(using: &rng) ? Int.random(in: -2...(count + 2), using: &rng) : nil
            let scroll = Double(Int.random(in: -300...3000, using: &rng))
            let result = layout(naturals, viewport: viewport, active: active, scroll: scroll)
            let effective = max(0, viewport)
            let context = "naturals \(naturals) viewport \(viewport) active \(String(describing: active)) scroll \(scroll)"

            #expect(result.frames.count == count, "\(context)")
            #expect(result.contentWidth == result.frames.reduce(0) { $0 + $1.width }, "\(context)")
            #expect(result.overflows == (result.contentWidth > effective), "\(context)")
            #expect(result.scrollX >= 0, "\(context)")
            #expect(result.scrollX <= max(0, result.contentWidth - effective), "\(context)")
            if !result.overflows { #expect(result.scrollX == 0, "\(context)") }
            for (frame, natural) in zip(result.frames, naturals) {
                #expect(frame.width >= natural, "\(context)")
            }
            for (left, right) in zip(result.frames, result.frames.dropFirst()) {
                #expect(left.maxX == right.x, "\(context)")
            }
            if let active, result.frames.indices.contains(active) {
                let frame = result.frames[active]
                if frame.width <= effective {
                    #expect(isFullyVisible(result, active, viewport: effective), "\(context)")
                } else {
                    #expect(result.scrollX == frame.x, "\(context)")
                }
            }
        }
    }

    @Test func hitTestAgreesWithFramesForRandomPoints() {
        var rng = SeededGenerator(seed: 7)
        for _ in 0..<2000 {
            let count = Int.random(in: 0...10, using: &rng)
            let naturals = (0..<count).map { _ in Double(Int.random(in: 20...300, using: &rng)) }
            let viewport = Double(Int.random(in: 100...900, using: &rng))
            let result = layout(naturals, viewport: viewport, active: count == 0 ? nil : Int.random(in: 0..<count, using: &rng))
            let point = Double(Int.random(in: -100...1200, using: &rng)) / 2
            let content = point + result.scrollX
            let expected = result.frames.firstIndex { content >= $0.x && content < $0.maxX }
            #expect(result.index(atViewportX: point) == expected, "naturals \(naturals) viewport \(viewport) point \(point)")
        }
    }
}
