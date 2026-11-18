import AppKit
import Testing
@testable import MicroDiffUI

extension UITests {
    /// Which folder the app opens for the command line it got.
    @MainActor
    struct LaunchStartPathTests {
        private func options(_ arguments: [String]) -> LaunchOptions {
            LaunchOptions(arguments: ["MicroDiff"] + arguments)
        }

        private var cwd: String { FileManager.default.currentDirectoryPath }

        @Test func anAbsolutePathIsStandardized() {
            #expect(options(["/tmp/some/../repo/"]).startPath == "/tmp/repo")
            #expect(options(["/tmp//repo/./sub"]).startPath == "/tmp/repo/sub")
        }

        @Test func aRelativePathIsResolvedAgainstTheCurrentDirectory() {
            let expected = URL(fileURLWithPath: cwd + "/some/sub").standardizedFileURL.path
            #expect(options(["some/sub"]).startPath == expected)
            #expect(options(["."]).startPath == URL(fileURLWithPath: cwd).standardizedFileURL.path)
            #expect(options(["some/../other"]).startPath == URL(fileURLWithPath: cwd + "/other").standardizedFileURL.path)
        }

        @Test func noPathMeansTheCurrentDirectoryUnlessItIsTheRootWhichFinderUses() {
            let expected: String? = cwd == "/" ? nil : cwd
            #expect(options([]).startPath == expected)
            // Flags alone do not name a folder.
            #expect(options(["--bench", "--tab", "files"]).startPath == expected)
        }

        @Test func aPathWithSpacesAndNonASCIICharactersKeepsThemAndFlagsDoNotEatIt() {
            let path = "/tmp/my repo/caf\u{E9} \u{65E5}\u{672C}"
            #expect(options(["--tab", path]).startPath == path)
            #expect(options([path, "--open", "a b.txt"]).openFiles == ["a b.txt"])
            #expect(options([path, "--open", "a b.txt"]).startPath == path)
        }
    }
}
