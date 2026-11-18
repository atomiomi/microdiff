import AppKit
import MicroDiffCore
import MicroDiffTestSupport
import Testing
@testable import MicroDiffUI

extension UITests {
    @MainActor
    @Suite
    struct SidebarToggleRenderingTests {
        private static let repo = Fixture.changesRepo()
        private static let size = CGSize(width: 800, height: 480)

        private func render(sidebarHidden: Bool) throws -> (bitmap: Bitmap, scale: Int) {
            Render.prepareApplication()
            let controller = MainWindowController(path: Self.repo.path, defaults: nil)
            let data = try #require(
                controller.renderSnapshot(size: Self.size, sidebarTab: .changes, open: [], mode: nil, sidebarHidden: sidebarHidden))
            let bitmap = try #require(Bitmap.decode(png: data))
            return (bitmap, max(1, bitmap.width / Int(Self.size.width)))
        }

        @Test func hiddenTheTopLeftShowsTheTabBarNotTheSidebarTabs() throws {
            // With no file open the main tab bar is one dark strip; the sidebar's active tab is the window color.
            func darkStrip(_ picture: (bitmap: Bitmap, scale: Int)) -> Int {
                let region = PixelRegion(x: 0, y: 34 * picture.scale, width: 280 * picture.scale, height: 20 * picture.scale)
                return picture.bitmap.count(near: RGB(Theme.inactive), in: region)
            }
            let shown = try render(sidebarHidden: false)
            let hidden = try render(sidebarHidden: true)
            let all = 280 * 20 * hidden.scale * hidden.scale
            #expect(darkStrip(shown) < all / 2)
            #expect(darkStrip(hidden) == all)
        }

        @Test func hiddenNoSidebarLineIsLeftWhereItWas() throws {
            let hidden = try render(sidebarHidden: true)
            let column = PixelRegion(x: 288 * hidden.scale, y: 100 * hidden.scale, width: hidden.scale, height: 300 * hidden.scale)
            #expect(hidden.bitmap.count(near: RGB(Theme.line), in: column) == 0)
            let shown = try render(sidebarHidden: false)
            #expect(shown.bitmap.count(near: RGB(Theme.line), in: column) > 0)
        }
    }
}
