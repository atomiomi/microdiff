import AppKit
import MicroDiffCore
import Testing
@testable import MicroDiffUI

extension UITests {
    @MainActor
    struct TreeStyleRenderingTests {
        private let background = RGB(Theme.background)
        private let width = 280

        private func fileRow(_ name: String, change: ChangeKind? = nil, ignored: Bool = false) -> TreeRow {
            TreeRow(
                id: "0|f|\(name)", kind: .file, depth: 1, name: name, path: name, repoIndex: change == nil ? -1 : 0,
                change: change.map { FileChange(path: name, kind: $0, isUntracked: $0 == .added) }, isIgnored: ignored)
        }

        private func dirRow(_ name: String, mark: ChangeKind? = nil, ignored: Bool = false) -> TreeRow {
            TreeRow(
                id: "0|d|\(name)", kind: .directory, depth: 1, name: name, path: name, repoIndex: 0,
                dirMark: mark, isIgnored: ignored)
        }

        private func render(_ rows: [TreeRow], selected: Int? = nil) -> Bitmap {
            let view = TreeView(frame: NSRect(x: 0, y: 0, width: width, height: 300))
            view.style = .files
            view.setRows(rows)
            view.selectedID = selected.map { rows[$0].id }
            return Render.canvas(view)
        }

        private func top(_ index: Int) -> Int { 8 + index * 24 }
        private var iconX: Int { Int(Theme.treePadding + Theme.treeIndent) }
        private var nameX: Int { iconX + 22 }

        private func nameRegion(_ row: Int) -> PixelRegion { PixelRegion(x: nameX, y: top(row), width: 150, height: 24) }
        private func iconRegion(_ row: Int) -> PixelRegion { PixelRegion(x: iconX, y: top(row) + 4, width: 16, height: 16) }

        /// Total brightness above the background in a region: lower when an icon is drawn dimmer.
        private func glow(_ bitmap: Bitmap, _ region: PixelRegion) -> Int {
            var total = 0
            for y in region.y..<(region.y + region.height) {
                for x in region.x..<(region.x + region.width) {
                    let c = bitmap.rgb(x, y)
                    total += abs(c.r - background.r) + abs(c.g - background.g) + abs(c.b - background.b)
                }
            }
            return total
        }

        @Test func folderWithOnlyNewFilesDrawsAGreenDotAtTheRightPlace() {
            let bitmap = render([dirRow("scripts", mark: .added), dirRow("plain")])
            let dot = RGB.composite(Ink.green.cg.copy(alpha: 0.85)!, over: background)
            let cx = width - 14 - 4, cy = top(0) + 12
            #expect(bitmap.rgb(cx, cy).isClose(to: dot, tolerance: 4))
            // Dot is 5 wide: its edges and the rest of the 7x7 box are background.
            #expect(bitmap.rgb(width - 14 - 8, cy).isClose(to: background))
            #expect(bitmap.rgb(width - 14, cy).isClose(to: background))
            #expect(bitmap.isUniform(background, in: PixelRegion(x: width - 16, y: top(1), width: 16, height: 24)))
        }

        @Test func dotColorFollowsTheMarkOfTheFolder() {
            let bitmap = render([dirRow("mixed", mark: .modified)])
            let dot = RGB.composite(Ink.yellow.cg.copy(alpha: 0.85)!, over: background)
            #expect(bitmap.rgb(width - 18, top(0) + 12).isClose(to: dot, tolerance: 4))
        }

        @Test func statusColorsAppearInTheNames() {
            let rows = [
                fileRow("mod.txt", change: .modified), fileRow("new.txt", change: .added), fileRow("plain.txt"),
                fileRow("ren.txt", change: .renamed),
            ]
            let bitmap = render(rows)
            func near(_ ink: Ink, _ row: Int) -> Int { bitmap.count(near: RGB(ink.cg), in: nameRegion(row), tolerance: 12) }
            #expect(near(.yellow, 0) > 5)
            #expect(near(.green, 1) > 5)
            #expect(near(.mid, 2) > 5)
            #expect(near(.blue, 3) > 5)
            #expect(near(.mid, 0) == 0)
            #expect(near(.yellow, 2) == 0)
        }

        @Test func selectedModifiedRowKeepsItsStatusColorOnTheSelectionFill() {
            let rows = [fileRow("mod.txt", change: .modified), fileRow("plain.txt")]
            let selection = RGB.composite(Theme.rowSelected, over: Theme.background)
            let bitmap = render(rows, selected: 0)
            #expect(bitmap.isUniform(selection, in: PixelRegion(x: 0, y: top(0), width: 10, height: 24)))
            #expect(bitmap.count(near: RGB(Ink.yellow.cg), in: nameRegion(0), tolerance: 12) > 5)
            let plain = render(rows, selected: 1)
            #expect(plain.count(near: RGB(Ink.fg.cg), in: nameRegion(1), tolerance: 12) > 5)
        }

        @Test func ignoredNamesUseTheIgnoredColor() {
            let bitmap = render([fileRow(".env", ignored: true), dirRow("node_modules", ignored: true)])
            #expect(bitmap.count(near: RGB(Ink.ignored.cg), in: nameRegion(0), tolerance: 12) > 5)
            #expect(bitmap.count(near: RGB(Ink.ignored.cg), in: nameRegion(1), tolerance: 12) > 5)
            #expect(bitmap.count(near: RGB(Ink.mid.cg), in: nameRegion(0), tolerance: 12) == 0)
        }

        @Test func ignoredIconsAreDimmerThanNormalOnes() {
            let bitmap = render([
                fileRow("a.txt"), fileRow("a.txt", ignored: true), dirRow("d"), dirRow("d", ignored: true),
            ])
            #expect(glow(bitmap, iconRegion(0)) > 0)
            #expect(glow(bitmap, iconRegion(1)) < glow(bitmap, iconRegion(0)))
            #expect(glow(bitmap, iconRegion(3)) < glow(bitmap, iconRegion(2)))
        }

        @Test func iconsDoNotChangeWhenARowIsSelected() {
            let rows = [fileRow("a.txt"), fileRow("b.txt")]
            let before = render(rows)
            let after = render(rows, selected: 0)
            let selection = RGB.composite(Theme.rowSelected, over: Theme.background)
            // Same icon pixels apart from the selection fill underneath: count the strongly colored ones.
            func strong(_ bitmap: Bitmap) -> Int {
                bitmap.count(in: iconRegion(0)) { c, _ in abs(c.r - selection.r) + abs(c.g - selection.g) + abs(c.b - selection.b) > 60 }
            }
            #expect(abs(strong(before) - strong(after)) <= 12)
        }

        @Test func iconsSitFourPointsBelowTheRowTop() {
            let bitmap = render([fileRow("a.txt")])
            let above = PixelRegion(x: iconX, y: top(0), width: 16, height: 3)
            #expect(bitmap.isUniform(background, in: above))
            #expect(bitmap.count(notNear: background, in: iconRegion(0)) > 20)
        }
    }
}
