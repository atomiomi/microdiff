import AppKit
import MicroDiffCore
import MicroDiffTestSupport
import Testing

@testable import MicroDiffUI

extension UITests {
    /// "New File…" in the row menu. The name comes through the `Prompts` seam; files are made for real, inside the test's repository.
    @MainActor
    @Suite
    struct NewFileTests {
        private func expand(_ controller: MainWindowController, _ paths: String...) {
            for path in paths { controller.workspace.toggle(controller.workspace.row(path: path)!) }
        }

        // MARK: The question

        @Test func theQuestionNamesTheFolderAFileRowAndTheRoot() {
            let repo = Fixture.changesRepo()
            let prompts = FakePrompts(names: [nil, nil, nil, nil])
            let controller = menuController(repo.path, tab: .files, prompts: prompts)
            expand(controller, "src", "src/ui")
            controller.choose("New File…", in: controller.rowMenu("src/ui", kind: .directory))
            controller.choose("New File…", in: controller.rowMenu("src/app.swift"))
            controller.choose("New File…", in: controller.rowMenu("", kind: .repo))
            controller.choose("New File…", in: controller.rowMenu("README.md"))
            let root = (repo.path as NSString).lastPathComponent
            #expect(prompts.nameQuestions == ["New file in “src/ui”", "New file in “src”", "New file in “\(root)”", "New file in “\(root)”"])
        }

        @Test func cancellingCreatesNothing() async {
            let repo = Fixture.changesRepo()
            let controller = menuController(repo.path, tab: .files, prompts: FakePrompts(names: [nil]))
            let before = entries(repo.path + "/src")
            controller.choose("New File…", in: controller.rowMenu("src", kind: .directory))
            await waitIdle(controller.workspace)
            #expect(entries(repo.path + "/src") == before)
            #expect(controller.workspace.tabs.isEmpty)
        }

        // MARK: Creating

        @Test func aPlainNameMakesAnEmptyFileShowsItAndOpensItForEditing() {
            let repo = Fixture.changesRepo()
            let controller = menuController(repo.path, tab: .files, prompts: FakePrompts(names: ["  note.txt \n"]))
            controller.choose("New File…", in: controller.rowMenu("", kind: .repo))
            let path = repo.path + "/note.txt"
            #expect(fileBytes(path) == [])
            let row = controller.workspace.row(path: "note.txt")
            #expect(row != nil)
            #expect(controller.workspace.selectedRowID == row?.id)
            #expect(controller.rootView.tree.selectedID == row?.id)
            #expect(controller.workspace.tabPaths == [path])
            #expect(controller.workspace.tabs[0].isPreview == false)
            #expect(controller.workspace.tabs[0].mode == .edit)
            #expect(controller.isEditorFirstResponder)
        }

        @Test func aFileRowMakesTheFileInItsFolder() {
            let repo = Fixture.changesRepo()
            let controller = menuController(repo.path, tab: .files, prompts: FakePrompts(names: ["x.txt"]))
            expand(controller, "src")
            controller.choose("New File…", in: controller.rowMenu("src/app.swift"))
            #expect(exists(repo.path + "/src/x.txt"))
            #expect(!exists(repo.path + "/x.txt"))
        }

        @Test func aNestedNameMakesTheFoldersAndOpensThemAboveTheRow() {
            let repo = Fixture.changesRepo()
            let controller = menuController(repo.path, tab: .files, prompts: FakePrompts(names: ["a/b/note.txt"]))
            controller.choose("New File…", in: controller.rowMenu("src", kind: .directory))
            #expect(fileBytes(repo.path + "/src/a/b/note.txt") == [])
            let rows = controller.workspace.sidebarRows()
            #expect(rows.map(\.path).contains("src/a/b/note.txt"))
            #expect(controller.workspace.selectedRowID == rows.first { $0.path == "src/a/b/note.txt" }?.id)
        }

        @Test func theNewFileShowsUpInTheChangesTabAsNew() async {
            let repo = Fixture.changesRepo()
            let controller = menuController(repo.path, tab: .files, prompts: FakePrompts(names: ["fresh.txt"]))
            controller.choose("New File…", in: controller.rowMenu("", kind: .repo))
            #expect(await waitUntil { controller.workspace.snapshot?.repos.first?.changes.contains { $0.path == "fresh.txt" } == true })
            controller.workspace.selectSidebarTab(.changes)
            #expect(controller.workspace.row(path: "fresh.txt")?.change?.kind == .added)
            #expect(controller.workspace.tabs[0].mode == .edit)
        }

        // MARK: Refusals

        @Test(arguments: [
            ("", "Enter a file name."),
            ("   ", "Enter a file name."),
            ("docs/", "A file name cannot end in “/”."),
            ("/tmp/abs.txt", "Use a name relative to the folder."),
            ("../out.txt", "“../out.txt” would be outside the opened folder."),
            ("a/../../out.txt", "“a/../../out.txt” would be outside the opened folder."),
            ("README.md", "“README.md” already exists."),
            ("src", "“src” already exists."),
            ("src/app.swift", "“src/app.swift” already exists."),
        ])
        func aRefusedNameIsToldAndCreatesNothing(name: String, message: String) async {
            let repo = Fixture.changesRepo()
            let prompts = FakePrompts(names: [name])
            let controller = menuController(repo.path, tab: .files, prompts: prompts)
            let readme = fileText(repo.path + "/README.md")
            let before = entries(repo.path)
            let outside = entries((repo.path as NSString).deletingLastPathComponent)
            controller.choose("New File…", in: controller.rowMenu("", kind: .repo))
            #expect(prompts.messages == [message])
            await waitIdle(controller.workspace)
            #expect(entries(repo.path) == before)
            #expect(entries((repo.path as NSString).deletingLastPathComponent) == outside)
            #expect(entries(repo.path + "/src") == ["app.swift", "other.swift", "ui"])
            #expect(fileText(repo.path + "/README.md") == readme)
            #expect(controller.workspace.tabs.isEmpty)
        }

        @Test func anExistingFileIsNeverTouched() {
            let repo = Fixture.changesRepo()
            let prompts = FakePrompts(names: ["app.swift"])
            let controller = menuController(repo.path, tab: .files, prompts: prompts)
            expand(controller, "src")
            let before = fileBytes(repo.path + "/src/app.swift")
            controller.choose("New File…", in: controller.rowMenu("src", kind: .directory))
            #expect(prompts.messages == ["“app.swift” already exists."])
            #expect(fileBytes(repo.path + "/src/app.swift") == before)
        }
    }
}
