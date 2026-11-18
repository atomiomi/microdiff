import MicroDiffCore
import Testing
@testable import MicroDiffUI

extension UITests {
    @MainActor
    struct TreeRowStyleTests {
        private func file(
            _ name: String = "a.txt", change: ChangeKind? = nil, ignored: Bool = false
        ) -> TreeRow {
            TreeRow(
                id: "0|f|\(name)", kind: .file, depth: 1, name: name, path: name, repoIndex: 0,
                change: change.map { FileChange(path: name, kind: $0, isUntracked: $0 == .added) }, isIgnored: ignored)
        }

        private func dir(
            _ name: String = "src", expanded: Bool = false, mark: ChangeKind? = nil, ignored: Bool = false, submodule: Bool = false,
            nestedRepo: Bool = false
        ) -> TreeRow {
            TreeRow(
                id: "0|d|\(name)", kind: .directory, depth: 1, name: name, path: name, repoIndex: 0, isExpanded: expanded,
                isSubmodule: submodule, dirMark: mark, isIgnored: ignored, isNestedRepo: nestedRepo)
        }

        private func repo(submodule: Bool = false) -> TreeRow {
            TreeRow(id: "0|r|", kind: .repo, depth: 0, name: "project", path: "", repoIndex: 0, isSubmodule: submodule)
        }

        private func style(_ row: TreeRow, _ tab: TreeView.Style = .files, selected: Bool = false) -> TreeRowStyle {
            TreeRowStyle(row: row, tab: tab, isSelected: selected)
        }

        // MARK: Nested repositories

        @Test func nestedRepoFolderUsesTheRepoIconAndASubmoduleLikeLetter() {
            let plain = style(dir("inner", nestedRepo: true))
            #expect(plain.icon == .repo && plain.marker == .none)
            #expect(style(dir("inner", expanded: true, nestedRepo: true)).icon == .repo)
            let marked = style(dir("inner", mark: .modified, nestedRepo: true))
            #expect(marked.icon == .repo)
            #expect(marked.nameInk == .yellow && marked.marker == .letter(ChangeKind.modified.letter, .yellow))
        }

        @Test func submoduleFolderKeepsItsIconAndAPlainFolderItsDot() {
            #expect(style(dir("lib", submodule: true)).icon == .submodule)
            #expect(style(dir("lib", mark: .added, submodule: true)).marker == .letter(ChangeKind.added.letter, .green))
            #expect(style(dir("src")).icon == .folder)
            #expect(style(dir("src", mark: .added)).marker == .dot(.green))
        }

        @Test func ignoredNestedFolderIsDimmedLikeAnyIgnoredFolder() {
            let result = style(dir("inner", ignored: true))
            #expect(result.icon == .folder && result.nameInk == .ignored && result.iconAlpha == 0.5)
        }

        @Test func nestedRepoSectionHeaderUsesTheRepoIconAndSubmoduleSectionTheSubmoduleIcon() {
            #expect(style(repo(submodule: false), .changes).icon == .repo)
            #expect(style(repo(submodule: true), .changes).icon == .submodule)
        }

        // MARK: Files tab, files

        @Test(arguments: [
            (ChangeKind.modified, Ink.yellow), (.added, .green), (.renamed, .blue), (.conflicted, .red), (.deleted, .red),
        ])
        func filesTabNameAndLetterUseTheStatusColor(kind: ChangeKind, ink: Ink) {
            for selected in [false, true] {
                let result = style(file(change: kind), selected: selected)
                #expect(result.nameInk == ink)
                #expect(result.marker == .letter(kind.letter, ink))
                #expect(!result.strikethrough)
            }
        }

        @Test func filesTabPlainFileIsMidAndSelectedIsMainText() {
            #expect(style(file()).nameInk == .mid)
            #expect(style(file(), selected: true).nameInk == .fg)
            #expect(style(file()).marker == .none)
        }

        @Test func filesTabIgnoredFileIsDimmedButWinsNothingOverAChange() {
            let ignored = style(file(ignored: true))
            #expect(ignored.nameInk == .ignored)
            #expect(ignored.iconAlpha == 0.5)
            #expect(style(file(ignored: true), selected: true).nameInk == .fg)
            let changed = style(file(change: .added, ignored: true))
            #expect(changed.nameInk == .green)
            #expect(changed.iconAlpha == 0.5)
        }

        @Test func normalRowsHaveFullIconAlpha() {
            #expect(style(file()).iconAlpha == 1)
            #expect(style(dir()).iconAlpha == 1)
            #expect(style(repo()).iconAlpha == 1)
        }

        @Test func fileIconComesFromTheFileName() {
            #expect(style(file("App.vue")).icon == FileIcon.forFile(named: "App.vue"))
            #expect(style(file("package.json")).icon == FileIcon.forFile(named: "package.json"))
        }

        @Test func selectionDoesNotChangeTheIcon() {
            #expect(style(file("a.ts"), selected: true).icon == style(file("a.ts")).icon)
            #expect(style(file("a.ts"), selected: true).iconAlpha == 1)
        }

        // MARK: Files tab, folders

        @Test(arguments: [(ChangeKind.modified, Ink.yellow), (.added, .green), (.renamed, .blue), (.deleted, .red), (.conflicted, .red)])
        func folderWithAMarkGetsColorAndADot(kind: ChangeKind, ink: Ink) {
            let result = style(dir(mark: kind))
            #expect(result.nameInk == ink)
            #expect(result.marker == .dot(ink))
        }

        @Test func foldersWithoutMarkAreMid() {
            let result = style(dir())
            #expect(result.nameInk == .mid)
            #expect(result.marker == .none)
        }

        @Test func ignoredFolderIsDimWithADimIcon() {
            let result = style(dir(ignored: true))
            #expect(result.nameInk == .ignored)
            #expect(result.iconAlpha == 0.5)
            #expect(result.marker == .none)
        }

        @Test func folderIconFollowsExpansion() {
            #expect(style(dir(expanded: false)).icon == .folder)
            #expect(style(dir(expanded: true)).icon == .folderOpen)
        }

        @Test func submoduleFolderShowsALetterNotADot() {
            let marked = style(dir(mark: .modified, submodule: true))
            #expect(marked.icon == .submodule)
            #expect(marked.marker == .letter("M", .yellow))
            #expect(marked.nameInk == .yellow)
            let plain = style(dir(expanded: true, submodule: true))
            #expect(plain.icon == .submodule)
            #expect(plain.marker == .none)
        }

        // MARK: Root and repo rows

        @Test func rootRowUsesMainTextAndTheRepoIcon() {
            for tab in [TreeView.Style.files, .changes] {
                let result = style(repo(), tab)
                #expect(result.nameInk == .fg)
                #expect(result.icon == .repo)
                #expect(result.marker == .none)
            }
        }

        @Test func submoduleSectionUsesTheSubmoduleIcon() {
            #expect(style(repo(submodule: true), .changes).icon == .submodule)
            #expect(style(repo(submodule: true), .files).icon == .submodule)
        }

        // MARK: Changes tab

        @Test(arguments: [ChangeKind.modified, .added, .renamed, .conflicted])
        func changesTabNamesAreMidAndSelectedIsMainText(kind: ChangeKind) {
            #expect(style(file(change: kind), .changes).nameInk == .mid)
            #expect(style(file(change: kind), .changes, selected: true).nameInk == .fg)
            #expect(style(file(change: kind), .changes).marker == .letter(kind.letter, Ink.change(kind)))
            #expect(!style(file(change: kind), .changes).strikethrough)
        }

        @Test func changesTabDeletedFileIsQuietAndStruckThrough() {
            let result = style(file(change: .deleted), .changes)
            #expect(result.nameInk == .dim)
            #expect(result.strikethrough)
            #expect(result.marker == .letter("D", .red))
            let selected = style(file(change: .deleted), .changes, selected: true)
            #expect(selected.nameInk == .fg)
            #expect(selected.strikethrough)
        }

        @Test func changesTabFoldersAreMidWithoutAMarker() {
            let result = style(dir(expanded: true), .changes)
            #expect(result.nameInk == .mid)
            #expect(result.marker == .none)
            #expect(result.icon == .folderOpen)
        }
    }
}
