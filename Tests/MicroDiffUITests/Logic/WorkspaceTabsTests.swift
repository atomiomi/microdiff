import CoreGraphics
import MicroDiffCore
import MicroDiffTestSupport
import Testing
@testable import MicroDiffUI

private let appFile = "src/app.swift"
private let otherFile = "src/other.swift"
private let freshFile = "new/deep/fresh.txt"

extension UITests {
    @MainActor
    @Suite
    struct WorkspaceTabsTests {
        private static let repo = Fixture.changesRepo()

        private func workspace() -> Workspace {
            scannedWorkspace(Self.repo.path)
        }

        private func path(_ relative: String) -> String { Self.repo.path + "/" + relative }

        // MARK: Preview and pinned tabs

        @Test func singleClickOpenCreatesAPreviewTab() {
            let workspace = workspace()
            workspace.open(Self.repo, appFile, pin: false)
            #expect(workspace.tabs.count == 1)
            #expect(workspace.tabs[0].isPreview)
            #expect(workspace.activeTab == 0)
        }

        @Test func nextSingleClickOpenReplacesThePreviewTab() {
            let workspace = workspace()
            workspace.open(Self.repo, appFile, pin: false)
            workspace.open(Self.repo, otherFile, pin: false)
            #expect(workspace.tabs.count == 1)
            #expect(workspace.tabPaths == [path(otherFile)])
            #expect(workspace.activeTab == 0)
            #expect(workspace.tabs[0].isPreview)
        }

        @Test func replacingThePreviewTabKeepsItsPosition() {
            let workspace = workspace()
            workspace.open(Self.repo, appFile, pin: true)
            workspace.open(Self.repo, otherFile, pin: false)
            workspace.open(Self.repo, "README.md", mode: .file, pin: true)
            workspace.open(Self.repo, freshFile, pin: false)
            #expect(workspace.tabPaths == [path(appFile), path(freshFile), path("README.md")])
            #expect(workspace.activeTab == 1)
        }

        @Test func pinnedOpenAppendsAndLeavesThePreviewAlone() {
            let workspace = workspace()
            workspace.open(Self.repo, appFile, pin: false)
            workspace.open(Self.repo, otherFile, pin: true)
            #expect(workspace.tabPaths == [path(appFile), path(otherFile)])
            #expect(workspace.tabs.map(\.isPreview) == [true, false])
            #expect(workspace.activeTab == 1)
        }

        @Test func singleClickOpenAppendsWhenThereIsNoPreviewTab() {
            let workspace = workspace()
            workspace.open(Self.repo, appFile, pin: true)
            workspace.open(Self.repo, otherFile, pin: false)
            #expect(workspace.tabPaths == [path(appFile), path(otherFile)])
            #expect(workspace.tabs.map(\.isPreview) == [false, true])
        }

        @Test func openingAnAlreadyOpenFileActivatesItsTabWithoutAddingOne() {
            let workspace = workspace()
            workspace.open(Self.repo, appFile, pin: true)
            workspace.open(Self.repo, otherFile, pin: true)
            workspace.open(Self.repo, appFile, pin: false)
            #expect(workspace.tabs.count == 2)
            #expect(workspace.activeTab == 0)
            #expect(workspace.tabs[0].isPreview == false)
        }

        @Test func pinnedOpenOfAnExistingPreviewTabKeepsIt() {
            let workspace = workspace()
            workspace.open(Self.repo, appFile, pin: false)
            workspace.open(Self.repo, appFile, pin: true)
            #expect(workspace.tabs.count == 1)
            #expect(workspace.tabs[0].isPreview == false)
            // No preview tab is left to replace.
            workspace.open(Self.repo, otherFile, pin: false)
            #expect(workspace.tabs.count == 2)
        }

        @Test func singleClickOnAnExistingPinnedTabDoesNotMakeItAPreview() {
            let workspace = workspace()
            workspace.open(Self.repo, appFile, pin: true)
            workspace.open(Self.repo, appFile, pin: false)
            #expect(workspace.tabs[0].isPreview == false)
        }

        @Test func pinTabTurnsAPreviewIntoANormalTab() {
            let workspace = workspace()
            workspace.open(Self.repo, appFile, pin: false)
            workspace.pinTab(0)
            #expect(workspace.tabs[0].isPreview == false)
            workspace.open(Self.repo, otherFile, pin: false)
            #expect(workspace.tabPaths == [path(appFile), path(otherFile)])
        }

        @Test func pinTabOnAnInactiveTabAlsoSelectsIt() {
            let workspace = workspace()
            workspace.open(Self.repo, appFile, pin: false)
            workspace.open(Self.repo, otherFile, pin: true)
            workspace.pinTab(0)
            #expect(workspace.activeTab == 0)
            #expect(workspace.tabs.map(\.isPreview) == [false, false])
        }

        @Test func pinTabWithABadIndexIsIgnored() {
            let workspace = workspace()
            workspace.open(Self.repo, appFile, pin: false)
            workspace.pinTab(5)
            workspace.pinTab(-1)
            #expect(workspace.tabs[0].isPreview)
        }

        @Test func openedTabTitleIsTheFileName() {
            let workspace = workspace()
            workspace.open(Self.repo, freshFile, pin: true)
            #expect(workspace.tabNames == ["fresh.txt"])
        }

        @Test func openingNotifiesTabsSidebarAndContent() {
            let workspace = workspace()
            var tabs = 0, sidebar = 0, content = 0
            workspace.onTabsChanged = { tabs += 1 }
            workspace.onSidebarChanged = { sidebar += 1 }
            workspace.onContentChanged = { _ in content += 1 }
            workspace.open(Self.repo, appFile)
            #expect(tabs == 1)
            #expect(sidebar == 1)
            #expect(content == 1)
        }

        // MARK: Closing

        private func threeTabs() -> Workspace {
            let workspace = workspace()
            workspace.open(Self.repo, appFile)
            workspace.open(Self.repo, otherFile)
            workspace.open(Self.repo, freshFile)
            return workspace
        }

        @Test func closingTheActiveMiddleTabActivatesTheNextOne() {
            let workspace = threeTabs()
            workspace.selectTab(1)
            workspace.closeTab(1)
            #expect(workspace.tabPaths == [path(appFile), path(freshFile)])
            #expect(workspace.activePath == path(freshFile))
        }

        @Test func closingTheActiveLastTabActivatesThePreviousOne() {
            let workspace = threeTabs()
            #expect(workspace.activeTab == 2)
            workspace.closeTab(2)
            #expect(workspace.activePath == path(otherFile))
        }

        @Test func closingTheActiveFirstTabActivatesTheNewFirstOne() {
            let workspace = threeTabs()
            workspace.selectTab(0)
            workspace.closeActiveTab()
            #expect(workspace.activeTab == 0)
            #expect(workspace.activePath == path(otherFile))
        }

        @Test func closingATabBeforeTheActiveOneKeepsTheSameFileActive() {
            let workspace = threeTabs()
            workspace.closeTab(0)
            #expect(workspace.activePath == path(freshFile))
            #expect(workspace.activeTab == 1)
        }

        @Test func closingATabAfterTheActiveOneKeepsTheSameFileActive() {
            let workspace = threeTabs()
            workspace.selectTab(0)
            workspace.closeTab(2)
            #expect(workspace.activeTab == 0)
            #expect(workspace.activePath == path(appFile))
        }

        @Test func closingTheLastTabLeavesNothingActiveAndNoContent() {
            let workspace = workspace()
            workspace.open(Self.repo, appFile)
            #expect(workspace.content != nil)
            workspace.closeTab(0)
            #expect(workspace.tabs.isEmpty)
            #expect(workspace.activeTab == nil)
            #expect(workspace.content == nil)
        }

        @Test func closeActiveTabClosesTheActiveOneAndDoesNothingWithoutTabs() {
            let workspace = workspace()
            workspace.closeActiveTab()
            #expect(workspace.tabs.isEmpty)
            workspace.open(Self.repo, appFile)
            workspace.open(Self.repo, otherFile)
            workspace.closeActiveTab()
            #expect(workspace.tabPaths == [path(appFile)])
            workspace.closeActiveTab()
            #expect(workspace.activeTab == nil)
        }

        @Test func closeTabWithABadIndexIsIgnored() {
            let workspace = threeTabs()
            workspace.closeTab(3)
            workspace.closeTab(-1)
            #expect(workspace.tabs.count == 3)
            #expect(workspace.activeTab == 2)
        }

        @Test func afterClosingTheActiveTabTheNeighboursFileIsLoaded() async {
            let workspace = threeTabs()
            workspace.selectTab(1)
            _ = await waitUntil { workspace.content?.document?.firstLine == "let other = 10" }
            workspace.closeTab(1)
            let loaded = await waitUntil { workspace.content?.document?.firstLine == "fresh file" }
            #expect(loaded)
            #expect(workspace.content?.document?.kind == .plain)
        }

        @Test func aTabCanBeReopenedAfterItWasClosed() {
            let workspace = workspace()
            workspace.open(Self.repo, appFile)
            workspace.closeTab(0)
            workspace.open(Self.repo, appFile)
            #expect(workspace.tabPaths == [path(appFile)])
            #expect(workspace.content?.document?.kind == .diff)
        }

        // MARK: Selecting

        @Test func selectTabActivatesItAndLoadsItsContent() async {
            let workspace = workspace()
            workspace.open(Self.repo, appFile)
            workspace.open(Self.repo, freshFile)
            #expect(workspace.content?.document?.kind == .plain)

            workspace.selectTab(0)
            #expect(workspace.activeTab == 0)
            let loaded = await waitUntil { workspace.content?.document?.kind == .diff }
            #expect(loaded)
            #expect(workspace.content?.document?.firstLine == "let value1 = 1")
        }

        @Test func selectingTwoTabsQuicklyEndsWithTheLastOneSelected() async {
            let workspace = threeTabs()
            workspace.selectTab(0)
            workspace.selectTab(1)
            let loaded = await waitUntil { workspace.content?.document?.firstLine == "let other = 10" }
            #expect(loaded)
            // The older load of tab 0 must not win when it finishes later.
            try? await Task.sleep(for: .milliseconds(100))
            #expect(workspace.content?.document?.firstLine == "let other = 10")
        }

        @Test func selectTabIgnoresTheActiveAndInvalidIndexes() {
            let workspace = threeTabs()
            var tabsChanged = 0
            workspace.onTabsChanged = { tabsChanged += 1 }
            workspace.selectTab(2)
            workspace.selectTab(9)
            workspace.selectTab(-1)
            #expect(tabsChanged == 0)
            #expect(workspace.activeTab == 2)
        }

        // MARK: Mode

        @Test func setModeSwitchesTheActiveTabAndReloadsTheDocument() async {
            let workspace = workspace()
            workspace.open(Self.repo, appFile)
            #expect(workspace.content?.document?.kind == .diff)

            workspace.setMode(.file)
            #expect(workspace.tabs[0].mode == .file)
            #expect(await waitUntil { workspace.content?.document?.kind == .file })

            workspace.setMode(.diff)
            #expect(workspace.tabs[0].mode == .diff)
            #expect(await waitUntil { workspace.content?.document?.kind == .diff })
        }

        @Test func setModeToTheCurrentModeDoesNothing() {
            let workspace = workspace()
            workspace.open(Self.repo, appFile)
            var tabsChanged = 0
            workspace.onTabsChanged = { tabsChanged += 1 }
            workspace.setMode(.diff)
            #expect(tabsChanged == 0)
        }

        @Test func setModeWithoutATabIsIgnored() {
            let workspace = workspace()
            workspace.setMode(.file)
            #expect(workspace.tabs.isEmpty)
        }

        @Test func setModeOnlyChangesTheActiveTab() {
            let workspace = threeTabs()
            workspace.setMode(.file)
            #expect(workspace.tabs.map(\.mode) == [.diff, .diff, .file])
        }

        @Test func setModeResetsTheTabsScrollPosition() {
            let workspace = workspace()
            workspace.open(Self.repo, appFile)
            workspace.rememberScroll(CGPoint(x: 0, y: 200))
            workspace.setMode(.file)
            #expect(workspace.activeScroll == .zero)
        }

        @Test func untrackedFileShowsAsPlainInBothModes() async {
            let workspace = workspace()
            workspace.open(Self.repo, freshFile)
            var reloads = 0
            workspace.onContentChanged = { _ in reloads += 1 }
            workspace.setMode(.file)
            #expect(await waitUntil { reloads == 1 })
            #expect(workspace.content?.document?.kind == .plain)
        }

        // MARK: Folds

        private func firstFoldLine(_ workspace: Workspace) -> Int? {
            workspace.content?.document?.foldRows.first?.line
        }

        @Test func expandFoldRemovesTheFoldFromTheRowsAndRemembersItInTheTab() throws {
            let workspace = workspace()
            workspace.open(Self.repo, appFile)
            let before = try #require(workspace.content?.document)
            let foldCount = before.rows.foldCount
            #expect(foldCount >= 2)
            let line = try #require(firstFoldLine(workspace))
            let rowCount = before.rows.rowCount

            var keepScroll: Bool?
            workspace.onContentChanged = { keepScroll = $0 }
            workspace.expandFold(startingAt: line)

            let after = try #require(workspace.content?.document)
            #expect(after.rows.foldCount == foldCount - 1)
            #expect(!after.foldRows.contains { $0.line == line })
            #expect(after.rows.rowCount > rowCount)
            #expect(workspace.tabs[0].expandedFolds == [line])
            #expect(keepScroll == true)
        }

        @Test func expandedFoldsSurviveSwitchingTheModeBackAndForth() async throws {
            let workspace = workspace()
            workspace.open(Self.repo, appFile)
            let foldCount = try #require(workspace.content?.document?.rows.foldCount)
            workspace.expandFold(startingAt: try #require(firstFoldLine(workspace)))

            workspace.setMode(.file)
            #expect(await waitUntil { workspace.content?.document?.kind == .file })
            workspace.setMode(.diff)
            #expect(await waitUntil { workspace.content?.document?.kind == .diff })
            #expect(workspace.content?.document?.rows.foldCount == foldCount - 1)
        }

        @Test func expandFoldIsIgnoredOutsideADiff() throws {
            let workspace = workspace()
            workspace.expandFold(startingAt: 3)
            #expect(workspace.content == nil)

            workspace.open(Self.repo, appFile, mode: .file)
            #expect(workspace.content?.document?.kind == .file)
            workspace.expandFold(startingAt: 3)
            #expect(workspace.tabs[0].expandedFolds.isEmpty)
        }

        @Test func foldOpenedWhileARescanReloadIsInFlightStaysOpen() async throws {
            let workspace = workspace()
            workspace.open(Self.repo, appFile)
            let foldCount = try #require(workspace.content?.document?.rows.foldCount)
            let line = try #require(firstFoldLine(workspace))

            // The rescan starts a background reload with the old list of open folds ...
            workspace.scanNow()
            // ... and the user opens a fold before it lands.
            workspace.expandFold(startingAt: line)
            try? await Task.sleep(for: .milliseconds(200))

            #expect(workspace.content?.document?.rows.foldCount == foldCount - 1)
            #expect(workspace.tabs[0].expandedFolds == [line])
        }

        @Test func closingAnInactiveTabLeavesTheShownDocumentAlone() async {
            let workspace = threeTabs()
            workspace.selectTab(0)
            _ = await waitUntil { workspace.content?.document?.firstLine == "let value1 = 1" }
            var reloads = 0
            workspace.onContentChanged = { _ in reloads += 1 }

            workspace.closeTab(2)
            try? await Task.sleep(for: .milliseconds(150))

            #expect(reloads == 0)
            #expect(workspace.activePath == path(appFile))
        }

        @Test func expandedFoldsBelongToTheirTabOnly() throws {
            let workspace = workspace()
            workspace.open(Self.repo, appFile)
            workspace.expandFold(startingAt: try #require(firstFoldLine(workspace)))
            workspace.open(Self.repo, otherFile)
            #expect(workspace.tabs[1].expandedFolds.isEmpty)
            #expect(workspace.tabs[0].expandedFolds.count == 1)
        }

        // MARK: Selected row

        @Test func selectedRowIDIsNilWithoutTabs() {
            let workspace = workspace()
            #expect(workspace.selectedRowID == nil)
            workspace.selectSidebarTab(.files)
            #expect(workspace.selectedRowID == nil)
        }

        @Test func selectedRowIDMatchesTheActiveFilesRowInTheChangesTab() throws {
            let workspace = workspace()
            workspace.open(Self.repo, appFile)
            let id = try #require(workspace.selectedRowID)
            #expect(id == TreeRow.makeID(repoIndex: 0, kind: .file, path: appFile))
            #expect(workspace.sidebarRows().first { $0.id == id }?.path == appFile)
        }

        @Test func selectedRowIDMatchesTheActiveFilesRowInTheFilesTab() throws {
            let workspace = workspace()
            workspace.open(Self.repo, appFile)
            workspace.selectSidebarTab(.files)
            let id = try #require(workspace.selectedRowID)
            #expect(workspace.sidebarRows().first { $0.id == id }?.path == appFile)
        }

        @Test func selectedRowIDFollowsTheActiveTab() throws {
            let workspace = threeTabs()
            #expect(workspace.selectedRowID == TreeRow.makeID(repoIndex: 0, kind: .file, path: freshFile))
            workspace.selectTab(1)
            #expect(workspace.selectedRowID == TreeRow.makeID(repoIndex: 0, kind: .file, path: otherFile))
        }

        @Test func unchangedFileHasNoRowInTheChangesTabButOneInTheFilesTab() throws {
            let workspace = workspace()
            workspace.open(Self.repo, "README.md", mode: .file)
            #expect(workspace.selectedRowID == nil)
            workspace.selectSidebarTab(.files)
            let id = try #require(workspace.selectedRowID)
            #expect(workspace.sidebarRows().contains { $0.id == id })
        }

        @Test func fileInsideASubmoduleIsSelectedInBothTabs() throws {
            let repo = Fixture.submoduleRepo()
            let workspace = scannedWorkspace(repo.path)
            workspace.open(repo, "vendor/lib/lib.c")

            let changesID = try #require(workspace.selectedRowID)
            #expect(changesID == TreeRow.makeID(repoIndex: 1, kind: .file, path: "lib.c"))
            #expect(workspace.sidebarRows().contains { $0.id == changesID })

            workspace.selectSidebarTab(.files)
            let filesID = try #require(workspace.selectedRowID)
            #expect(workspace.sidebarRows().contains { $0.id == filesID })
        }

        @Test func switchingToTheFilesTabRevealsTheActiveFileInANestedFolder() {
            let workspace = workspace()
            workspace.open(Self.repo, freshFile)
            workspace.selectSidebarTab(.files)
            #expect(workspace.row(path: "new", kind: .directory)?.isExpanded == true)
            #expect(workspace.row(path: "new/deep", kind: .directory)?.isExpanded == true)
            #expect(workspace.row(path: freshFile) != nil)
        }

        @Test func revealingAnUnchangedNestedFileWorksToo() {
            let workspace = workspace()
            workspace.open(Self.repo, "src/ui/widgets/panel.swift", mode: .file)
            workspace.selectSidebarTab(.files)
            #expect(workspace.row(path: "src/ui/widgets/panel.swift") != nil)
        }

        @Test func switchingTheSidebarTabNotifiesOnlyWhenItChanges() {
            let workspace = workspace()
            var calls = 0
            workspace.onSidebarChanged = { calls += 1 }
            workspace.selectSidebarTab(.changes)
            #expect(calls == 0)
            workspace.selectSidebarTab(.files)
            #expect(calls == 1)
            #expect(workspace.sidebarTab == .files)
        }

        // MARK: Scroll

        @Test func rememberedScrollIsReturnedForTheActiveTab() {
            let workspace = workspace()
            workspace.open(Self.repo, appFile)
            workspace.rememberScroll(CGPoint(x: 12, y: 340))
            #expect(workspace.activeScroll == CGPoint(x: 12, y: 340))
        }

        @Test func eachTabRemembersItsOwnScroll() {
            let workspace = workspace()
            workspace.open(Self.repo, appFile)
            workspace.rememberScroll(CGPoint(x: 0, y: 50))
            workspace.open(Self.repo, otherFile)
            workspace.rememberScroll(CGPoint(x: 0, y: 90))
            workspace.selectTab(0)
            #expect(workspace.activeScroll == CGPoint(x: 0, y: 50))
            #expect(workspace.tabs[1].scroll == CGPoint(x: 0, y: 90))
        }

        @Test func scrollWithoutAnActiveTabIsZeroAndIgnored() {
            let workspace = workspace()
            workspace.rememberScroll(CGPoint(x: 0, y: 70))
            #expect(workspace.activeScroll == .zero)
        }

        @Test func scrollRememberedWhileTheActiveTabsContentIsStillLoadingIsIgnored() async {
            let workspace = workspace()
            workspace.open(Self.repo, appFile)
            workspace.open(Self.repo, otherFile)
            // Tab 0 is selected, but the document on screen is still tab 1's.
            workspace.selectTab(0)
            workspace.rememberScroll(CGPoint(x: 0, y: 500))
            #expect(workspace.activeScroll == .zero)

            _ = await waitUntil { workspace.content?.document?.firstLine == "let value1 = 1" }
            workspace.rememberScroll(CGPoint(x: 0, y: 500))
            #expect(workspace.activeScroll == CGPoint(x: 0, y: 500))
        }
    }

}
