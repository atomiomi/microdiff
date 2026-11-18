import Foundation

/// How a changed file is shown: its diff, or the whole file.
package enum ViewMode: UInt8, Sendable, Hashable {
    case diff
    case file
}

/// What to load for one open tab.
package struct DocumentRequest: Sendable, Hashable {
    /// Absolute path of the file on disk (for deleted files: where it used to be).
    package var path: String
    /// The repository the file's change belongs to. Nil when the file has no change.
    package var repo: RepoSnapshot?
    package var change: FileChange?
    package var mode: ViewMode
    /// Folds the user opened (first hidden line index of each).
    package var expandedFolds: Set<Int>
    /// Row heights of the view that will show the document.
    package var metrics: RowMetrics

    package init(
        path: String, repo: RepoSnapshot? = nil, change: FileChange? = nil, mode: ViewMode = .diff,
        expandedFolds: Set<Int> = [], metrics: RowMetrics = RowMetrics()
    ) {
        self.path = path
        self.repo = repo
        self.change = change
        self.mode = mode
        self.expandedFolds = expandedFolds
        self.metrics = metrics
    }
}

/// Everything a code view needs to draw one file. Immutable; built off the main thread.
package struct TextDocument: Sendable {
    package enum Kind: UInt8, Sendable {
        /// Unified diff with folds.
        case diff
        /// Whole file with change marks in the gutter.
        case file
        /// A deleted file: its old contents.
        case deleted
        /// Whole file, no decoration.
        case plain
    }

    package var kind: Kind
    package var rows: DiffDocument
    /// The file as it is on disk. Context and added rows point into it.
    package var newText: TextBuffer
    /// Deleted rows point into it: the patch's deleted lines, or the whole old file for `.deleted`.
    package var oldText: TextBuffer
    package var patch: FilePatch
    package var lexer: Lexer?
    /// Lexer state at the start of each line of `newText` / `oldText`. Empty means "always normal".
    package var newStates: [LexState]
    package var oldStates: [LexState]
    /// The row heights `rows` was laid out with.
    package var metrics: RowMetrics

    /// The same document with other folds opened. Cheap: only the row list is rebuilt.
    package func withExpandedFolds(_ folds: Set<Int>) -> TextDocument {
        guard kind == .diff else { return self }
        var copy = self
        copy.rows = DiffDocument.diff(patch: patch, newLineCount: newText.lineCount, expandedFolds: folds, metrics: metrics)
        return copy
    }

    /// Longest line in bytes across both texts, for the horizontal scroll range.
    package var maxLineByteLength: Int {
        max(newText.maxLineByteLength, oldText.maxLineByteLength)
    }
}

package enum DocumentContent: Sendable {
    case text(TextDocument)
    /// Nothing to draw as text; show this short line instead.
    case message(String)
}

/// Loads what a tab shows. Synchronous; call it off the main thread.
package struct DocumentLoader: Sendable {
    package static let binaryMessage = "binary file"
    package static let tooLargeMessage = "file too large to show"
    package static let missingMessage = "file not found"

    /// Above this size a file is shown without colors: lexing it would cost more than it is worth.
    package static let maxHighlightBytes = 4 * 1024 * 1024

    package let scanner: RepoScanner

    package init(scanner: RepoScanner = RepoScanner()) {
        self.scanner = scanner
    }

    package func load(_ request: DocumentRequest) -> DocumentContent {
        let fileName = (request.path as NSString).lastPathComponent

        if let change = request.change, let repo = request.repo, change.kind == .deleted {
            guard let data = try? scanner.headContents(path: change.path, in: repo) else {
                return .message(Self.missingMessage)
            }
            guard data.count <= TextBuffer.defaultMaxBytes else { return .message(Self.tooLargeMessage) }
            let old = TextBuffer(data)
            guard !old.isBinary else { return .message(Self.binaryMessage) }
            let lexer = Self.lexer(for: fileName, byteCount: old.byteCount)
            return .text(TextDocument(
                kind: .deleted,
                rows: .deletedFile(lineCount: old.lineCount, metrics: request.metrics),
                newText: .empty,
                oldText: old,
                patch: .empty,
                lexer: lexer,
                newStates: [],
                oldStates: lexer?.startStates(for: old) ?? [],
                metrics: request.metrics
            ))
        }

        let new: TextBuffer
        do {
            new = try TextBuffer(contentsOfFile: request.path)
        } catch TextBuffer.LoadError.tooLarge {
            return .message(Self.tooLargeMessage)
        } catch {
            return .message(Self.missingMessage)
        }
        guard !new.isBinary else { return .message(Self.binaryMessage) }

        var patch = FilePatch.empty
        var kind = TextDocument.Kind.plain
        if let change = request.change, let repo = request.repo,
           change.kind == .modified || change.kind == .renamed || change.kind == .conflicted {
            patch = (try? scanner.patch(for: change, in: repo)) ?? .empty
            guard !patch.isBinary else { return .message(Self.binaryMessage) }
            if !patch.hunks.isEmpty {
                kind = request.mode == .diff ? .diff : .file
            }
        }

        let rows: DiffDocument
        switch kind {
        case .diff:
            rows = .diff(patch: patch, newLineCount: new.lineCount, expandedFolds: request.expandedFolds, metrics: request.metrics)
        case .file:
            rows = .file(patch: patch, lineCount: new.lineCount, metrics: request.metrics)
        case .plain, .deleted:
            rows = .plain(lineCount: new.lineCount, metrics: request.metrics)
        }

        let lexer = Self.lexer(for: fileName, byteCount: new.byteCount)
        let newStates = lexer?.startStates(for: new) ?? []
        // Each hunk's deleted lines are an unrelated piece of the old file. They start in the state the new file has
        // where the hunk sits (inside `<script>`, a block comment, ...), so they are colored like the lines around them.
        // A changed hunk sits at its first new line; a pure deletion at the new line after the removed ones.
        let resets: [(line: Int, state: LexState)] = lexer.map { lexer in
            patch.hunks.map { hunk in
                let line = hunk.newCount > 0 ? hunk.newStart - 1 : hunk.newStart
                return (hunk.deletedLines.lowerBound, lexer.state(atLine: max(0, line), in: new, states: newStates))
            }
        } ?? []
        return .text(TextDocument(
            kind: kind,
            rows: rows,
            newText: new,
            oldText: patch.deletedText,
            patch: patch,
            lexer: lexer,
            newStates: newStates,
            oldStates: lexer?.startStates(for: patch.deletedText, resets: resets) ?? [],
            metrics: request.metrics
        ))
    }

    private static func lexer(for fileName: String, byteCount: Int) -> Lexer? {
        byteCount <= maxHighlightBytes ? Lexer.forFileName(fileName) : nil
    }
}
