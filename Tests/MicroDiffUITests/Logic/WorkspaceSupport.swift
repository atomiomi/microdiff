import AppKit
import MicroDiffCore
import MicroDiffTestSupport
import Testing
@testable import MicroDiffUI

extension DocumentContent {
    var document: TextDocument? {
        if case let .text(document) = self { return document }
        return nil
    }

    var message: String? {
        if case let .message(text) = self { return text }
        return nil
    }
}

extension TextDocument {
    /// First line of the text the document shows (the old text for a deleted file).
    var firstLine: String {
        kind == .deleted ? oldText.line(0) : newText.line(0)
    }

    var foldRows: [DiffRow] {
        (0..<rows.rowCount).map { rows.row(at: $0) }.filter { $0.kind == .fold }
    }
}

/// A workspace that has scanned the folder (without watchers or background work).
@MainActor
func scannedWorkspace(_ path: String) -> Workspace {
    let workspace = Workspace(path: path)
    workspace.scanNow()
    return workspace
}

@MainActor
extension Workspace {
    /// Opens a file of `repo` (repo-relative path) and loads it before returning.
    func open(_ repo: TestRepo, _ relative: String, mode: ViewMode = .diff, pin: Bool = true) {
        openFile(repo.path + "/" + relative, mode: mode, pin: pin, synchronously: true)
    }

    var activePath: String? { activeTab.map { tabs[$0].path } }
    var tabPaths: [String] { tabs.map(\.path) }
    var tabNames: [String] { tabs.map(\.title) }

    func row(path: String, kind: TreeRowKind? = nil) -> TreeRow? {
        sidebarRows().first { $0.path == path && (kind == nil || $0.kind == kind) }
    }
}
