import AppKit
import MicroDiffCore
import MicroDiffTestSupport
import Testing
@testable import MicroDiffUI

/// Renders the whole window content offscreen (the window is created but never shown).
extension UITests {
    @MainActor
    @Suite
    struct SnapshotRenderingTests {
        private static let repo = Fixture.changesRepo()
        private static let size = CGSize(width: 800, height: 480)

        private static let background = RGB(Theme.background)
        private static let addedTint = RGB.composite(Theme.addedRow, over: Theme.background)
        private static let deletedTint = RGB.composite(Theme.deletedRow, over: Theme.background)

        /// A rendered picture and how many pixels a point is.
        private struct Picture {
            var bitmap: Bitmap
            var scale: Int

            /// Pixels per point: one column of the main area starts after the 288 pt sidebar and its divider.
            var mainArea: PixelRegion {
                PixelRegion(x: 289 * scale, y: 0, width: bitmap.width - 289 * scale, height: bitmap.height)
            }
        }

        private func render(
            _ path: String, tab: SidebarTab = .changes, open files: [String] = [], mode: ViewMode? = nil,
            size: CGSize = SnapshotRenderingTests.size
        ) throws -> Picture {
            Render.prepareApplication()
            let controller = MainWindowController(path: path)
            let data = try #require(controller.renderSnapshot(size: size, sidebarTab: tab, open: files, mode: mode))
            let bitmap = try #require(Bitmap.decode(png: data))
            let scale = bitmap.width / Int(size.width)
            #expect(bitmap.width == Int(size.width) * scale && bitmap.height == Int(size.height) * scale)
            #expect(scale == 1 || scale == 2)
            return Picture(bitmap: bitmap, scale: max(1, scale))
        }

        // MARK: Size

        @Test func imageHasTheRequestedSizeInPointsAtOneOrTwoTimes() throws {
            for size in [CGSize(width: 800, height: 480), CGSize(width: 640, height: 400)] {
                let picture = try render(Self.repo.path, size: size)
                #expect(picture.bitmap.width == Int(size.width) * picture.scale)
                #expect(picture.bitmap.height == Int(size.height) * picture.scale)
            }
        }

        // MARK: Diff open

        @Test func diffOfAModifiedFileShowsAddedAndDeletedRowTints() throws {
            let picture = try render(Self.repo.path, open: ["src/app.swift"])
            let area = picture.mainArea
            let minimum = 2000 * picture.scale * picture.scale
            #expect(picture.bitmap.count(near: Self.addedTint, in: area) > minimum)
            #expect(picture.bitmap.count(near: Self.deletedTint, in: area) > minimum)
        }

        @Test func diffShowsTheGreenAndRedGutterBars() throws {
            let picture = try render(Self.repo.path, open: ["src/app.swift"])
            let bar = PixelRegion(x: 289 * picture.scale, y: 0, width: 2 * picture.scale, height: picture.bitmap.height)
            let minimum = 20 * picture.scale * picture.scale
            #expect(picture.bitmap.count(near: RGB(Ink.green.cg), in: bar) > minimum)
            #expect(picture.bitmap.count(near: RGB(Ink.red.cg), in: bar) > minimum)
        }

        @Test func eachChangedRowGetsItsOwnTintedBand() throws {
            // Two hunks, each one deleted + one added line: four bands one line tall, each as wide as the main area.
            let picture = try render(Self.repo.path, open: ["src/app.swift"])
            let rowsOfAdded = rowCount(picture, tint: Self.addedTint)
            let rowsOfDeleted = rowCount(picture, tint: Self.deletedTint)
            #expect(rowsOfAdded == 2 * Int(Theme.lineHeight) * picture.scale)
            #expect(rowsOfDeleted == 2 * Int(Theme.lineHeight) * picture.scale)
        }

        /// Number of pixel rows in the main area that are mostly the given tint.
        private func rowCount(_ picture: Picture, tint: RGB) -> Int {
            let area = picture.mainArea
            var rows = 0
            for y in 0..<picture.bitmap.height {
                let band = PixelRegion(x: area.x, y: y, width: area.width, height: 1)
                if picture.bitmap.count(near: tint, in: band) > area.width * 6 / 10 { rows += 1 }
            }
            return rows
        }

        @Test func plainUntrackedFileHasNoRowTintsAndNoBars() throws {
            let picture = try render(Self.repo.path, open: ["new/deep/fresh.txt"])
            // A few anti-aliased text pixels may land near the tint; never a whole row.
            let stray = 50 * picture.scale * picture.scale
            #expect(picture.bitmap.count(near: Self.addedTint, in: picture.mainArea) < stray)
            #expect(picture.bitmap.count(near: Self.deletedTint, in: picture.mainArea) < stray)
        }

        @Test func fileModeOfAModifiedFileMarksOnlyTheGutterNotTheRows() throws {
            // Tall enough to have the changed line (around line 20) on screen.
            let picture = try render(Self.repo.path, open: ["src/app.swift"], mode: .read, size: CGSize(width: 800, height: 640))
            #expect(picture.bitmap.count(near: Self.deletedTint, in: picture.mainArea) < 150 * picture.scale * picture.scale)  // anti-aliased pink text may land near the tint; a tinted row is thousands of pixels
            let bar = PixelRegion(x: 289 * picture.scale, y: 0, width: 2 * picture.scale, height: picture.bitmap.height)
            #expect(picture.bitmap.count(near: RGB(Ink.yellow.cg), in: bar) > 10 * picture.scale)
        }

        // MARK: Nothing open

        @Test func withNoFileOpenThereAreNoTintedPixelsInTheMainArea() throws {
            let picture = try render(Self.repo.path)
            #expect(picture.bitmap.count(near: Self.addedTint, in: picture.mainArea) == 0)
            #expect(picture.bitmap.count(near: Self.deletedTint, in: picture.mainArea) == 0)
            let bar = PixelRegion(x: 289 * picture.scale, y: 0, width: 2 * picture.scale, height: picture.bitmap.height)
            #expect(picture.bitmap.count(near: RGB(Ink.green.cg), in: bar) == 0)
        }

        @Test func withNoFileOpenTheMainAreaShowsAMessage() throws {
            let picture = try render(Self.repo.path)
            let middle = PixelRegion(x: 289 * picture.scale + 50, y: 150 * picture.scale, width: 400 * picture.scale, height: 250 * picture.scale)
            #expect(picture.bitmap.count(notNear: Self.background, in: middle) > 20)
        }

        // MARK: Chrome

        @Test func titleStripIsTheBackgroundColor() throws {
            let picture = try render(Self.repo.path, open: ["src/app.swift"])
            // The picture includes the window frame: sample right of the window buttons and left of the centered title.
            let strip = PixelRegion(x: 110 * picture.scale, y: 8 * picture.scale, width: 40 * picture.scale, height: 10 * picture.scale)
            #expect(picture.bitmap.isUniform(Self.background, in: strip))
        }

        @Test func sidebarAndMainAreaAreSeparatedByAThemeLineColumn() throws {
            let picture = try render(Self.repo.path, open: ["src/app.swift"])
            let line = RGB(Theme.line)
            let bitmap = picture.bitmap
            let columns = (0..<bitmap.width).filter { x in
                bitmap.count(near: line, in: .columns(x, 1, height: bitmap.height), tolerance: 2) > bitmap.height * 6 / 10
            }
            #expect(!columns.isEmpty)
            // The default sidebar is 288 pt wide: the divider sits right at its edge.
            let expected = 288 * picture.scale
            #expect(columns.contains { abs($0 - expected) <= picture.scale })
        }

        // MARK: Other folders and tabs

        @Test func notARepoFolderRendersAnImage() throws {
            let folder = Fixture.plainFolder()
            let picture = try render(folder.path)
            #expect(picture.bitmap.count(notNear: Self.background) > 100)
        }

        @Test func cleanRepoRendersAnImage() throws {
            let repo = Fixture.cleanRepo()
            let picture = try render(repo.path)
            #expect(picture.bitmap.count(notNear: Self.background) > 100)
        }

        @Test func notARepoAndCleanRepoShowAnEmptyMessageInTheSidebar() throws {
            let folder = Fixture.plainFolder()
            let repo = Fixture.cleanRepo()
            for path in [folder.path, repo.path] {
                let picture = try render(path)
                let sidebarBottom = PixelRegion(x: 20 * picture.scale, y: 150 * picture.scale, width: 250 * picture.scale, height: 250 * picture.scale)
                #expect(picture.bitmap.count(notNear: Self.background, in: sidebarBottom) > 20)
            }
        }

        @Test func filesTabWithAFileOpenShowsTheWholeFileByDefault() throws {
            let picture = try render(Self.repo.path, tab: .files, open: ["src/app.swift"], size: CGSize(width: 800, height: 640))
            // Read mode: no row tints, but the changed lines are marked in the gutter.
            #expect(picture.bitmap.count(near: Self.deletedTint, in: picture.mainArea) < 150 * picture.scale * picture.scale)  // anti-aliased pink text may land near the tint; a tinted row is thousands of pixels
            let bar = PixelRegion(x: 289 * picture.scale, y: 0, width: 2 * picture.scale, height: picture.bitmap.height)
            #expect(picture.bitmap.count(near: RGB(Ink.yellow.cg), in: bar) > 10 * picture.scale)
        }

        @Test func filesTabWithTheDiffModeShowsTheTints() throws {
            let picture = try render(Self.repo.path, tab: .files, open: ["src/app.swift"], mode: .diff)
            #expect(picture.bitmap.count(near: Self.addedTint, in: picture.mainArea) > 2000)
        }

        @Test func filesTabAndChangesTabLookDifferent() throws {
            let changes = try render(Self.repo.path, tab: .changes)
            let files = try render(Self.repo.path, tab: .files)
            let sidebar = PixelRegion(x: 0, y: 0, width: 288 * changes.scale, height: changes.bitmap.height)
            var differing = 0
            for y in stride(from: 0, to: changes.bitmap.height, by: 2) {
                for x in stride(from: 0, to: sidebar.width, by: 2) where changes.bitmap.rgb(x, y) != files.bitmap.rgb(x, y) {
                    differing += 1
                }
            }
            #expect(differing > 200)
        }

        @Test func rendersAreRepeatable() throws {
            let first = try render(Self.repo.path, open: ["src/app.swift"])
            let second = try render(Self.repo.path, open: ["src/app.swift"])
            #expect(first.bitmap.count(near: Self.addedTint) == second.bitmap.count(near: Self.addedTint))
        }

        @Test func absoluteOpenPathsAreAccepted() throws {
            let picture = try render(Self.repo.path, open: [Self.repo.path + "/src/app.swift"])
            #expect(picture.bitmap.count(near: Self.addedTint, in: picture.mainArea) > 2000)
        }
    }

}
