import Foundation

/// Where each file tab sits in the tab bar.
///
/// Rules (same idea as VS Code and Zed):
/// - While they fit, every tab is `fixedWidth` wide (or its natural width when its name needs more).
/// - When they do not fit, tabs shrink to their natural width.
/// - When even that does not fit, the strip scrolls sideways and the active tab is kept fully in view.
package struct TabBarLayout: Sendable, Hashable {
    package struct Frame: Sendable, Hashable {
        /// Left edge inside the strip, before scrolling.
        package var x: Double
        package var width: Double

        package var maxX: Double { x + width }
    }

    package var frames: [Frame]
    /// Total width of all tabs.
    package var contentWidth: Double
    /// How far the strip is scrolled. Always 0 when everything fits.
    package var scrollX: Double
    /// The tabs do not fit in the viewport.
    package var overflows: Bool

    package static func compute(
        naturalWidths: [Double],
        viewportWidth: Double,
        fixedWidth: Double = 150,
        activeIndex: Int?,
        scrollX: Double
    ) -> TabBarLayout {
        let viewport = max(0, viewportWidth)
        let roomy = naturalWidths.map { max(fixedWidth, $0) }
        let widths = roomy.reduce(0, +) <= viewport ? roomy : naturalWidths

        var frames: [Frame] = []
        frames.reserveCapacity(widths.count)
        var x = 0.0
        for width in widths {
            frames.append(Frame(x: x, width: width))
            x += width
        }

        let overflows = x > viewport
        var scroll = 0.0
        if overflows {
            scroll = min(max(0, scrollX), x - viewport)
            if let activeIndex, frames.indices.contains(activeIndex) {
                let active = frames[activeIndex]
                if active.x < scroll {
                    scroll = active.x
                } else if active.maxX > scroll + viewport {
                    // A tab wider than the viewport shows its start.
                    scroll = min(active.x, active.maxX - viewport)
                }
            }
        }
        return TabBarLayout(frames: frames, contentWidth: x, scrollX: scroll, overflows: overflows)
    }

    /// Index of the tab under a point given in viewport coordinates, or nil.
    package func index(atViewportX viewportX: Double) -> Int? {
        let x = viewportX + scrollX
        guard x >= 0, x < contentWidth else { return nil }
        var low = 0
        var high = frames.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if x < frames[mid].x {
                high = mid - 1
            } else if x >= frames[mid].maxX {
                low = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }
}
