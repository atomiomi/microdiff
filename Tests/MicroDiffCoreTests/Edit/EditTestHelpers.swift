import Foundation
import MicroDiffCore

// Foundation-only helpers for the edit tests (a file must not import both Foundation and Testing here).

func fileBytes(_ path: String) -> [UInt8] {
    [UInt8](FileManager.default.contents(atPath: path) ?? Data())
}

func bytes(_ values: [UInt8]) -> Data { Data(values) }

func permissions(_ path: String) -> Int {
    var info = stat()
    stat(path, &info)
    return Int(info.st_mode & 0o7777)
}

func setPermissions(_ path: String, _ mode: Int) {
    chmod(path, mode_t(mode))
}

func isSymlink(_ path: String) -> Bool {
    (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
}

func listDirectory(_ path: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
}

func removeFile(_ path: String) {
    try? FileManager.default.removeItem(atPath: path)
}

func removeFolder(_ path: String) { removeFile(path) }

func stampOf(_ path: String) -> DiskStamp? {
    if case let .present(stamp)? = DiskObservation.observe(path) { return stamp }
    return nil
}

func stamp(_ n: Int) -> DiskStamp { DiskStamp(size: Int64(n), modifiedNanos: Int64(n), inode: 1) }

/// The marks of every line (row i is line i) as the read view has them for `path` in `repo` right now.
func readViewMarks(_ repo: TestRepo, _ path: String) -> [LineMark] {
    let scanner = RepoScanner()
    let snapshot = scanner.scan(root: repo.path)
    let root = snapshot.repos[0]
    let text = TextBuffer(Data(fileBytes(repo.path + "/" + path)))
    let patch = root.changes.first { $0.path == path }.flatMap { try? scanner.patch(for: $0, in: root) } ?? .empty
    return marks(DiffDocument.file(patch: patch, lineCount: text.lineCount))
}

/// The editor's marks for `text` (in its file format) against the HEAD version of `path`.
func editorMarks(_ repo: TestRepo, _ path: String, text: [UInt8]) -> [LineMark]? {
    let git = GitRunner()
    guard let base = ChangeMarks.base(MarkSource(repoRoot: repo.path, headPath: path), git: git) else { return nil }
    return ChangeMarks.compute(text: Data(text), base: base, repoRoot: repo.path, git: git).map(marks)
}

func marks(_ rows: DiffDocument) -> [LineMark] {
    (0..<rows.rowCount).map { rows.row(at: $0).mark }
}

func utf8(_ text: String) -> [UInt8] { Array(text.utf8) }
