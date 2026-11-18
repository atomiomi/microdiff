import Foundation

/// A file as the editor sees it: BOM stripped, CRLF turned into LF.
package struct EditableText: Sendable, Equatable {
    package var text: String
    package var format: FileFormat
    /// The disk version this text was read from (taken before reading, so a change during the read is noticed later).
    package var stamp: DiskStamp

    package init(text: String, format: FileFormat, stamp: DiskStamp) {
        self.text = text
        self.format = format
        self.stamp = stamp
    }
}

/// What `EditFile.save` must put back around the editor text.
package struct FileFormat: Sendable, Equatable {
    package var hasBOM: Bool
    /// Every line ending in the file was CRLF. The editor text then uses LF.
    package var usesCRLF: Bool

    package init(hasBOM: Bool = false, usesCRLF: Bool = false) {
        self.hasBOM = hasBOM
        self.usesCRLF = usesCRLF
    }
}

package enum EditFile {
    package static let maxBytes = 4 * 1024 * 1024

    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    package static func load(path: String) throws(EditError) -> EditableText {
        let (data, stamp) = try readBytes(path)
        var bytes = [UInt8](data)
        let hasBOM = bytes.starts(with: bom)
        if hasBOM { bytes.removeFirst(3) }
        let usesCRLF = allLineEndingsAreCRLF(bytes)
        if usesCRLF { bytes = collapseCRLF(bytes) }
        let text = String(decoding: bytes, as: UTF8.self)
        // Invalid input decodes to U+FFFD, so the re-encoded bytes differ.
        guard text.utf8.elementsEqual(bytes) else { throw .notEditable(.notUTF8) }
        return EditableText(text: text, format: FileFormat(hasBOM: hasBOM, usesCRLF: usesCRLF), stamp: stamp)
    }

    /// Writes atomically (temp file next to the target, then rename), keeps the permissions, and writes through a
    /// symlink to its target. Creates the file when it is gone, as long as its folder exists.
    package static func save(_ text: String, to path: String, format: FileFormat) throws(EditError) -> DiskStamp {
        let bytes = bytes(text, format: format)
        let target = resolved(path)
        var mode: mode_t = 0o644
        var existing = stat()
        if stat(target, &existing) == 0 { mode = existing.st_mode & 0o7777 }

        let dir = (target as NSString).deletingLastPathComponent
        var template = Array(("\(dir)/.microdiff-save-XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw map(errno) }
        let tempPath = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        var failure: Int32?
        if fchmod(fd, mode) != 0 { failure = errno }
        if failure == nil { failure = writeAll(fd, bytes) }
        if failure == nil, fsync(fd) != 0 { failure = errno }
        close(fd)
        if failure == nil, rename(tempPath, target) != 0 { failure = errno }
        if let failure {
            unlink(tempPath)
            throw map(failure)
        }
        guard case let .present(stamp)? = DiskObservation.observe(target) else { throw .writeFailed(errno: EIO) }
        return stamp
    }

    /// The file's bytes for the editor text: the byte order mark and CRLF line endings put back.
    package static func bytes(_ text: String, format: FileFormat) -> [UInt8] {
        var bytes: [UInt8] = format.hasBOM ? bom : []
        bytes.reserveCapacity(text.utf8.count + 3)
        if format.usesCRLF {
            for byte in text.utf8 {
                if byte == 0x0A { bytes.append(0x0D) }
                bytes.append(byte)
            }
        } else {
            bytes.append(contentsOf: text.utf8)
        }
        return bytes
    }

    // MARK: - Private

    private static func readBytes(_ path: String) throws(EditError) -> (Data, DiskStamp) {
        var info = stat()
        guard stat(path, &info) == 0 else {
            throw .notEditable(errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable)
        }
        if info.st_mode & S_IFMT == S_IFDIR { throw .notEditable(.directory) }
        let buffer: TextBuffer
        do {
            buffer = try TextBuffer(contentsOfFile: path, maxBytes: maxBytes)
        } catch TextBuffer.LoadError.tooLarge {
            throw .notEditable(.tooLarge)
        } catch {
            throw .notEditable(.unreadable)
        }
        if buffer.isBinary { throw .notEditable(.binary) }
        return (buffer.data, DiskStamp(info))
    }

    private static func allLineEndingsAreCRLF(_ bytes: [UInt8]) -> Bool {
        var seen = false
        for (i, byte) in bytes.enumerated() where byte == 0x0A {
            guard i > 0, bytes[i - 1] == 0x0D else { return false }
            seen = true
        }
        return seen
    }

    private static func collapseCRLF(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        for byte in bytes {
            if byte == 0x0A { out.removeLast() }
            out.append(byte)
        }
        return out
    }

    private static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Int32? {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n < 0 {
                if errno == EINTR { continue }
                return errno
            }
            offset += n
        }
        return nil
    }

    private static func map(_ code: Int32) -> EditError {
        switch code {
        case ENOENT, ENOTDIR: .folderMissing
        case EACCES, EPERM, EROFS: .permissionDenied
        default: .writeFailed(errno: code)
        }
    }
}
