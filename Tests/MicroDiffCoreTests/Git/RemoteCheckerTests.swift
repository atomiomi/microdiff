import Dispatch
import MicroDiffCore
import Testing

/// Asking a remote where a branch is, against bare repositories in temporary folders (no network).
@Suite struct RemoteCheckerTests {
    private let checker = RemoteChecker()
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func snapshot(_ repo: TestRepo) -> RepoSnapshot {
        RepoScanner().scan(root: repo.path).repos[0]
    }

    private func check(_ repo: TestRepo, _ checker: RemoteChecker? = nil) -> RemoteChecker.Check {
        let repoSnapshot = snapshot(repo)
        return (checker ?? self.checker).check(root: repo.path, branch: repoSnapshot.branchLabel, head: repoSnapshot.headOID)
    }

    /// The marks after a check, the way the app puts them together.
    private func marks(_ repo: TestRepo, checked check: RemoteChecker.Check? = nil) -> RepoSync? {
        let repoSnapshot = snapshot(repo)
        let memory = check.map { RemoteMemory().recording($0, head: repoSnapshot.headOID, at: now) }
        return RepoSync.make(
            upstream: repoSnapshot.upstream, isAhead: repoSnapshot.isAhead, isBehind: repoSnapshot.isBehind,
            head: repoSnapshot.headOID, memory: memory)
    }

    /// The remote moves on without this clone fetching.
    private func moveRemote(_ remote: TestRemote) {
        let other = remote.clone(pushingFirstCommit: false)
        other.write("other.txt", "from elsewhere\n")
        other.commitAll("elsewhere")
        other.git("push", "--quiet")
    }

    @Test func upToDateHasNoMarks() {
        let remote = TestRemote()
        let repo = remote.clone()
        let result = check(repo)
        #expect(result.answer == .commit(snapshot(repo).headOID ?? ""))
        #expect(result.isAncestor == true)
        #expect(marks(repo, checked: result) == nil)
    }

    @Test func theRemoteMovedAndNothingWasFetchedIsSomethingToPull() {
        let remote = TestRemote()
        let repo = remote.clone()
        moveRemote(remote)
        #expect(marks(repo) == nil, "git alone cannot know")
        let result = check(repo)
        #expect(result.isAncestor == false)
        #expect(marks(repo, checked: result) == RepoSync(upstream: "origin/main", pull: true, push: false, checkedAt: now))
    }

    @Test func fetchedButNotMergedIsSomethingToPullWithAndWithoutACheck() {
        let remote = TestRemote()
        let repo = remote.clone()
        moveRemote(remote)
        repo.git("fetch", "--quiet")
        #expect(marks(repo) == RepoSync(upstream: "origin/main", pull: true, push: false, checkedAt: nil))
        #expect(marks(repo, checked: check(repo)) == RepoSync(upstream: "origin/main", pull: true, push: false, checkedAt: now))
    }

    @Test func afterAPullTheMarkGoesWithoutAskingTheRemoteAgain() throws {
        let remote = TestRemote()
        let repo = remote.clone()
        moveRemote(remote)
        let folder = TempDir()
        let log = folder.path + "/log"
        let git = FakeGit.wrapping(logTo: log)
        let counting = RemoteChecker(git: git.runner)
        let before = snapshot(repo)
        let answered = RemoteMemory().recording(
            counting.check(root: repo.path, branch: "main", head: before.headOID), head: before.headOID, at: now)
        #expect(answered.ancestry?.isAncestor == false)
        let remoteCalls = (fileText(log) ?? "").split(separator: "\n").filter { $0.contains(" ls-remote ") }.count
        #expect(remoteCalls == 1)

        repo.git("pull", "--quiet", "--ff-only")
        let after = snapshot(repo)
        #expect(after.headOID != before.headOID)
        #expect(!after.isBehind)
        #expect(answered.needsAncestry(head: after.headOID))
        let head = try #require(after.headOID)
        let commit = try #require(answered.commit)
        let updated = answered.recordingAncestry(head: head, isAncestor: counting.isAncestor(commit, of: head, in: repo.path))
        #expect(RepoSync.make(upstream: after.upstream, isAhead: false, isBehind: false, head: head, memory: updated) == nil)
        #expect((fileText(log) ?? "").split(separator: "\n").filter { $0.contains(" ls-remote ") }.count == remoteCalls)
    }

    @Test func localCommitsAreSomethingToPush() {
        let remote = TestRemote()
        let repo = remote.clone()
        repo.write("new.txt", "mine\n")
        repo.commitAll("mine")
        #expect(marks(repo) == RepoSync(upstream: "origin/main", pull: false, push: true, checkedAt: nil))
        let result = check(repo)
        #expect(result.isAncestor == true, "the remote's commit is part of HEAD")
        #expect(marks(repo, checked: result) == RepoSync(upstream: "origin/main", pull: false, push: true, checkedAt: nil))
    }

    @Test func bothAtOnce() {
        let remote = TestRemote()
        let repo = remote.clone()
        moveRemote(remote)
        repo.write("new.txt", "mine\n")
        repo.commitAll("mine")
        let result = check(repo)
        #expect(marks(repo, checked: result) == RepoSync(upstream: "origin/main", pull: true, push: true, checkedAt: now))
    }

    @Test func aBranchWithoutAnUpstreamHasNothingToAskAndNoMarks() {
        let repo = TestRepo()
        repo.write("a.txt", "x\n")
        repo.commitAll("first")
        #expect(snapshot(repo).upstream == nil)
        #expect(check(repo).answer == .notApplicable)
        #expect(marks(repo) == nil)
    }

    @Test func anUpstreamThatIsALocalBranchIsNotAskedAbout() {
        let remote = TestRemote()
        let repo = remote.clone()
        repo.git("checkout", "--quiet", "-b", "topic", "--track", "main")
        repo.write("t.txt", "t\n")
        repo.commitAll("topic work")
        #expect(snapshot(repo).upstream == "main")
        #expect(check(repo).answer == .notApplicable)
        // What git knows locally still shows: this branch is ahead of the local one it follows.
        #expect(marks(repo) == RepoSync(upstream: "main", pull: false, push: true, checkedAt: nil))
    }

    @Test func aBranchThatIsGoneOnTheRemoteHasNothingToPull() {
        let remote = TestRemote()
        let repo = remote.clone()
        repo.git("checkout", "--quiet", "-b", "feature")
        repo.write("f.txt", "f\n")
        repo.commitAll("feature")
        repo.git("push", "--quiet", "-u", "origin", "feature")
        let other = remote.clone(pushingFirstCommit: false)
        other.git("push", "--quiet", "origin", "--delete", "feature")
        let result = check(repo)
        #expect(result.answer == .gone)
        #expect(marks(repo, checked: result) == nil)
    }

    @Test func aRemoteThatCannotBeReachedGivesNoAnswer() {
        let remote = TestRemote()
        let repo = remote.clone()
        repo.git("remote", "set-url", "origin", repo.path + "/no/such/remote")
        let result = check(repo)
        #expect(result.answer == .failed)
        #expect(result.isAncestor == nil)
        #expect(marks(repo, checked: result) == nil)
        #expect(RemoteMemory().recording(result, head: nil, at: now).failedAt == now)
    }

    @Test func aCheckWritesNothingToTheRepository() {
        let remote = TestRemote()
        let repo = remote.clone()
        moveRemote(remote)
        let before = repo.gitFolderListing()
        #expect(!before.contains { $0.hasPrefix("FETCH_HEAD") })
        _ = check(repo)
        _ = check(repo)
        #expect(repo.gitFolderListing() == before)
    }

    // MARK: Never stuck, never asking

    @Test func aCallThatHangsIsStoppedAtTheTimeLimitAndLeavesNothingRunning() async throws {
        let remote = TestRemote()
        let repo = remote.clone()
        let folder = TempDir()
        let pidFile = folder.path + "/pid"
        let git = FakeGit.wrapping(lsRemote: "sleep 60 &\necho $! > '\(pidFile)'\nwait")
        let slow = RemoteChecker(git: git.runner, timeLimit: 0.5)
        let start = ContinuousClock.now
        let result = check(repo, slow)
        #expect(result.answer == .failed)
        #expect(ContinuousClock.now - start < .seconds(10))
        let pid = try #require(fileText(pidFile).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        var gone = false
        for _ in 0..<500 where !gone {
            gone = !processExists(pid)
            if !gone { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(gone)
    }

    @Test func aCancelledCheckStopsTheCallAtOnce() async {
        let remote = TestRemote()
        let repo = remote.clone()
        let git = FakeGit.wrapping(lsRemote: "sleep 60")
        let patient = RemoteChecker(git: git.runner, timeLimit: 60)
        let token = CancelToken()
        let head = snapshot(repo).headOID
        let path = repo.path
        // On a dispatch thread, timed there: the task pool may be busy with other tests that block.
        // Timed from the moment of cancelling: a busy machine may be slow to start the process or the timer.
        let (result, took) = await withCheckedContinuation { (continuation: CheckedContinuation<(RemoteChecker.Check, Duration), Never>) in
            DispatchQueue.global().async {
                nonisolated(unsafe) var cancelledAt: ContinuousClock.Instant?
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                    cancelledAt = .now
                    token.cancel()
                }
                let result = patient.check(root: path, branch: "main", head: head, cancel: token)
                let end = ContinuousClock.now
                continuation.resume(returning: (result, end - (cancelledAt ?? end)))
            }
        }
        #expect(result.answer == .failed)
        #expect(took < .seconds(3))
    }

    @Test func theCallCannotAskForAnythingAndKeepsTheUsersSettings() throws {
        let remote = TestRemote()
        let repo = remote.clone()
        let folder = TempDir()
        let dump = folder.path + "/env"
        let git = FakeGit.wrapping(lsRemote: "env > '\(dump)'\nps -o tty= -p $$ >> '\(dump)'\nexit 1")
        _ = check(repo, RemoteChecker(git: git.runner))
        let lines = try #require(fileText(dump)).split(separator: "\n").map(String.init)
        #expect(lines.contains("GIT_TERMINAL_PROMPT=0"))
        #expect(lines.contains("GIT_ASKPASS=/usr/bin/true"))
        #expect(lines.contains("SSH_ASKPASS_REQUIRE=never"))
        #expect(!lines.contains { $0.hasPrefix("SSH_ASKPASS=") })
        #expect(!lines.contains { $0.hasPrefix("DISPLAY=") })
        #expect(lines.contains { $0.hasPrefix("HOME=") && $0.count > 5 }, "the rest is inherited")
        #expect(lines.contains { $0.hasPrefix("PATH=") })
        #expect(lines.last?.hasPrefix("??") == true, "no terminal to ask on")
    }

    @Test func theEnvironmentDoesNotTouchSshOrCredentialSettings() {
        let touched = Set(GitRunner.remoteOverrides.keys).union(GitRunner.remoteRemovals)
        for name in touched {
            #expect(!name.hasPrefix("GIT_SSH"), "\(name)")
            #expect(!name.hasPrefix("SSH_AUTH"), "\(name)")
            #expect(!name.lowercased().contains("credential"), "\(name)")
            #expect(!name.hasPrefix("GIT_CONFIG"), "\(name)")
        }
        #expect(GitRunner.remoteOverrides["GIT_TERMINAL_PROMPT"] == "0")
    }
}
