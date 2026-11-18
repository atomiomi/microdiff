import MicroDiffCore
import MicroDiffTestSupport
import Testing
@testable import MicroDiffUI

extension UITests {
    @MainActor
    @Suite
    struct WorkspaceScanTests {
        private static let changes = Fixture.changesRepo()

        @Test func scanNowFillsTheSnapshotWithEveryKindOfChange() throws {
            let repo = Self.changes
            let workspace = Workspace(path: repo.path)
            #expect(workspace.snapshot == nil)

            workspace.scanNow()

            let snapshot = try #require(workspace.snapshot)
            #expect(snapshot.isGitRepo)
            #expect(snapshot.repos.count == 1)
            let kinds = Dictionary(uniqueKeysWithValues: snapshot.repos[0].changes.map { ($0.path, $0.kind) })
            #expect(kinds == [
                "src/app.swift": .modified,
                "src/other.swift": .modified,
                "data.bin": .modified,
                "docs/old.txt": .deleted,
                "docs/renamed.txt": .renamed,
                "new/deep/fresh.txt": .added,
            ])
            #expect(snapshot.totalChangeCount == 6)
        }

        @Test func untrackedFileInNewFolderIsReportedAsAddedAndUntracked() {
            let workspace = scannedWorkspace(Self.changes.path)
            let fresh = workspace.snapshot?.repos[0].changes.first { $0.path == "new/deep/fresh.txt" }
            #expect(fresh?.isUntracked == true)
        }

        @Test func rootPathIsTheGitTopLevelEvenWhenOpenedFromASubfolder() {
            let repo = Self.changes
            let workspace = Workspace(path: repo.path + "/src/ui")
            workspace.scanNow()
            #expect(workspace.rootPath == repo.path)
            #expect(workspace.rootName == folderName(repo.path))
            #expect(workspace.snapshot?.rootPath == repo.path)
        }

        @Test func rootNameIsTheFolderName() {
            let repo = Self.changes
            let workspace = scannedWorkspace(repo.path)
            #expect(workspace.rootName == folderName(repo.path))
        }

        @Test func plainFolderIsNotAGitRepoAndKeepsItsOwnPath() {
            let folder = Fixture.plainFolder()
            let workspace = scannedWorkspace(folder.path)
            #expect(workspace.snapshot?.isGitRepo == false)
            #expect(workspace.rootPath == folder.path)
            #expect(workspace.snapshot?.totalChangeCount == 0)
        }

        @Test func cleanRepoHasARootRepoAndNoChanges() {
            let repo = Fixture.cleanRepo()
            let workspace = scannedWorkspace(repo.path)
            #expect(workspace.snapshot?.isGitRepo == true)
            #expect(workspace.snapshot?.repos.count == 1)
            #expect(workspace.snapshot?.totalChangeCount == 0)
        }

        @Test func submoduleWithChangesInsideGetsItsOwnRepoSection() throws {
            let repo = Fixture.submoduleRepo()
            let workspace = scannedWorkspace(repo.path)
            let snapshot = try #require(workspace.snapshot)
            #expect(snapshot.repos.count == 2)
            #expect(snapshot.repos[1].isSubmodule)
            #expect(snapshot.repos[1].displayPath == "vendor/lib")
            #expect(snapshot.repos[1].changes.map(\.path) == ["lib.c"])
            #expect(snapshot.submodulePaths == ["vendor/lib"])
        }

        @Test func nothingIsLoadedBeforeTheFirstScan() {
            let workspace = Workspace(path: Self.changes.path)
            #expect(workspace.sidebarRows().isEmpty)
            #expect(workspace.sidebarEmptyMessage == nil)
            #expect(workspace.tabs.isEmpty)
            #expect(workspace.activeTab == nil)
            #expect(workspace.content == nil)
        }
    }

}
