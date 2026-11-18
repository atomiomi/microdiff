import Foundation

/// Where the read view's base text for a file comes from: its HEAD version in this repository.
package struct MarkSource: Sendable, Equatable {
    package var repoRoot: String
    /// Repository-relative path in HEAD (the old path of a rename).
    package var headPath: String

    package init(repoRoot: String, headPath: String) {
        self.repoRoot = repoRoot
        self.headPath = headPath
    }
}

/// The read view's gutter marks for text that is not on disk yet (the editor's). Computed the way the read view gets
/// them, so the two cannot disagree: the same `git diff` options, of the HEAD version against the text, read by the
/// same `DiffDocument.file`. Blocking: call off the main thread.
package enum ChangeMarks {
    /// The HEAD version of the file; nil when there is none (new, untracked or ignored file, no commits).
    package static func base(_ source: MarkSource, git: GitRunner) -> Data? {
        try? git.run(["cat-file", "blob", "HEAD:" + source.headPath], in: source.repoRoot)
    }

    /// Row i is line i of `text`, with its mark. Nil when git fails. `text` is the file's bytes (see `EditFile.bytes`).
    package static func compute(text: Data, base: Data, repoRoot: String, git: GitRunner) -> DiffDocument? {
        let lineCount = TextBuffer(text).lineCount
        guard text != base else { return .file(patch: .empty, lineCount: lineCount) }
        // `git diff --no-index` compares files: both live in temporary files for the length of the call.
        let folder = NSTemporaryDirectory() + "microdiff-marks-" + UUID().uuidString
        let basePath = folder + "/base", textPath = folder + "/text"
        defer { try? FileManager.default.removeItem(atPath: folder) }
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try base.write(to: URL(fileURLWithPath: basePath))
            try text.write(to: URL(fileURLWithPath: textPath))
            // Run in the repository, so its diff settings apply as they do to the read view's diff. Exit code 1: they differ.
            let output = try git.run(
                ["diff", "--no-index", "--no-color", "--no-ext-diff", "--no-textconv", "-U0", "--", basePath, textPath],
                in: repoRoot, allowedExitCodes: [0, 1])
            let patch = DiffParser.parse(output)
            return .file(patch: patch.isBinary ? .empty : patch, lineCount: lineCount)
        } catch {
            return nil
        }
    }
}
