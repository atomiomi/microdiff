import MicroDiffCore
import Testing
@testable import MicroDiffUI

extension UITests {
    /// Which starts talk to a running instance, and what they ask it.
    @MainActor
    struct InstanceLaunchOptionsTests {
        private func parse(_ arguments: [String]) -> LaunchOptions {
            LaunchOptions(arguments: ["MicroDiff"] + arguments)
        }

        @Test func offscreenAndMeasuringModesRunOnTheirOwn() {
            #expect(parse(["/repo", "--snapshot", "out.png"]).isStandaloneMode)
            #expect(parse(["/repo", "--soak", "5"]).isStandaloneMode)
            #expect(parse(["--soak"]).isStandaloneMode)
            #expect(parse(["/repo", "--bench"]).isStandaloneMode)
        }

        @Test func normalStartsUseTheRunningInstance() {
            #expect(!parse(["/repo"]).isStandaloneMode)
            #expect(!parse(["/repo", "--open", "a.txt", "--mode", "file", "--tab", "files"]).isStandaloneMode)
            #expect(!parse([]).isStandaloneMode)
        }

        @Test func theRequestCarriesTheAbsoluteFolderTheFilesAndTheMode() {
            let request = parse(["/some/repo/../repo", "--open", "/some/repo/a b.txt", "--open", "src/x.swift", "--mode", "file"]).instanceRequest
            #expect(request.folder == "/some/repo")
            #expect(request.openFiles == ["/some/repo/a b.txt", "src/x.swift"])
            #expect(request.mode == "file")
            #expect(parse(["/r"]).instanceRequest == InstanceRequest(folder: "/r"))
            #expect(parse(["/r", "--mode", "diff"]).instanceRequest.mode == "diff")
        }

        @Test func aRelativeFolderIsResolvedAgainstTheWorkingDirectoryBeforeItIsSent() {
            let request = parse(["some/sub"]).instanceRequest
            #expect(request.folder.hasPrefix("/"))
            #expect(request.folder.hasSuffix("/some/sub"))
        }

        @Test func theRequestSurvivesTheWire() {
            let request = parse(["/Users/me/Мой проект", "--open", "файл.swift"]).instanceRequest
            #expect(InstanceRequest.decode(request.encoded()) == request)
        }
    }
}
