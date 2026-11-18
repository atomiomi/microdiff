import Foundation

// Foundation-only helpers for the document tests (a file must not import both Foundation and Testing here).

/// `chmod 755`: a mode-only change for git.
func makeExecutable(_ path: String) {
    chmod(path, 0o755)
}

/// A file of `byteCount` zero bytes that takes (almost) no disk space.
func writeSparseFile(_ path: String, byteCount: Int) {
    FileManager.default.createFile(atPath: path, contents: nil)
    guard let handle = FileHandle(forWritingAtPath: path) else { fatalError("cannot open \(path)") }
    try! handle.truncate(atOffset: UInt64(byteCount))
    try! handle.close()
}

/// `count` copies of one byte (no newline, no NUL when `byte` is printable).
func filledData(_ byte: UInt8, count: Int) -> Data {
    Data(repeating: byte, count: count)
}

/// The file's contents decoded as UTF-8.
func fileText(_ path: String) -> String {
    String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self)
}

func makeDirectory(_ path: String) {
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}
