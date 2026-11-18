import AppKit
import MicroDiffCore
import Testing
@testable import MicroDiffUI

extension UITests {
    /// The tab strip scrolls sideways when the tabs do not fit.
    @MainActor
    @Suite
    struct TabBarScrollTests {
        private func bar(tabCount: Int, width: CGFloat = 900) -> (FileTabBarView, NSWindow) {
            let bar = FileTabBarView(frame: .zero)
            let window = hostInWindow(bar, width: width, height: 37)
            bar.update(
                tabs: (0..<tabCount).map { FileTab(title: "file\($0).swift", kind: nil, isPreview: false) },
                activeIndex: 0, mode: .diff)
            // Drawing is what ends the "scroll the active tab into view" step that follows an update.
            _ = Render.tabBar(bar)
            return (bar, window)
        }

        /// Which tab a click at `x` selects. (Near the left edge, away from the close boxes at the right edge of each tab.)
        private func tabAt(_ bar: FileTabBarView, _ window: NSWindow, x: Double) -> Int? {
            var picked: Int?
            bar.onSelect = { picked = $0 }
            bar.mouseDown(with: makeMouseDown(in: bar, at: point(x, 18), window: window))
            return picked
        }

        @Test func wheelScrollingMovesTheStripSidewaysWithinItsLimits() throws {
            let (bar, window) = bar(tabCount: 20)
            let start = try #require(tabAt(bar, window, x: 4))
            #expect(start == 0)

            // Vertical wheel: content moves left, so a later tab is under the same x.
            bar.scrollWheel(with: try #require(Event.scroll(dy: -400)))
            let scrolled = try #require(tabAt(bar, window, x: 4))
            #expect(scrolled > start)

            // Horizontal gestures work too, and the far end stops at the last tab.
            bar.scrollWheel(with: try #require(Event.scroll(dx: -100_000)))
            let end = try #require(tabAt(bar, window, x: 4))
            #expect(end >= 12)
            bar.scrollWheel(with: try #require(Event.scroll(dx: -100_000)))
            #expect(tabAt(bar, window, x: 4) == end)

            // And back: it stops at the first tab, not before it.
            bar.scrollWheel(with: try #require(Event.scroll(dy: 100_000)))
            #expect(tabAt(bar, window, x: 4) == start)
        }

        @Test func thePredominantAxisDecidesTheDirection() throws {
            let (bar, window) = bar(tabCount: 20)
            let start = try #require(tabAt(bar, window, x: 4))
            // More horizontal than vertical: the horizontal part counts.
            bar.scrollWheel(with: try #require(Event.scroll(dx: -400, dy: 30)))
            #expect(try #require(tabAt(bar, window, x: 4)) > start)
        }

        @Test func tabsThatFitDoNotScroll() throws {
            let (bar, window) = bar(tabCount: 2)
            let before = try #require(tabAt(bar, window, x: 4))
            bar.scrollWheel(with: try #require(Event.scroll(dy: -500)))
            #expect(tabAt(bar, window, x: 4) == before)
        }
    }
}
