import AppKit
import MicroDiffCore
import MicroDiffTestSupport

@testable import MicroDiffUI

// Helpers for the row menu tests. No `import Testing` here (it cannot be combined with Foundation in one file).

private struct FakeTrashError: LocalizedError {
    var errorDescription: String? { "the Trash is full" }
}

/// Stands in for Finder and the Trash: records what was revealed and trashed. A trashed item is moved into a
/// folder of its own, so it really leaves the opened folder and nothing reaches the user's Trash.
@MainActor
final class FakeFileActions {
    private(set) var revealed: [String] = []
    private(set) var trashed: [String] = []
    /// The next move to the Trash fails.
    var failsToTrash = false
    private let bin = TempDir(prefix: "microdiff-bin")

    var fileActions: FileActions {
        FileActions(
            reveal: { self.revealed.append($0) },
            trash: { path in
                if self.failsToTrash { throw FakeTrashError() }
                self.trashed.append(path)
                try FileManager.default.moveItem(atPath: path, toPath: self.bin.path + "/" + UUID().uuidString)
            })
    }
}

/// A controller (never shown) with fake prompts and fake file actions, on `path`, scanned, in the given sidebar tab.
@MainActor
func menuController(
    _ path: String, tab: SidebarTab, prompts: FakePrompts = FakePrompts(), actions: FakeFileActions = FakeFileActions()
) -> MainWindowController {
    let controller = editController(path, prompts: prompts)
    controller.fileActions = actions.fileActions
    controller.workspace.selectSidebarTab(tab)
    return controller
}

/// A menu as text: its titles in order, "-" for a separator, " (disabled)" after a dimmed item.
func summary(_ menu: NSMenu?) -> [String] {
    (menu?.items ?? []).map { $0.isSeparatorItem ? "-" : $0.title + ($0.isEnabled ? "" : " (disabled)") }
}

@MainActor
extension MainWindowController {
    /// The row menu of the row at `path` in the current sidebar tab.
    func rowMenu(_ path: String, kind: TreeRowKind? = nil) -> NSMenu? {
        workspace.row(path: path, kind: kind).flatMap { menu(for: $0) }
    }

    /// Clicks the menu item with this title.
    func choose(_ title: String, in menu: NSMenu?) {
        guard let item = menu?.items.first(where: { $0.title == title }), let action = item.action else { return }
        _ = NSApp.sendAction(action, to: item.target, from: item)
    }
}

/// Makes a symbolic link at `link` to `target`.
func symlink(_ target: String, at link: String) {
    try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
}

/// The keys of the delete tests.
enum DeleteKey {
    case backspace, forwardDelete

    var code: UInt16 { self == .backspace ? 51 : 117 }
    var characters: String { self == .backspace ? "\u{7f}" : "\u{f728}" }
}

@MainActor
extension MainWindowController {
    /// A key press the way the window delivers it: key equivalents first, then the first responder.
    func press(_ key: DeleteKey, modifiers: NSEvent.ModifierFlags = []) {
        pressKey(key.code, characters: key.characters, modifiers: modifiers)
    }

    func pressKey(_ code: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []) {
        let event = Event.key(code, characters: characters, modifiers: modifiers)
        if !window.performKeyEquivalent(with: event) { window.firstResponder?.keyDown(with: event) }
    }

    /// A click on a row of the files tab, the way the tree gets it: the tree takes the keyboard, then handles the click.
    func click(_ path: String, kind: TreeRowKind? = nil, clicks: Int = 1) {
        focusSidebar()
        let tree = rootView.tree
        guard let index = tree.rows.firstIndex(where: { $0.path == path && (kind == nil || $0.kind == kind) }) else { return }
        let top = 8 + (index == 0 ? 0 : Theme.repoBandHeight + CGFloat(index - 1) * Theme.treeRowHeight)
        tree.mouse(.down, at: CGPoint(x: 40, y: top + 10), event: Event.mouse(clicks: clicks))
    }

    func doubleClick(_ path: String, kind: TreeRowKind? = nil) {
        click(path, kind: kind)
        click(path, kind: kind, clicks: 2)
    }

    var treeHasKeyboard: Bool { window.firstResponder === rootView.tree }
    var codeViewHasKeyboard: Bool { window.firstResponder === rootView.codeView }

    func focusSidebar() { _ = window.makeFirstResponder(rootView.tree) }
    func focusCode() { _ = window.makeFirstResponder(rootView.codeView) }
}

/// A repository with a few text files, a code file and folders (one nested): `a.txt`, `b.txt`, `code.swift`,
/// `dir/inner.txt`, `dir/sub/deep.swift`. Rows of the files tab: root, `dir`, `a.txt`, `b.txt`, `code.swift`.
@MainActor
func treeRepo() -> TestRepo {
    let repo = TestRepo()
    repo.write("a.txt", "alpha\nbeta\n")
    repo.write("b.txt", "one\ntwo\n")
    repo.write("code.swift", "let x = 1\n")
    repo.write("dir/inner.txt", "inner\n")
    repo.write("dir/sub/deep.swift", "let y = 2\n")
    repo.commitAll("first")
    return repo
}
