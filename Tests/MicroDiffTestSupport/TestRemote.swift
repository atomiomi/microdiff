import Foundation

/// A bare repository in a throwaway folder, to push to and fetch from without a network.
package final class TestRemote: @unchecked Sendable {
    private let dir = TempDir(prefix: "microdiff-remote")

    /// The folder of the bare repository (also what a clone's `origin` url is).
    package var path: String { dir.path }

    package init() {
        // Made through a repository object only for its git runner: `git init --bare` needs no work tree.
        let helper = TestRepo()
        helper.git("init", "--quiet", "--bare", "--initial-branch=main", path)
    }

    /// A clone of this remote, on `main` with a first commit pushed (when the remote is still empty).
    package func clone(pushingFirstCommit: Bool = true) -> TestRepo {
        let repo = TestRepo(cloning: path)
        if pushingFirstCommit {
            repo.write("a.txt", "one\n")
            repo.commitAll("first")
            repo.git("push", "--quiet", "-u", "origin", "main")
        }
        return repo
    }
}
