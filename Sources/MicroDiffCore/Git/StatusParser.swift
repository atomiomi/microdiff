import Foundation

package enum StatusParser {
    /// Parses the output of `git status --porcelain=v2 --branch -z --untracked-files=all`.
    ///
    /// Records are NUL-terminated. Header records start with "# ":
    /// - `# branch.oid <oid>` or `# branch.oid (initial)` (no commits yet -> `headOID` nil)
    /// - `# branch.head <name>` or `# branch.head (detached)` (-> `branch` nil)
    /// - `# branch.upstream <name>` (the branch it follows; absent without one) -> `upstream`
    /// - `# branch.ab +<ahead> -<behind>` (only with an upstream) -> `isAhead`, `isBehind`
    /// - other headers are ignored.
    ///
    /// Entry records:
    /// - `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`
    /// - `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>` followed by ONE MORE NUL-terminated record: the original path
    /// - `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>`
    /// - `? <path>` (untracked), `! <path>` (ignored: goes to `RepoStatus.ignored`, directories keep git's trailing slash)
    ///   An untracked path ending in `/` is a folder git does not walk into: a nested git repository. It goes to
    ///   `RepoStatus.nestedRepoCandidates` (trailing slash kept), never to `changes`.
    /// Paths may contain spaces: the path is everything after the fixed number of space-separated fields.
    ///
    /// `<sub>` is `N...` for normal files. For submodules it is `S<c><m><u>` with `C`/`M`/`U` or `.` in each slot.
    /// Submodule records go to `RepoStatus.submodules`, never to `changes`.
    ///
    /// Mapping of `XY` (X = staged, Y = unstaged, `.` = unchanged) to one `ChangeKind` versus HEAD:
    /// - `u` record                         -> conflicted
    /// - `?` record                         -> added, isUntracked = true
    /// - X == "A" and Y == "D"              -> skipped (never existed in HEAD, gone again)
    /// - Y == "D" or X == "D"               -> deleted (for type-2 records the path is the ORIGINAL path, oldPath nil)
    /// - type-2 record with X == "R"        -> renamed, `path` = new path, `oldPath` = original path
    /// - X == "A" or X == "C"               -> added
    /// - anything else                      -> modified
    ///
    /// If the same path appears as both deleted and untracked (deleted in the index, re-created on disk),
    /// the result is a single `modified` entry at the position of the first one.
    /// Malformed records are skipped; the parser never crashes.
    package static func parse(_ data: Data) -> RepoStatus {
        var status = RepoStatus()
        // Only deleted entries can be merged with a later untracked record, and there are few of them.
        var deletedAt: [String: Int] = [:]

        data.withUnsafeBytes { raw in
            var reader = RecordReader(bytes: raw.bindMemory(to: UInt8.self))
            while let rec = reader.next() {
                guard let first = rec.first else { continue }
                switch first {
                case UInt8(ascii: "#"):
                    parseHeader(rec, into: &status)
                case UInt8(ascii: "?"):
                    guard rec.count > 2, rec[1] == space else { continue }
                    let path = string(rec, from: 2)
                    if rec[rec.count - 1] == UInt8(ascii: "/") {
                        status.nestedRepoCandidates.append(path)
                    } else if let index = deletedAt[path] {
                        status.changes[index].kind = .modified
                        deletedAt[path] = nil
                    } else {
                        status.changes.append(FileChange(path: path, kind: .added, isUntracked: true))
                    }
                case UInt8(ascii: "!"):
                    guard rec.count > 2, rec[1] == space else { continue }
                    status.ignored.append(string(rec, from: 2))
                case UInt8(ascii: "1"):
                    guard let entry = Entry(rec, pathSpaces: 8) else { continue }
                    if entry.sub.0 == UInt8(ascii: "S") {
                        status.submodules.append(SubmoduleState(
                            path: entry.path,
                            commitChanged: entry.sub.1 == UInt8(ascii: "C"),
                            hasModifiedContent: entry.sub.2 == UInt8(ascii: "M"),
                            hasUntrackedContent: entry.sub.3 == UInt8(ascii: "U")))
                    } else if let kind = kind(x: entry.x, y: entry.y, isRename: false) {
                        append(FileChange(path: entry.path, kind: kind), deletedAt: &deletedAt, to: &status)
                    }
                case UInt8(ascii: "2"):
                    guard let entry = Entry(rec, pathSpaces: 9) else { continue }
                    // The original path is its own record; without it the entry is truncated.
                    guard let original = reader.next(), !original.isEmpty else { continue }
                    let oldPath = string(original, from: 0)
                    guard let kind = kind(x: entry.x, y: entry.y, isRename: true) else { continue }
                    switch kind {
                    case .deleted:
                        append(FileChange(path: oldPath, kind: .deleted), deletedAt: &deletedAt, to: &status)
                    case .renamed:
                        append(FileChange(path: entry.path, oldPath: oldPath, kind: .renamed), deletedAt: &deletedAt, to: &status)
                    default:
                        append(FileChange(path: entry.path, kind: kind), deletedAt: &deletedAt, to: &status)
                    }
                case UInt8(ascii: "u"):
                    guard let entry = Entry(rec, pathSpaces: 10) else { continue }
                    status.changes.append(FileChange(path: entry.path, kind: .conflicted))
                default:
                    continue
                }
            }
        }
        return status
    }

    private static let space = UInt8(ascii: " ")

    private static func kind(x: UInt8, y: UInt8, isRename: Bool) -> ChangeKind? {
        let a = UInt8(ascii: "A"), d = UInt8(ascii: "D")
        if x == a && y == d { return nil }
        if x == d || y == d { return .deleted }
        if isRename && x == UInt8(ascii: "R") { return .renamed }
        if x == a || x == UInt8(ascii: "C") { return .added }
        return .modified
    }

    private static func append(_ change: FileChange, deletedAt: inout [String: Int], to status: inout RepoStatus) {
        if change.kind == .deleted { deletedAt[change.path] = status.changes.count }
        status.changes.append(change)
    }

    private static func parseHeader(_ rec: UnsafeBufferPointer<UInt8>, into status: inout RepoStatus) {
        if hasPrefix(rec, "# branch.oid ") {
            let value = string(rec, from: 13)
            status.headOID = value == "(initial)" ? nil : value
        } else if hasPrefix(rec, "# branch.head ") {
            let value = string(rec, from: 14)
            status.branch = value == "(detached)" ? nil : value
        } else if hasPrefix(rec, "# branch.upstream ") {
            status.upstream = string(rec, from: 18)
        } else if hasPrefix(rec, "# branch.ab +") {
            // "+<ahead> -<behind>"
            let counts = string(rec, from: 13).split(separator: " ")
            guard counts.count == 2, let ahead = Int(counts[0]), let behind = Int(counts[1].dropFirst()) else { return }
            status.isAhead = ahead > 0
            status.isBehind = behind > 0
        }
    }

    private static func hasPrefix(_ bytes: UnsafeBufferPointer<UInt8>, _ prefix: StaticString) -> Bool {
        let n = prefix.utf8CodeUnitCount
        guard bytes.count >= n, let base = bytes.baseAddress else { return false }
        return memcmp(base, prefix.utf8Start, n) == 0
    }

    private static func string(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: bytes[start...]), as: UTF8.self)
    }

    /// The fixed leading fields of a "1", "2" or "u" record.
    private struct Entry {
        let x: UInt8
        let y: UInt8
        /// The 4-byte submodule field, e.g. "N..." or "SCMU".
        let sub: (UInt8, UInt8, UInt8, UInt8)
        let path: String

        init?(_ rec: UnsafeBufferPointer<UInt8>, pathSpaces: Int) {
            // "<t> <X><Y> <s s s s> " is 10 bytes before the first variable field.
            guard rec.count > 10, rec[1] == StatusParser.space, rec[4] == StatusParser.space, rec[9] == StatusParser.space else { return nil }
            var seen = 0
            var start = 0
            for i in 0..<rec.count where rec[i] == StatusParser.space {
                seen += 1
                if seen == pathSpaces {
                    start = i + 1
                    break
                }
            }
            guard seen == pathSpaces, start < rec.count else { return nil }
            x = rec[2]
            y = rec[3]
            sub = (rec[5], rec[6], rec[7], rec[8])
            path = StatusParser.string(rec, from: start)
        }
    }

    /// Splits a buffer on NUL without copying.
    private struct RecordReader {
        let bytes: UnsafeBufferPointer<UInt8>
        var pos = 0

        mutating func next() -> UnsafeBufferPointer<UInt8>? {
            guard pos < bytes.count, let base = bytes.baseAddress else { return nil }
            var end = bytes.count
            if let hit = memchr(base + pos, 0, end - pos) {
                end = base.distance(to: UnsafePointer(hit.assumingMemoryBound(to: UInt8.self)))
            }
            let record = UnsafeBufferPointer(rebasing: bytes[pos..<end])
            pos = end + 1
            return record
        }
    }
}
