import CoreGraphics
import MicroDiffCore
import Testing
@testable import MicroDiffUI

extension UITests {
    @MainActor
    struct IconDrawingTests {
        private static let inset = 16
        private static let canvas = 48

        @Test(arguments: Icon.allCases)
        func everyIconDrawsSomething(icon: Icon) {
            let bitmap = Render.icon(icon, size: Theme.iconSize, canvas: Self.canvas, inset: Self.inset)
            #expect(bitmap.countVisible() > 10, "\(icon) drew almost nothing")
        }

        @Test(arguments: Icon.allCases)
        func everyIconStaysInsideItsBox(icon: Icon) {
            for size in [Theme.iconSize, 12, 24] {
                let bitmap = Render.icon(icon, size: size, canvas: Self.canvas, inset: Self.inset)
                let total = bitmap.countVisible()
                // The stroke may spill about a pixel over the box edge; anything beyond two pixels is a bug.
                let margin = 2
                let box = PixelRegion(
                    x: Self.inset - margin, y: Self.inset - margin,
                    width: Int(size) + margin * 2, height: Int(size) + margin * 2)
                #expect(bitmap.countVisible(in: box) == total, "\(icon) at \(size) pt draws outside its box")
            }
        }

        @Test(arguments: Icon.allCases)
        func everyIconFillsMostOfItsBoxExtent(icon: Icon) {
            // Icons are drawn on a 24 grid with a margin of about 2 units: the ink must reach across most of the box.
            let size: CGFloat = 24
            let bitmap = Render.icon(icon, size: size, canvas: Self.canvas, inset: Self.inset)
            var minX = Int.max, maxX = Int.min
            for x in 0..<bitmap.width where bitmap.countVisible(in: .columns(x, 1, height: bitmap.height)) > 0 {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
            #expect(maxX - minX >= 8, "\(icon) is only \(maxX - minX + 1) px wide at 24 pt")
        }

        @Test func iconColorIsTheRequestedOne() {
            let bitmap = Render.icon(.close, size: 24, canvas: Self.canvas, inset: Self.inset)
            let white = bitmap.count(near: RGB(255, 255, 255), tolerance: 0)
            #expect(white > 10)
        }

        @Test func iconIsDrawnAtTheRequestedPosition() {
            let bitmap = Render.icon(.chevronDown, size: 24, canvas: 64, inset: 30)
            #expect(bitmap.countVisible(in: PixelRegion(x: 0, y: 0, width: 28, height: 64)) == 0)
            #expect(bitmap.countVisible(in: PixelRegion(x: 28, y: 28, width: 36, height: 36)) > 10)
        }

        @Test func thickerStrokeDrawsMoreInk() {
            func ink(_ weight: CGFloat) -> Int {
                Bitmap.render(width: 48, height: 48) {
                    Icon.branch.draw(in: $0, x: 8, y: 8, size: 32, color: Theme.rgb(0xffffff), weight: weight)
                }.countVisible()
            }
            #expect(ink(3) > ink(1))
        }
    }

    @MainActor
    struct ThemeTests {
        @Test func changeKindsMapToTheirInks() {
            #expect(Ink.change(.modified) == .yellow)
            #expect(Ink.change(.added) == .green)
            #expect(Ink.change(.deleted) == .red)
            #expect(Ink.change(.conflicted) == .red)
            #expect(Ink.change(.renamed) == .blue)
        }

        @Test(arguments: ChangeKind.allCases)
        func everyChangeKindHasAnInk(kind: ChangeKind) {
            #expect(Ink.change(kind).cg.alpha == 1)
        }

        @Test(arguments: [
            (TokenKind.plain, Ink.code), (.keyword, .keyword), (.type, .type), (.function, .function),
            (.string, .string), (.number, .number), (.comment, .comment), (.punctuation, .punctuation),
            (.variable, .variable), (.tag, .tag), (.attribute, .attribute), (.operator, .operator),
        ])
        func syntaxKindsMapToTheirInks(kind: TokenKind, ink: Ink) {
            #expect(Ink.syntax(kind) == ink)
        }

        @Test func syntaxInksReadTheActivePalette() {
            let palette = SyntaxPalette.active
            #expect(RGB(Ink.code.cg) == RGB(hex: palette.plain))
            #expect(RGB(Ink.operator.cg) == RGB(hex: palette.operator))
            #expect(RGB(Ink.syntax(.keyword).cg) == RGB(hex: palette.keyword))
            #expect(palette.plain == 0xabb2bf && palette.operator == 0x56b6c2 && palette.comment == 0x7f848e)
            // The UI text color is not the code text color.
            #expect(RGB(Ink.fg.cg) == RGB(hex: 0xb8bec9))
        }

        @Test func everyTokenKindIsCovered() {
            #expect(TokenKind.allCases.count == 12)
        }

        @Test func syntaxColorsAreOpaqueAndVariableDiffersFromPlain() {
            #expect(TokenKind.allCases.allSatisfy { Ink.syntax($0).cg.alpha == 1 })
            #expect(RGB(Ink.syntax(.variable).cg) != RGB(Ink.syntax(.plain).cg))
            // One Dark Pro Flat: tags share the variable red, attributes the number orange, punctuation the plain gray.
            #expect(RGB(Ink.syntax(.tag).cg) == RGB(Ink.syntax(.variable).cg))
            #expect(RGB(Ink.syntax(.attribute).cg) == RGB(Ink.syntax(.number).cg))
            #expect(RGB(Ink.syntax(.punctuation).cg) == RGB(Ink.syntax(.plain).cg))
        }

        @Test func everyInkHasAColor() {
            #expect(Theme.inkColors.count == Ink.allCases.count)
            for ink in Ink.allCases {
                #expect(ink.cg.alpha == 1)
            }
        }

        @Test(arguments: [
            // Text.
            (Ink.fg, 0xb8bec9 as UInt32), (.mid, 0x9fa7b4), (.dim, 0x7b818b), (.icon, 0x848b98),
            (.lineNumber, 0x484f5e), (.ignored, 0x5d6470),
            // Status.
            (.green, 0x94c580), (.red, 0xe17177), (.yellow, 0xe1bc77), (.blue, 0x6caeef),
            // Syntax.
            // One Dark Pro Flat.
            (.code, 0xabb2bf), (.keyword, 0xc678dd), (.type, 0xe5c07b), (.function, 0x61afef), (.string, 0x98c379),
            (.number, 0xd19a66), (.comment, 0x7f848e), (.punctuation, 0xabb2bf), (.variable, 0xe06c75),
            (.operator, 0x56b6c2), (.tag, 0xe06c75), (.attribute, 0xd19a66),
        ])
        func inkColorsMatchTheDesign(ink: Ink, hex: UInt32) {
            #expect(RGB(ink.cg) == RGB(hex: hex))
        }

        @Test func surfaceAndFillColorsMatchTheDesign() {
            func check(_ color: CGColor, _ hex: UInt32, _ alpha: CGFloat, _ name: String) {
                #expect(RGB(color) == RGB(hex: hex), "\(name) color")
                #expect(abs(color.alpha - alpha) < 0.0001, "\(name) alpha")
            }
            check(Theme.background, 0x22262c, 1, "background")
            check(Theme.inactive, 0x1c1f24, 1, "inactive")
            check(Theme.line, 0x2d3138, 1, "line")
            check(Theme.guide, 0x363b43, 1, "guide")
            check(Theme.addedRow, 0x94c580, 0.12, "addedRow")
            check(Theme.deletedRow, 0xe17177, 0.12, "deletedRow")
            check(Theme.addedWord, 0x94c580, 0.30, "addedWord")
            check(Theme.deletedWord, 0xe17177, 0.30, "deletedWord")
            check(Theme.band, 0xffffff, 0.035, "band")
            check(Theme.rowSelected, 0xffffff, 0.07, "rowSelected")
            check(Theme.rowHover, 0xffffff, 0.03, "rowHover")
            check(Theme.closeHover, 0xffffff, 0.10, "closeHover")
        }

        @Test func everyFaceHasAFont() {
            #expect(Theme.fonts.count == Face.allCases.count)
        }

        @Test func codeStartsAfterTheGutter() {
            #expect(Theme.codeX == 66)
            #expect(Theme.codeX == Theme.gutterBarWidth + Theme.gutterNumberWidth + Theme.gutterGap)
        }

        @Test func charWidthIsPositiveAndMatchesTheMonospacedFont() {
            #expect(Theme.charWidth > 0)
            #expect(Theme.charWidth < 20)
            let wide = TextCache.shared.line("0000000000", .regular, .fg).width
            let narrow = TextCache.shared.line("iiiiiiiiii", .regular, .fg).width
            #expect(abs(wide - narrow) < 0.5)
            #expect(abs(wide / 10 - Theme.charWidth) < 0.05)
        }

        @Test func rgbHelperReadsHexAndAlpha() {
            let color = Theme.rgb(0x336699, 0.5)
            #expect(color.alpha == 0.5)
            #expect(RGB(color) == RGB(hex: 0x336699))
        }

        @Test func rowTintsAreTranslucentSoTheTextBelowStaysReadable() {
            for tint in [Theme.addedRow, Theme.deletedRow, Theme.rowSelected, Theme.rowHover, Theme.band] {
                #expect(tint.alpha > 0 && tint.alpha < 0.5)
            }
        }
    }

}
