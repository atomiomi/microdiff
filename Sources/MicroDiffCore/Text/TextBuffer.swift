import Foundation

/// Read-only text split into lines. Stores the raw bytes once plus one 32-bit offset per line,
/// so a 200k-line file costs its own size plus under 1 MB.
///
/// Line rules (same as git):
/// - "a\nb\n" has 2 lines, "a\nb" has 2 lines, "a\n\n" has 2 lines (the second is empty), "" has 0 lines.
/// - A line ends at "\n". A "\r" directly before that "\n" is not part of the line.
package struct TextBuffer: Sendable {
    package enum LoadError: Error, Sendable, Equatable {
        /// The file is larger than the allowed maximum.
        case tooLarge(bytes: Int)
        case unreadable
    }

    /// Files above this size are not loaded (see `init(contentsOfFile:maxBytes:)`).
    package static let defaultMaxBytes = 32 * 1024 * 1024

    package static let empty = TextBuffer(Data())

    /// One entry per line plus a sentinel: the sentinel is one past the last terminator
    /// (the buffer size, or the buffer size + 1 when the last line has no "\n"),
    /// so line `i` always ends right before `lineStarts[i + 1] - 1`.
    private let lineStarts: [UInt32]

    package let data: Data

    /// Length in bytes of the longest line, without terminators. 0 for an empty buffer.
    package let maxLineByteLength: Int

    /// True when a NUL byte appears in the first 8000 bytes (same heuristic git uses).
    package let isBinary: Bool

    package init(_ data: Data) {
        self.data = data
        var starts: [UInt32] = []
        var longest = 0
        var binary = false
        let count = data.count
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, count > 0 else { return }
            binary = memchr(base, 0, min(count, 8000)) != nil
            let bytes = raw.bindMemory(to: UInt8.self)
            starts.reserveCapacity(count / 32 + 2)
            starts.append(0)
            var pos = 0
            while pos < count {
                var end = count
                if let hit = memchr(base + pos, 0x0A, count - pos) {
                    end = base.distance(to: UnsafeRawPointer(hit))
                }
                var contentEnd = end
                if end < count, contentEnd > pos, bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
                longest = max(longest, contentEnd - pos)
                pos = end + 1
                starts.append(UInt32(clamping: pos))
            }
        }
        lineStarts = starts
        maxLineByteLength = longest
        isBinary = binary
    }

    /// Reads the whole file into memory (never memory-maps: a mapped file that gets truncated by another
    /// process would crash the app). Throws `.tooLarge` above `maxBytes`, `.unreadable` on any I/O error.
    package init(contentsOfFile path: String, maxBytes: Int = TextBuffer.defaultMaxBytes) throws {
        var info = stat()
        guard stat(path, &info) == 0 else { throw LoadError.unreadable }
        let size = Int(info.st_size)
        guard size <= maxBytes else { throw LoadError.tooLarge(bytes: size) }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { throw LoadError.unreadable }
        self.init(data)
    }

    package var byteCount: Int { data.count }

    package var lineCount: Int { max(lineStarts.count - 1, 0) }

    /// Byte range of line `index` (0-based) without its terminator. Precondition: 0 <= index < lineCount.
    package func lineRange(_ index: Int) -> Range<Int> {
        precondition(index >= 0 && index < lineCount, "line index out of range")
        let start = Int(lineStarts[index])
        var end = Int(lineStarts[index + 1]) - 1
        if end > start, end < data.count {
            let hasCR = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in raw[end - 1] == 0x0D }
            if hasCR { end -= 1 }
        }
        return start..<min(end, data.count)
    }

    /// Line `index` decoded as UTF-8. Invalid bytes become U+FFFD.
    package func line(_ index: Int) -> String {
        withLineBytes(index) { String(decoding: $0, as: UTF8.self) }
    }

    /// Calls `body` with the raw bytes of line `index`, without copying.
    package func withLineBytes<R>(_ index: Int, _ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        let range = lineRange(index)
        return try data.withUnsafeBytes { raw in
            try body(UnsafeBufferPointer(rebasing: raw.bindMemory(to: UInt8.self)[range]))
        }
    }
}
