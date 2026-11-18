import AppKit
import MicroDiffCore
import Testing
@testable import MicroDiffUI

extension UITests {
    @MainActor
    struct FileIconDrawingTests {
        private static let canvas = 48
        private static let inset = 16

        private func render(_ icon: FileIcon, size: CGFloat = 16, alpha: CGFloat = 1, background: CGColor? = nil) -> Bitmap {
            Bitmap.render(width: Self.canvas, height: Self.canvas, background: background) {
                icon.draw(in: $0, x: CGFloat(Self.inset), y: CGFloat(Self.inset), size: size, alpha: alpha)
            }
        }

        // MARK: Data

        @Test func tableHasSixtyFiveIcons() {
            #expect(FileIcon.allCases.count == 65)
            #expect(FileIcon.allCases.prefix(5) == [.file, .folder, .folderOpen, .repo, .submodule])
        }

        @Test(arguments: FileIcon.allCases)
        func everyIconParsesToPaths(icon: FileIcon) {
            let strokes = FileIconData.strokes(icon)
            #expect(!strokes.isEmpty)
            for stroke in strokes {
                let commands = SVGPath.parse(stroke.d)
                #expect(commands.count > 1, "\(icon): \(stroke.d)")
                if case .move = commands.first {} else { Issue.record("\(icon) does not start with a move") }
                // The parser stops silently at malformed input; the whole string must have been used.
                #expect(!FileIcon.cgPath(stroke.d).boundingBoxOfPath.isNull)
            }
        }

        /// A few shapes (docker, swift, ...) stroke slightly past the grid; `draw` clips them like the SVG viewBox.
        /// Their center lines must stay on the grid (hair of rounding allowed), so a stroke spills by at most half a line width.
        @Test(arguments: FileIcon.allCases)
        func pathBoundsStayInsideTheGrid(icon: FileIcon) {
            for stroke in FileIconData.strokes(icon) {
                let box = FileIcon.cgPath(stroke.d).boundingBox
                let slack: CGFloat = 0.2  // cpp reaches -0.19 on the left
                #expect(box.minX >= -slack && box.minY >= -slack, "\(icon) starts outside: \(box)")
                #expect(box.maxX <= 16 + slack && box.maxY <= 16 + slack, "\(icon) ends outside: \(box)")
                #expect(stroke.width <= 1)
            }
        }

        // MARK: Pixels

        @Test(arguments: FileIcon.allCases)
        func everyIconDrawsInsideItsSquare(icon: FileIcon) {
            let bitmap = render(icon)
            let total = bitmap.countVisible()
            #expect(total > 15, "\(icon) drew almost nothing")
            let box = PixelRegion(x: Self.inset, y: Self.inset, width: 16, height: 16)
            #expect(bitmap.countVisible(in: box) == total, "\(icon) paints outside its square")
        }

        @Test(arguments: [8.0, 12.0, 24.0, 32.0])
        func scaledIconsStayInsideTheirSquare(size: Double) {
            for icon in FileIcon.allCases {
                let bitmap = render(icon, size: CGFloat(size))
                let margin = 1
                let box = PixelRegion(
                    x: Self.inset - margin, y: Self.inset - margin, width: Int(size) + margin * 2, height: Int(size) + margin * 2)
                #expect(bitmap.countVisible(in: box) == bitmap.countVisible(), "\(icon) at \(size)")
                #expect(bitmap.countVisible() > 0, "\(icon) at \(size)")
            }
        }

        @Test(arguments: FileIcon.allCases)
        func everyTintShowsItsColor(icon: FileIcon) {
            let bitmap = render(icon, size: 32)
            for tint in Set(FileIconData.strokes(icon).map(\.tint)) {
                let color = RGB(hex: tint.hex)
                // Count solid pixels of the tint (anti-aliased edges are blends and do not count).
                let hits = bitmap.count { rgb, alpha in alpha == 255 && rgb.isClose(to: color, tolerance: 2) }
                #expect(hits > 0, "\(icon) shows no pixel of \(tint)")
            }
        }

        @Test func singleTintIconsUseOnlyThatColor() {
            for (icon, hex) in [(FileIcon.vue, 0x94c580), (.yaml, 0xe17177), (.lock, 0x6b727e), (.sass, 0xdba0cd)] as [(FileIcon, UInt32)] {
                let bitmap = render(icon)
                let wrong = bitmap.count { rgb, alpha in alpha == 255 && !rgb.isClose(to: RGB(hex: hex), tolerance: 2) }
                #expect(wrong == 0, "\(icon)")
            }
        }

        @Test func tintHexValuesAreTheOursPalette() {
            let expected: [FileIconTint: UInt32] = [
                .t: 0x848b98, .o: 0x6b727e, .b: 0x6caeef, .y: 0xe1bc77, .g: 0x94c580, .r: 0xe17177, .p: 0xd99a68,
                .m: 0xc584e0, .k: 0xdba0cd, .s: 0x6bb7d6, .sk: 0x7cc5d2, .tl: 0x6fbfb3, .mr: 0xdc8a8f, .fl: 0xd9a9a9,
                .rw: 0xd6bdb7, .lv: 0xa4a8e6,
            ]
            #expect(expected.count == FileIconTint.allCases.count)
            for tint in FileIconTint.allCases { #expect(tint.hex == expected[tint], "\(tint)") }
        }

        @Test func alphaDimsTheWholeIcon() {
            // Vue: the top edge covers y 1...2 fully, so pixel (x 3, y 1) is solid at alpha 1.
            let probe = (x: Self.inset + 3, y: Self.inset + 1)
            let full = render(.vue).pixel(probe.x, probe.y)
            let half = render(.vue, alpha: 0.5).pixel(probe.x, probe.y)
            #expect(full.alpha == 255)
            #expect(abs(half.alpha - 128) <= 2)
            #expect(render(.vue, alpha: 0).countVisible() == 0)
        }

        @Test func alphaDoesNotDoubleDarkenOverlaps() {
            // typescript has a stroke crossing its box edge region; every solid pixel must be dimmed equally
            // (one layer), never darker where two strokes overlap.
            let half = render(.typescript, alpha: 0.5)
            let maxAlpha = half.count { _, alpha in alpha > 130 }
            #expect(maxAlpha == 0)
        }

        @Test func sixteenPixelIconsAreSharp() {
            // Box edge of typescript runs along y = 1.5 with width 1: whole pixels, no blend.
            let bitmap = render(.typescript)
            for x in 6...9 {
                let top = bitmap.pixel(Self.inset + x, Self.inset + 1)
                #expect(top.alpha == 255)
                #expect(bitmap.pixel(Self.inset + x, Self.inset).alpha == 0)
            }
        }

        // MARK: Stroke exceptions

        @Test func cssSecondPathIsThinner() {
            let strokes = FileIconData.strokes(.css)
            #expect(strokes.count == 2)
            #expect(strokes[0].width == 1)
            #expect(strokes[1].width == 0.814)
            #expect(strokes.allSatisfy { $0.cap == .round && $0.join == .round })
        }

        @Test func zipHasButtCapsAndRoundJoins() {
            for stroke in FileIconData.strokes(.zip) {
                #expect(stroke.width == 1)
                #expect(stroke.cap == .butt)
                #expect(stroke.join == .round)
            }
        }

        @Test func csharpHasButtCapsAndMiterJoins() {
            for stroke in FileIconData.strokes(.csharp) {
                #expect(stroke.width == 1)
                #expect(stroke.cap == .butt)
                #expect(stroke.join == .miter)
            }
        }

        @Test func everyOtherIconUsesTheDefaultStroke() {
            for icon in FileIcon.allCases where icon != .css && icon != .zip && icon != .csharp {
                for stroke in FileIconData.strokes(icon) {
                    #expect(stroke.width == 1 && stroke.cap == .round && stroke.join == .round, "\(icon)")
                }
            }
        }

        @Test func submoduleIsFolderCornerPlusArrow() {
            let strokes = FileIconData.strokes(.submodule)
            #expect(strokes.map(\.tint) == [.t, .b])
            #expect(strokes[0].d == FileIconData.strokes(.repo)[0].d)
            #expect(strokes[1].d == "M8.5 12.5h6m-2-2 2 2-2 2")
        }

        @Test func repeatedDrawsGiveTheSamePixels() {
            let a = render(.python)
            let b = render(.python)
            #expect(a.count(in: nil) { _, alpha in alpha > 0 } == b.countVisible())
        }
    }
}
