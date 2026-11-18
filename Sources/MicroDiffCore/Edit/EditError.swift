import Foundation

/// Why a file cannot be opened for editing.
package enum EditBlock: Sendable, Equatable {
    case missing
    case directory
    case binary
    case notUTF8
    case tooLarge
    case unreadable
}

/// A failure the UI can show as one sentence (`message`).
package enum EditError: Error, Sendable, Equatable {
    case notEditable(EditBlock)
    case folderMissing
    case permissionDenied
    case writeFailed(errno: Int32)

    package var message: String {
        switch self {
        case .notEditable(.missing): "File not found."
        case .notEditable(.directory): "This is a folder, not a file."
        case .notEditable(.binary): "Binary files cannot be edited."
        case .notEditable(.notUTF8): "Only UTF-8 text files can be edited."
        case .notEditable(.tooLarge): "File is too large to edit (limit 4 MB)."
        case .notEditable(.unreadable): "File cannot be read."
        case .folderMissing: "Cannot save: the folder no longer exists."
        case .permissionDenied: "Cannot save: permission denied."
        case let .writeFailed(code): "Cannot save: \(String(cString: strerror(code)))."
        }
    }
}
