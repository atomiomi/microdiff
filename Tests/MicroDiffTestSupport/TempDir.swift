import Foundation

/// A throwaway directory for tests. Removed when the object is released.
package final class TempDir: @unchecked Sendable {
    package let path: String

    package init(prefix: String = "microdiff-test") {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Resolve symlinks (/var -> /private/var) so paths compare equal to what git and realpath print.
        path = base.resolvingSymlinksInPath().path
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Writes a file (creating parent folders) and returns its absolute path.
    @discardableResult
    package func write(_ relativePath: String, _ contents: String) -> String {
        write(relativePath, Data(contents.utf8))
    }

    @discardableResult
    package func write(_ relativePath: String, _ contents: Data) -> String {
        let full = path + "/" + relativePath
        let dir = (full as NSString).deletingLastPathComponent
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: full, contents: contents)
        return full
    }

    package func mkdir(_ relativePath: String) {
        try! FileManager.default.createDirectory(atPath: path + "/" + relativePath, withIntermediateDirectories: true)
    }

    package func remove(_ relativePath: String) {
        try? FileManager.default.removeItem(atPath: path + "/" + relativePath)
    }
}
