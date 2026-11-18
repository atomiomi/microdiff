import Foundation

package enum DiffRowKind: UInt8, Sendable, Hashable {
    /// An unchanged line.
    case context
    /// A line that exists only in the new text.
    case added
    /// A line that exists only in the old text.
    case deleted
    /// A collapsed run of unchanged lines ("18 unchanged lines").
    case fold
}

/// Gutter mark for a line in the read view.
package enum LineMark: UInt8, Sendable, Hashable {
    case none
    /// The line is new (its hunk removed nothing).
    case added
    /// The line replaced older lines (its hunk also removed something).
    case modified
}

/// One visible row of a diff or read view.
package struct DiffRow: Sendable, Hashable {
    package var kind: DiffRowKind
    /// - context / added: 0-based line index in the NEW text.
    /// - deleted: 0-based line index in `FilePatch.deletedText` (or in the old text for `deletedFile` documents).
    /// - fold: 0-based index of the first hidden line in the NEW text.
    package var line: Int
    /// fold: number of hidden lines. Every other kind: 1.
    package var count: Int
    /// Line number to print in the gutter (1-based). Nil prints nothing (deleted rows of a diff, fold rows).
    package var number: Int?
    /// Index into `FilePatch.hunks` for added/deleted rows of a diff. -1 otherwise.
    package var hunk: Int
    /// Only set by `DiffDocument.file`. `.none` everywhere else.
    package var mark: LineMark

    package init(kind: DiffRowKind, line: Int, count: Int = 1, number: Int? = nil, hunk: Int = -1, mark: LineMark = .none) {
        self.kind = kind
        self.line = line
        self.count = count
        self.number = number
        self.hunk = hunk
        self.mark = mark
    }
}

/// The list of rows a code view shows, with their vertical positions.
///
/// Stores runs of equal rows (a context, added or deleted run is one element, a fold is one element) plus prefix
/// arrays of row index and y, so memory is O(hunks + folds) and lookups are binary searches over runs.
package struct DiffDocument: Sendable {
    /// A maximal group of consecutive rows of one kind. A fold run is a single row that hides `count` lines.
    private struct Run: Sendable {
        var kind: DiffRowKind
        /// First line (see `DiffRow.line`) of the run.
        var firstLine: Int
        /// Rows of the run, or hidden lines for a fold.
        var count: Int
        var hunk: Int
        var mark: LineMark
        /// Whether rows print `line + 1` in the gutter.
        var numbered: Bool

        var rowCount: Int { kind == .fold ? 1 : count }
    }

    private var runs: [Run] = []
    /// `rowStart[i]` is the index of the first row of run i. One extra element holds the total row count.
    private var rowStart: [Int] = [0]
    /// `yStart[i]` is the top edge of run i. One extra element holds the content height.
    private var yStart: [Double] = [0]
    private var metrics = RowMetrics()
    /// Number of fold rows.
    package private(set) var foldCount = 0

    /// Unified diff: changed lines, `context` unchanged lines around each hunk, the rest collapsed into fold rows.
    ///
    /// With N = `newLineCount` and 1-based new line numbers:
    /// - A hunk with `newCount > 0` changes new lines `newStart ..< newStart + newCount` (added rows) and keeps
    ///   lines `newStart - context ... newStart + newCount - 1 + context` visible.
    /// - A pure deletion (`newCount == 0`) sits after new line `a = newStart` and keeps lines `a - context + 1 ... a + context` visible.
    /// - Visible ranges are clamped to `1...N` and merged. Visible lines that are not added are context rows.
    /// - Each maximal run of non-visible lines becomes ONE fold row (`line` = first hidden line index, `count` = run length),
    ///   including runs at the very top and bottom. A run shorter than `minFoldLines` is shown as context rows instead.
    ///   A fold whose `line` is in `expandedFolds` is shown as context rows instead.
    /// - A hunk's deleted rows come directly before its added rows. For a pure deletion they come directly after
    ///   the row of new line `newStart` (at the very top when `newStart == 0`).
    /// - Gutter numbers: context and added rows print their new line number; deleted and fold rows print nothing.
    /// - No hunks: every line is a context row (no folds).
    ///
    /// Patches that do not fit the file (stale hunks) are clamped, never trapped on. A fold is also split where
    /// deleted rows sit inside hidden lines (only possible with `context == 0`).
    package static func diff(
        patch: FilePatch,
        newLineCount: Int,
        context: Int = 3,
        minFoldLines: Int = 4,
        expandedFolds: Set<Int> = [],
        metrics: RowMetrics = RowMetrics()
    ) -> DiffDocument {
        let n = clampedCount(newLineCount)
        var builder = Builder(metrics: metrics)
        if patch.hunks.isEmpty {
            builder.append(kind: .context, line: 0, count: n, numbered: true)
            return builder.finish()
        }

        let ctx = min(max(context, 0), n)
        // Place every hunk first: where its deleted rows go and which new lines it adds.
        struct Placed {
            var index: Int
            var anchor: Int
            var addEnd: Int
        }
        var placed: [Placed] = []
        placed.reserveCapacity(patch.hunks.count)
        var cursor = 0
        for (index, hunk) in patch.hunks.enumerated() {
            let (anchor, addEnd) = place(hunk, cursor: cursor, lineCount: n)
            placed.append(Placed(index: index, anchor: anchor, addEnd: addEnd))
            cursor = addEnd
        }

        // Visible intervals (0-based, end exclusive), sorted and merged.
        var visible: [Range<Int>] = []
        for p in placed {
            let lo = max(p.anchor - ctx, 0)
            let hi = min(p.addEnd + ctx, n)
            guard lo < hi else { continue }
            if let last = visible.last, lo <= last.upperBound {
                visible[visible.count - 1] = last.lowerBound..<max(last.upperBound, hi)
            } else {
                visible.append(lo..<hi)
            }
        }

        var next = 0 // index into `visible`
        func emitUnchanged(_ range: Range<Int>) {
            var pos = range.lowerBound
            while pos < range.upperBound {
                while next < visible.count, visible[next].upperBound <= pos { next += 1 }
                if next < visible.count, visible[next].lowerBound <= pos {
                    let end = min(range.upperBound, visible[next].upperBound)
                    builder.append(kind: .context, line: pos, count: end - pos, numbered: true)
                    pos = end
                } else {
                    let end = min(range.upperBound, next < visible.count ? visible[next].lowerBound : range.upperBound)
                    let length = end - pos
                    if length >= minFoldLines && !expandedFolds.contains(pos) {
                        builder.append(kind: .fold, line: pos, count: length, numbered: false)
                    } else {
                        builder.append(kind: .context, line: pos, count: length, numbered: true)
                    }
                    pos = end
                }
            }
        }

        cursor = 0
        for p in placed {
            emitUnchanged(cursor..<p.anchor)
            let hunk = patch.hunks[p.index]
            builder.append(kind: .deleted, line: hunk.deletedLines.lowerBound, count: hunk.deletedLines.count, hunk: p.index, numbered: false)
            builder.append(kind: .added, line: p.anchor, count: p.addEnd - p.anchor, hunk: p.index, numbered: true)
            cursor = p.addEnd
        }
        emitUnchanged(cursor..<n)
        return builder.finish()
    }

    /// Whole file, every line a context row numbered 1...lineCount, no folds.
    /// `mark` is `.modified` for lines inside a hunk that also deleted lines, `.added` inside a hunk that deleted nothing, else `.none`.
    package static func file(patch: FilePatch, lineCount: Int, metrics: RowMetrics = RowMetrics()) -> DiffDocument {
        let n = clampedCount(lineCount)
        var builder = Builder(metrics: metrics)
        var cursor = 0
        for hunk in patch.hunks {
            let (anchor, addEnd) = place(hunk, cursor: cursor, lineCount: n)
            builder.append(kind: .context, line: cursor, count: anchor - cursor, numbered: true)
            let mark: LineMark = hunk.deletedLines.isEmpty ? .added : .modified
            builder.append(kind: .context, line: anchor, count: addEnd - anchor, numbered: true, mark: mark)
            cursor = addEnd
        }
        builder.append(kind: .context, line: cursor, count: n - cursor, numbered: true)
        return builder.finish()
    }

    /// A deleted file: every old line is a deleted row, numbered 1...lineCount, `hunk` -1.
    package static func deletedFile(lineCount: Int, metrics: RowMetrics = RowMetrics()) -> DiffDocument {
        var builder = Builder(metrics: metrics)
        builder.append(kind: .deleted, line: 0, count: clampedCount(lineCount), numbered: true)
        return builder.finish()
    }

    /// A file shown without any diff decoration (new or untracked files): context rows numbered 1...lineCount.
    package static func plain(lineCount: Int, metrics: RowMetrics = RowMetrics()) -> DiffDocument {
        var builder = Builder(metrics: metrics)
        builder.append(kind: .context, line: 0, count: clampedCount(lineCount), numbered: true)
        return builder.finish()
    }

    package init() {}

    package var rowCount: Int { rowStart[rowStart.count - 1] }

    /// Total height of all rows.
    package var contentHeight: Double { yStart[yStart.count - 1] }

    /// Precondition: 0 <= index < rowCount. Out-of-range indices are clamped; an empty document gives a context row at line 0.
    package func row(at index: Int) -> DiffRow {
        guard !runs.isEmpty else { return DiffRow(kind: .context, line: 0) }
        let i = runIndex(ofRow: min(max(index, 0), rowCount - 1))
        let run = runs[i]
        if run.kind == .fold {
            return DiffRow(kind: .fold, line: run.firstLine, count: run.count, number: nil, hunk: -1, mark: .none)
        }
        let line = run.firstLine + (min(max(index, 0), rowCount - 1) - rowStart[i])
        return DiffRow(kind: run.kind, line: line, count: 1, number: run.numbered ? line + 1 : nil, hunk: run.hunk, mark: run.mark)
    }

    /// Top edge of row `index`. `y(ofRow: rowCount)` is `contentHeight`.
    package func y(ofRow index: Int) -> Double {
        guard !runs.isEmpty else { return 0 }
        guard index < rowCount else { return contentHeight }
        let row = max(index, 0)
        let i = runIndex(ofRow: row)
        guard runs[i].kind != .fold else { return yStart[i] }
        return yStart[i] + Double(row - rowStart[i]) * metrics.lineHeight
    }

    package func height(ofRow index: Int) -> Double {
        guard !runs.isEmpty else { return 0 }
        return runs[runIndex(ofRow: min(max(index, 0), rowCount - 1))].kind == .fold ? metrics.foldHeight : metrics.lineHeight
    }

    /// Index of the row containing vertical position `y`. Clamped to `0...rowCount - 1`; returns 0 when empty.
    package func rowIndex(atY y: Double) -> Int {
        guard !runs.isEmpty, y > 0 else { return 0 }
        guard y < contentHeight else { return rowCount - 1 }
        // Last run whose top edge is at or above y.
        var lo = 0
        var hi = runs.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if yStart[mid] <= y { lo = mid } else { hi = mid - 1 }
        }
        let run = runs[lo]
        guard run.kind != .fold, metrics.lineHeight > 0 else { return rowStart[lo] }
        let k = Int(((y - yStart[lo]) / metrics.lineHeight).rounded(.down))
        return rowStart[lo] + min(max(k, 0), run.count - 1)
    }

    /// For word-level highlighting: the k-th deleted row of a hunk pairs with the k-th added row of the same hunk.
    /// Returns the paired row index, or nil when the row is not part of a hunk or has no partner.
    package func counterpart(ofRow index: Int) -> Int? {
        guard index >= 0, index < rowCount else { return nil }
        let i = runIndex(ofRow: index)
        let run = runs[i]
        guard run.hunk >= 0 else { return nil }
        let k = index - rowStart[i]
        // A hunk's deleted run is directly followed by its added run.
        switch run.kind {
        case .deleted:
            guard i + 1 < runs.count, runs[i + 1].kind == .added, runs[i + 1].hunk == run.hunk, k < runs[i + 1].count else { return nil }
            return rowStart[i + 1] + k
        case .added:
            guard i > 0, runs[i - 1].kind == .deleted, runs[i - 1].hunk == run.hunk, k < runs[i - 1].count else { return nil }
            return rowStart[i - 1] + k
        case .context, .fold:
            return nil
        }
    }

    /// Last run whose first row is at or before `row`. Requires a non-empty document and a valid row.
    private func runIndex(ofRow row: Int) -> Int {
        var lo = 0
        var hi = runs.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if rowStart[mid] <= row { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private static func clampedCount(_ value: Int) -> Int {
        min(max(value, 0), Int.max / 4)
    }

    /// Where a hunk lands in the new text (0-based). `anchor` is the line its deleted rows sit before; the added
    /// lines are `anchor ..< addEnd`. Clamped into `cursor...lineCount` so stale or odd hunks stay in order.
    private static func place(_ hunk: Hunk, cursor: Int, lineCount: Int) -> (anchor: Int, addEnd: Int) {
        let start = min(max(hunk.newStart, 0), lineCount + 1)
        let count = min(max(hunk.newCount, 0), lineCount + 1)
        if count == 0 {
            // Pure deletion: sits after new line `newStart`.
            let anchor = min(max(start, cursor), lineCount)
            return (anchor, anchor)
        }
        let first = max(start - 1, 0)
        let anchor = min(max(first, cursor), lineCount)
        return (anchor, min(max(first + count, anchor), lineCount))
    }

    /// Collects runs (merging neighbours that continue each other) and the prefix arrays.
    private struct Builder {
        var doc = DiffDocument()

        init(metrics: RowMetrics) {
            doc.metrics = metrics
        }

        mutating func append(kind: DiffRowKind, line: Int, count: Int, hunk: Int = -1, numbered: Bool, mark: LineMark = .none) {
            guard count > 0 else { return }
            if kind != .fold, var last = doc.runs.last,
               last.kind == kind, last.hunk == hunk, last.mark == mark, last.numbered == numbered,
               last.firstLine + last.count == line {
                last.count += count
                doc.runs[doc.runs.count - 1] = last
                return
            }
            doc.runs.append(Run(kind: kind, firstLine: line, count: count, hunk: hunk, mark: mark, numbered: numbered))
            if kind == .fold { doc.foldCount += 1 }
        }

        /// Fills the prefix arrays. Merging above changed run lengths, so they are computed once at the end.
        mutating func finish() -> DiffDocument {
            doc.rowStart = [0]
            doc.yStart = [0]
            doc.rowStart.reserveCapacity(doc.runs.count + 1)
            doc.yStart.reserveCapacity(doc.runs.count + 1)
            var rows = 0
            var y = 0.0
            for run in doc.runs {
                rows += run.rowCount
                y += run.kind == .fold ? doc.metrics.foldHeight : Double(run.count) * doc.metrics.lineHeight
                doc.rowStart.append(rows)
                doc.yStart.append(y)
            }
            return doc
        }
    }
}
