import Foundation
import MicroDiffCore

/// A throwaway executable that replaces the git binary, for tests of slow or failing git.
/// Removed when released.
package final class FakeGit: @unchecked Sendable {
    private let dir = TempDir(prefix: "microdiff-fakegit")
    package let path: String

    /// `body` is the shell script after the `#!/bin/sh` line. `"$@"` are git's arguments.
    package init(_ body: String) {
        path = dir.write("git", "#!/bin/sh\n" + body + "\n")
        chmod(path, 0o755)
    }

    /// A runner that uses this script.
    package var runner: GitRunner { GitRunner(gitPath: path) }

    /// Behaves like git, but writes every call's arguments as a line to `logPath`, and runs `lsRemote` (shell code) in place
    /// of every `git ls-remote`.
    package static func wrapping(logTo logPath: String? = nil, lsRemote: String? = nil) -> FakeGit {
        var body = ""
        if let logPath { body += "echo \"$@\" >> '\(logPath)'\n" }
        if let lsRemote { body += "case \" $* \" in *\" ls-remote \"*)\n\(lsRemote)\n;; esac\n" }
        return FakeGit(body + "exec '\(GitRunner().gitPath)' \"$@\"")
    }

    /// Waits `seconds`, then runs the real git with the same arguments.
    package static func slow(_ seconds: Double) -> FakeGit {
        FakeGit("sleep \(seconds)\nexec '\(GitRunner().gitPath)' \"$@\"")
    }

    /// Fails like git does when it cannot do its job.
    package static func failing(exitCode: Int32 = 128, message: String = "fatal: boom") -> FakeGit {
        FakeGit("echo '\(message)' >&2\nexit \(exitCode)")
    }
}
