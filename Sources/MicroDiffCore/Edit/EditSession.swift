/// A disk version that disagrees with unsaved edits.
package enum DiskConflict: Sendable, Equatable {
    case changed
    case deleted
}

/// What the UI must do after `EditSession.diskDidChange`.
package enum DiskOutcome: Sendable, Equatable {
    /// Nothing to do (same disk version, or only the remembered stamp changed).
    case nothing
    /// Replace the editor text with this (the session is clean).
    case reload(String)
    /// The editor already shows the disk text; the session just became clean.
    case becameClean
    /// Show the "changed on disk" / "deleted on disk" strip (`session.conflict`).
    case conflict(DiskConflict)
    /// The file is gone and nothing was unsaved: leave edit mode.
    case fileDeleted
}

/// State of one open file in edit mode. No I/O: the caller passes in what it read from disk.
package struct EditSession: Sendable {
    package private(set) var savedText: String
    package private(set) var format: FileFormat
    package private(set) var isDirty = false
    package private(set) var conflict: DiskConflict?

    /// The newest disk version looked at (saved, loaded, or reported by `diskDidChange`), even when it was a conflict.
    private var lastSeen: DiskObservation
    /// UTF-16 length of `savedText`, the unit of `NSTextStorage.length`.
    private var savedLength: Int
    /// The disk text behind a `.changed` conflict, so `reload()` needs no I/O.
    private var pending: EditableText?

    package init(loaded: EditableText) {
        savedText = loaded.text
        format = loaded.format
        lastSeen = .present(loaded.stamp)
        savedLength = loaded.text.utf16.count
    }

    /// Call on every edit. `length` is the editor text's UTF-16 length. `text` is only called when the length equals
    /// the saved length (the only case where the text can be equal), so typing in a big file stays O(1).
    package mutating func textDidChange(length: Int, text: () -> String) {
        isDirty = length != savedLength || !Self.sameBytes(text(), savedText)
    }

    /// Call after a successful `EditFile.save` of `text`. My version wins: dirty and conflict are cleared.
    package mutating func didSave(text: String, stamp: DiskStamp) {
        savedText = text
        savedLength = text.utf16.count
        lastSeen = .present(stamp)
        isDirty = false
        conflict = nil
        pending = nil
    }

    /// Call after a file-watcher event. `readDisk` is only called when the disk version is new and present; return nil
    /// when it cannot be loaded (the event is then ignored). `currentText` is only called when dirty.
    package mutating func diskDidChange(
        _ disk: DiskObservation, currentText: () -> String, readDisk: () -> EditableText?
    ) -> DiskOutcome {
        guard disk != lastSeen else { return .nothing }
        switch disk {
        case .missing:
            lastSeen = disk
            pending = nil
            guard isDirty else { return .fileDeleted }
            conflict = .deleted
            return .conflict(.deleted)
        case .present:
            guard let new = readDisk() else { return .nothing }
            lastSeen = disk
            if Self.sameBytes(new.text, savedText) {
                format = new.format
                conflict = nil
                pending = nil
                return .nothing
            }
            if !isDirty {
                accept(new)
                return .reload(new.text)
            }
            if Self.sameBytes(new.text, currentText()) {
                accept(new)
                return .becameClean
            }
            conflict = .changed
            pending = new
            return .conflict(.changed)
        }
    }

    /// "Reload": discard my edits and take the disk text, which the UI puts in the editor. Nil when there is nothing
    /// to take (no conflict, or the file was deleted: then leave edit mode instead).
    package mutating func reload() -> String? {
        guard conflict == .changed, let new = pending else { return nil }
        accept(new)
        return new.text
    }

    /// "Keep mine": stay dirty and hide the strip. The same disk version does not raise it again.
    package mutating func keepMine() {
        conflict = nil
        pending = nil
    }

    private mutating func accept(_ new: EditableText) {
        savedText = new.text
        savedLength = new.text.utf16.count
        format = new.format
        isDirty = false
        conflict = nil
        pending = nil
    }

    /// Swift `==` treats canonically equivalent strings as equal; the files would still differ.
    private static func sameBytes(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }
}
