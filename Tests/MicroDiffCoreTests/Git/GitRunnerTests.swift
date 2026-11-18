import MicroDiffCore
import Testing

@Suite struct GitRunnerTests {
    private let git = GitRunner()

    @Test func resolvesAnExistingGitBinary() {
        #expect(git.gitPath.hasPrefix("/"))
        #expect(isExecutableFile(git.gitPath))
    }

    @Test func explicitPathIsUsedAsIs() {
        #expect(GitRunner(gitPath: "/somewhere/git").gitPath == "/somewhere/git")
    }

    @Test func versionCallWorks() throws {
        let dir = TempDir()
        let out = try git.run(["--version"], in: dir.path)
        #expect(String(decoding: out, as: UTF8.self).hasPrefix("git version"))
    }

    @Test func nonZeroExitThrowsWithStderr() {
        let dir = TempDir()
        do {
            _ = try git.run(["rev-parse", "--verify", "no-such-ref"], in: dir.path)
            Issue.record("expected a throw")
        } catch let error as GitError {
            #expect(error.exitCode != 0)
            #expect(!error.stderr.isEmpty)
            #expect(error.arguments == ["rev-parse", "--verify", "no-such-ref"])
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func allowedExitCodesDoNotThrow() throws {
        let dir = TempDir()
        // `git config --get` of a missing key exits with 1.
        let out = try git.run(["config", "--file", "none.cfg", "--get", "a.b"], in: dir.path, allowedExitCodes: [0, 1])
        #expect(out.isEmpty)
    }

    @Test func badDirectoryThrows() {
        #expect(throws: GitError.self) {
            try git.run(["status"], in: "/definitely/not/a/folder")
        }
    }

    @Test func missingBinaryThrowsWithMinusOne() {
        let runner = GitRunner(gitPath: "/no/such/git")
        do {
            _ = try runner.run(["--version"], in: "/tmp")
            Issue.record("expected a throw")
        } catch let error as GitError {
            #expect(error.exitCode == -1)
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func largeStdoutDoesNotHang() throws {
        let repo = TestRepo()
        // ~3 MB of tracked content printed through `git cat-file`.
        repo.write("big.txt", String(repeating: "0123456789abcdef\n", count: 200_000))
        repo.commitAll()
        let out = try git.run(["cat-file", "blob", "HEAD:big.txt"], in: repo.path)
        #expect(out.count == 17 * 200_000)
    }

    @Test func largeStderrAndStdoutTogetherDoNotDeadlock() throws {
        let dir = TempDir()
        // The alias writes 600 KB to each stream, far above the pipe buffer.
        let alias = "alias.noisy=!yes e | head -c 600000 >&2; yes o | head -c 600000"
        let out = try git.run(["-c", alias, "noisy"], in: dir.path)
        #expect(out.count == 600_000)
    }

    @Test func setsEnvironmentForReadOnlyNonInteractiveUse() throws {
        let dir = TempDir()
        let alias = "alias.env=!echo $GIT_OPTIONAL_LOCKS $GIT_TERMINAL_PROMPT $LC_ALL"
        let out = try git.run(["-c", alias, "env"], in: dir.path)
        #expect(String(decoding: out, as: UTF8.self) == "0 0 C\n")
    }
}
