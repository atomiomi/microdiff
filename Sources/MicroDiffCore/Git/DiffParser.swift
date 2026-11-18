import Foundation

/// One block of change, already normalized so it holds ONLY deleted and/or added lines (no context).
///
/// Numbering follows `git diff -U0`:
/// - `oldStart`/`newStart` are 1-based.
/// - Pure insertion (`oldCount == 0`): `oldStart` is the old line AFTER which the lines were added (0 = at the very top).
/// - Pure deletion (`newCount == 0`): `newStart` is the new line AFTER which the lines were removed (0 = at the very top).
package struct Hunk: Sendable, Hashable {
    package var oldStart: Int
    package var oldCount: Int
    package var newStart: Int
    package var newCount: Int
    /// Line indices of this hunk's deleted lines inside `FilePatch.deletedText`. `count == oldCount`.
    package var deletedLines: Range<Int>

    package init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, deletedLines: Range<Int>) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.deletedLines = deletedLines
    }
}

/// The parsed diff of a single file against HEAD.
package struct FilePatch: Sendable {
    /// Git reported "Binary files ... differ" (or a GIT binary patch).
    package var isBinary: Bool
    /// Sorted top to bottom. Never overlapping.
    package var hunks: [Hunk]
    /// Every deleted line of the patch, in order, without the leading "-". One line per deleted line.
    package var deletedText: TextBuffer

    package init(isBinary: Bool = false, hunks: [Hunk] = [], deletedText: TextBuffer = .empty) {
        self.isBinary = isBinary
        self.hunks = hunks
        self.deletedText = deletedText
    }

    package static let empty = FilePatch()
}

package enum DiffParser {
    /// Parses the output of `git diff --no-color --no-ext-diff -U0 ...` for ONE file.
    ///
    /// Must also accept patches that contain context lines (any `-U<n>`): a hunk with context is split into
    /// one `Hunk` per run of consecutive "-"/"+" lines, with `oldStart`/`newStart` computed to match what
    /// `-U0` would have printed. "\ No newline at end of file" lines are ignored. Header lines before the
    /// first "@@" (diff --git, index, ---, +++, rename from/to, similarity index, mode changes) are skipped.
    /// Empty input gives `FilePatch.empty`. Input that only has headers (e.g. a pure rename) gives no hunks.
    ///
    /// `deletedText` holds every deleted line followed by "\n" (a terminator after the last line too,
    /// so a trailing empty deleted line is not lost).
    package static func parse(_ data: Data) -> FilePatch {
        guard !data.isEmpty else { return .empty }
        var builder = Builder()
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let base = bytes.baseAddress else { return }
            var pos = 0
            while pos < bytes.count {
                var end = bytes.count
                if let hit = memchr(base + pos, 0x0A, end - pos) {
                    end = base.distance(to: UnsafePointer(hit.assumingMemoryBound(to: UInt8.self)))
                }
                builder.consume(UnsafeBufferPointer(rebasing: bytes[pos..<end]))
                pos = end + 1
            }
        }
        return builder.finish()
    }

    private struct Builder {
        var isBinary = false
        var hunks: [Hunk] = []
        var deleted: [UInt8] = []
        var deletedTotal = 0

        /// False until the first valid hunk header, and after a malformed one.
        var inHunk = false
        var sawHunk = false
        /// Next old / new line number to be consumed by the current hunk.
        var oldPos = 0
        var newPos = 0

        // The current run of "-"/"+" lines.
        var runActive = false
        var runOld = 0
        var runNew = 0
        var runDeleted = 0
        var runAdded = 0
        var runFirstDeleted = 0

        mutating func consume(_ line: UnsafeBufferPointer<UInt8>) {
            if isHunkHeader(line) {
                flush()
                if let h = parseHeader(line) {
                    inHunk = true
                    sawHunk = true
                    oldPos = h.oldCount == 0 ? h.oldStart + 1 : h.oldStart
                    newPos = h.newCount == 0 ? h.newStart + 1 : h.newStart
                } else {
                    inHunk = false
                }
                return
            }
            guard inHunk else {
                if !sawHunk, startsWith(line, "Binary files ") || startsWith(line, "GIT binary patch") {
                    isBinary = true
                }
                return
            }
            switch line.first {
            case UInt8(ascii: "-"):
                startRun()
                deleted.append(contentsOf: UnsafeBufferPointer(rebasing: line[1...]))
                deleted.append(0x0A)
                deletedTotal += 1
                runDeleted += 1
                oldPos += 1
            case UInt8(ascii: "+"):
                startRun()
                runAdded += 1
                newPos += 1
            case UInt8(ascii: " "), nil:
                // Some tools strip the space of an empty context line.
                flush()
                oldPos += 1
                newPos += 1
            default:
                // "\ No newline at end of file" and anything else git does not put in a hunk.
                break
            }
        }

        mutating func startRun() {
            guard !runActive else { return }
            runActive = true
            runOld = oldPos
            runNew = newPos
            runDeleted = 0
            runAdded = 0
            runFirstDeleted = deletedTotal
        }

        mutating func flush() {
            guard runActive else { return }
            runActive = false
            // -U0 numbering: an empty side points at the line BEFORE the change.
            hunks.append(Hunk(
                oldStart: runDeleted > 0 ? runOld : runOld - 1,
                oldCount: runDeleted,
                newStart: runAdded > 0 ? runNew : runNew - 1,
                newCount: runAdded,
                deletedLines: runFirstDeleted..<(runFirstDeleted + runDeleted)))
        }

        mutating func finish() -> FilePatch {
            flush()
            guard isBinary || !hunks.isEmpty else { return .empty }
            return FilePatch(isBinary: isBinary, hunks: hunks, deletedText: deleted.isEmpty ? .empty : TextBuffer(Data(deleted)))
        }
    }

    private static func isHunkHeader(_ line: UnsafeBufferPointer<UInt8>) -> Bool {
        line.count >= 2 && line[0] == UInt8(ascii: "@") && line[1] == UInt8(ascii: "@")
    }

    private static func startsWith(_ bytes: UnsafeBufferPointer<UInt8>, _ prefix: StaticString) -> Bool {
        let n = prefix.utf8CodeUnitCount
        guard bytes.count >= n, let base = bytes.baseAddress else { return false }
        return memcmp(base, prefix.utf8Start, n) == 0
    }

    /// Parses "@@ -a[,b] +c[,d] @@ ...". A missing count means 1.
    private static func parseHeader(_ line: UnsafeBufferPointer<UInt8>) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        var i = 0
        guard startsWith(line, "@@ -") else { return nil }
        i = 4
        guard let oldStart = number(line, &i) else { return nil }
        var oldCount = 1
        if i < line.count, line[i] == UInt8(ascii: ",") {
            i += 1
            guard let c = number(line, &i) else { return nil }
            oldCount = c
        }
        guard i + 1 < line.count, line[i] == UInt8(ascii: " "), line[i + 1] == UInt8(ascii: "+") else { return nil }
        i += 2
        guard let newStart = number(line, &i) else { return nil }
        var newCount = 1
        if i < line.count, line[i] == UInt8(ascii: ",") {
            i += 1
            guard let c = number(line, &i) else { return nil }
            newCount = c
        }
        return (oldStart, oldCount, newStart, newCount)
    }

    private static func number(_ line: UnsafeBufferPointer<UInt8>, _ i: inout Int) -> Int? {
        var value = 0
        var digits = 0
        while i < line.count, line[i] >= 0x30, line[i] <= 0x39 {
            value = value * 10 + Int(line[i] - 0x30)
            digits += 1
            i += 1
            if digits > 9 { return nil }
        }
        return digits > 0 ? value : nil
    }
}
