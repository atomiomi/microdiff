import AppKit

/// What a right click on a sidebar row can do. Adding an item: a case here, its title, a line in
/// `Workspace.menuEntries(for:)` and a case in `MainWindowController.perform`.
enum RowAction: Equatable {
    case newFile
    case showInFinder
    case moveToTrash

    var title: String {
        switch self {
        case .newFile: "New File…"
        case .showInFinder: "Show in Finder"
        case .moveToTrash: "Move to Trash"
        }
    }
}

extension RowAction {
    /// Shown beside the item. The menu is not in the menu bar, so this is no window-wide shortcut.
    var keyEquivalent: String { self == .moveToTrash ? "\u{8}" : "" }
}

enum RowMenuEntry: Equatable {
    case item(RowAction, isEnabled: Bool)
    case separator
}

/// Why a new file was not made; `message` is told to the user.
struct NewFileError: Error {
    var message: String
}

/// The real side effects of the row menu, behind a seam: the app reveals and trashes for real, tests record.
struct FileActions {
    /// Brings Finder forward with the item selected in its parent folder.
    var reveal: (_ path: String) -> Void
    /// Moves the item to the Trash, where the user can put it back.
    var trash: (_ path: String) throws -> Void

    static let system = FileActions(
        reveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0)]) },
        // Not a directory URL: a link to a folder is trashed as the link, not as the folder.
        trash: { try FileManager.default.trashItem(at: URL(fileURLWithPath: $0, isDirectory: false), resultingItemURL: nil) })
}
