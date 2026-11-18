import Foundation
import MicroDiffCore

/// A throwaway git repository for integration tests. Talks to the git CLI directly (not through
/// `GitRunner`) and ignores the developer's git config. Removed when the object is released.
package final class TestRepo: @unchecked Sendable {
    private let dir = TempDir(prefix: "microdiff-repo")

    package var path: String { dir.path }

    /// Creates the folder and runs `git init`.
    package init() {
        git("init", "--quiet")
    }

    @discardableResult
    package func write(_ relativePath: String, _ contents: String) -> String {
        dir.write(relativePath, contents)
    }

    @discardableResult
    package func write(_ relativePath: String, _ contents: Data) -> String {
        dir.write(relativePath, contents)
    }

    package func remove(_ relativePath: String) {
        dir.remove(relativePath)
    }

    /// Runs git in the repo (or in `subfolder`, e.g. inside a submodule) and returns stdout.
    @discardableResult
    package func git(_ args: String..., in subfolder: String? = nil) -> String {
        let cwd = subfolder.map { path + "/" + $0 } ?? path
        let (status, text) = Self.runGit(args, in: cwd)
        if status != 0 { fatalError("git \(args) failed: \(text)") }
        return text
    }

    /// Like `git`, but reports failure instead of aborting (e.g. a merge that conflicts).
    @discardableResult
    package func tryGit(_ args: String..., in subfolder: String? = nil) -> Bool {
        Self.runGit(args, in: subfolder.map { path + "/" + $0 } ?? path).status == 0
    }

    package func commitAll(_ message: String = "commit", in subfolder: String? = nil) {
        git("add", "-A", in: subfolder)
        git("commit", "--quiet", "--allow-empty", "-m", message, in: subfolder)
    }

    /// Adds `source` as a submodule at `path`. Stages the change; commit it with `commitAll`.
    package func addSubmodule(from source: TestRepo, at path: String) {
        git("submodule", "--quiet", "add", source.path, path)
    }

    /// The developer's own git settings must not leak into fixtures.
    private static let environment = ChildProcess.environment(overriding: [
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
    ])

    private static let gitPath = GitRunner().gitPath

    private static func runGit(_ args: [String], in directory: String) -> (status: Int32, text: String) {
        let arguments = [
            gitPath, "-C", directory,
            "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
            "-c", "init.defaultBranch=main", "-c", "protocol.file.allow=always", "-c", "core.autocrlf=false",
        ] + args
        guard let result = ChildProcess.run(path: gitPath, arguments: arguments, environment: environment) else {
            fatalError("cannot start git")
        }
        return (result.exitCode, String(decoding: result.stdout + result.stderr, as: UTF8.self))
    }
}
