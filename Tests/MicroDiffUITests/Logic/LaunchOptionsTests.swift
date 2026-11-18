import CoreGraphics
import MicroDiffCore
import Testing
@testable import MicroDiffUI

extension UITests {
    @MainActor
    struct LaunchOptionsTests {
        private func parse(_ arguments: [String]) -> LaunchOptions {
            LaunchOptions(arguments: ["MicroDiff"] + arguments)
        }

        @Test func noArgumentsMeansDefaults() {
            let options = parse([])
            #expect(options.path == nil)
            #expect(options.snapshotPath == nil)
            #expect(options.snapshotSize == CGSize(width: 1180, height: 720))
            #expect(options.sidebarTab == .changes)
            #expect(options.openFiles.isEmpty)
            #expect(options.mode == nil)
            #expect(options.benchmark == false)
        }

        @Test func programNameIsNotTakenForAPath() {
            #expect(parse([]).path == nil)
        }

        @Test func aPlainArgumentIsThePath() {
            #expect(parse(["/some/repo"]).path == "/some/repo")
        }

        @Test func firstPlainArgumentWinsAsPath() {
            #expect(parse(["first", "second"]).path == "first")
            #expect(parse(["--bench", "first", "second"]).path == "first")
        }

        @Test func snapshotTakesTheFollowingArgumentAsOutputFile() {
            let options = parse(["/repo", "--snapshot", "out.png"])
            #expect(options.snapshotPath == "out.png")
            #expect(options.path == "/repo")
        }

        @Test func snapshotValueIsNeverTakenAsThePath() {
            #expect(parse(["--snapshot", "out.png"]).path == nil)
        }

        @Test func sidebarTakesAWidthInPoints() {
            #expect(parse([]).snapshotSidebarWidth == nil)
            #expect(parse(["--sidebar", "220"]).snapshotSidebarWidth == 220)
            #expect(parse(["--sidebar", "160.5"]).snapshotSidebarWidth == 160.5)
        }

        @Test func sidebarWithoutAUsableWidthIsIgnoredAndKeepsThePath() {
            #expect(parse(["--sidebar"]).snapshotSidebarWidth == nil)
            #expect(parse(["--sidebar", "wide"]).snapshotSidebarWidth == nil)
            let options = parse(["--sidebar", "--snapshot", "out.png", "/repo"])
            #expect(options.snapshotSidebarWidth == nil)
            #expect(options.snapshotPath == "out.png")
            #expect(options.path == "/repo")
        }

        @Test func tabFilesSelectsTheFilesTab() {
            #expect(parse(["--tab", "files"]).sidebarTab == .files)
        }

        @Test func tabChangesAndUnknownValuesSelectTheChangesTab() {
            #expect(parse(["--tab", "changes"]).sidebarTab == .changes)
            #expect(parse(["--tab", "whatever"]).sidebarTab == .changes)
            #expect(parse(["--tab"]).sidebarTab == .changes)
        }

        @Test func severalOpenFlagsKeepTheirOrder() {
            let options = parse(["--open", "b.swift", "--open", "a/c.rs", "--open", "z.txt"])
            #expect(options.openFiles == ["b.swift", "a/c.rs", "z.txt"])
        }

        @Test func openWithoutAValueIsIgnored() {
            #expect(parse(["--open"]).openFiles.isEmpty)
        }

        @Test func modeReadSelectsReadMode() {
            #expect(parse(["--mode", "read"]).mode == .read)
            #expect(parse(["--mode", "file"]).mode == nil, "the old name is gone")
        }

        @Test func modeDiffSelectsDiffMode() {
            #expect(parse(["--mode", "diff"]).mode == .diff)
        }

        @Test func modeEditSelectsEditMode() {
            #expect(parse(["--mode", "edit"]).mode == .edit)
            #expect(parse(["--mode", "write"]).mode == nil)
        }

        @Test func sizeIsReadAsWidthTimesHeight() {
            #expect(parse(["--size", "800x600"]).snapshotSize == CGSize(width: 800, height: 600))
            #expect(parse(["--size", "1180.5x720"]).snapshotSize == CGSize(width: 1180.5, height: 720))
        }

        @Test func malformedSizeIsIgnored() {
            let standard = CGSize(width: 1180, height: 720)
            for text in ["800", "800x", "x600", "axb", "800x600x400", "", "800*600"] {
                #expect(parse(["--size", text]).snapshotSize == standard, "size \(text)")
            }
            #expect(parse(["--size"]).snapshotSize == standard)
        }

        @Test func sizeValueIsNeverTakenAsThePath() {
            #expect(parse(["--size", "800x600"]).path == nil)
        }

        @Test func zeroOrNegativeSizeIsIgnored() {
            let standard = CGSize(width: 1180, height: 720)
            #expect(parse(["--size", "0x0"]).snapshotSize == standard)
            #expect(parse(["--size", "-5x10"]).snapshotSize == standard)
        }

        @Test func benchFlagTurnsOnBenchmarkMode() {
            #expect(parse(["--bench"]).benchmark)
        }

        @Test func finderProcessSerialArgumentIsIgnored() {
            let options = parse(["-psn_0_123456"])
            #expect(options.path == nil)
            #expect(options.benchmark == false)
        }

        @Test func unknownFlagsAreIgnoredAndDoNotHideThePath() {
            let options = parse(["-psn_0_123", "--unknown", "/repo"])
            #expect(options.path == "/repo")
        }

        @Test func everythingTogether() {
            let options = parse([
                "/repo", "--snapshot", "/tmp/out.png", "--tab", "files", "--open", "a.rs", "--open", "b.rs",
                "--mode", "read", "--size", "640x480", "--bench",
            ])
            #expect(options.path == "/repo")
            #expect(options.snapshotPath == "/tmp/out.png")
            #expect(options.sidebarTab == .files)
            #expect(options.openFiles == ["a.rs", "b.rs"])
            #expect(options.mode == .read)
            #expect(options.snapshotSize == CGSize(width: 640, height: 480))
            #expect(options.benchmark)
        }
    }

}
