import Foundation

/// What a repository row says about the remote: something to pull, something to push.
package struct RepoSync: Sendable, Hashable {
    /// The branch this one follows, as git names it (`origin/main`).
    package var upstream: String
    /// The remote has commits this clone does not have.
    package var pull: Bool
    /// This clone has commits the remote does not have.
    package var push: Bool
    /// When the remote last answered, when the pull mark comes from that answer. Nil without a pull mark, and when it only
    /// comes from what git already knew (the last fetch).
    package var checkedAt: Date?

    package init(upstream: String, pull: Bool, push: Bool, checkedAt: Date? = nil) {
        self.upstream = upstream
        self.pull = pull
        self.push = push
        self.checkedAt = checkedAt
    }

    /// The marks of a repository, or nil when there is nothing to pull or push (or no upstream).
    /// `memory` is what the remote checks found out; it decides the pull mark once it has an answer for this HEAD.
    package static func make(upstream: String?, isAhead: Bool, isBehind: Bool, head: String?, memory: RemoteMemory?) -> RepoSync? {
        guard let upstream else { return nil }
        var pull = isBehind
        var checkedAt: Date?
        if let memory, let at = memory.checkedAt {
            if memory.commit == nil {
                pull = false
                checkedAt = at
            } else if let ancestry = memory.ancestry, ancestry.remote == memory.commit, ancestry.head == head {
                pull = !ancestry.isAncestor
                checkedAt = at
            }
        }
        guard pull || isAhead else { return nil }
        return RepoSync(upstream: upstream, pull: pull, push: isAhead, checkedAt: pull ? checkedAt : nil)
    }

    /// The lines of the tooltip, only those that apply: what to pull, then what to push.
    package func toolTipLines(now: Date) -> [String] {
        var lines: [String] = []
        if pull {
            var line = "to pull: new commits on \(upstream)"
            if let checkedAt { line += " (checked \(Self.age(from: checkedAt, to: now)))" }
            lines.append(line)
        }
        if push { lines.append("to push: commits that are not on \(upstream) yet") }
        return lines
    }

    /// "just now", "N minutes ago", "N hours ago".
    package static func age(from then: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(then))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago" }
        let hours = minutes / 60
        return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
    }
}

/// What the remote checks know about one branch of one repository.
package struct RemoteMemory: Sendable, Hashable {
    /// Whether HEAD has the remote's commit.
    package struct Ancestry: Sendable, Hashable {
        package var head: String
        package var remote: String
        package var isAncestor: Bool

        package init(head: String, remote: String, isAncestor: Bool) {
            self.head = head
            self.remote = remote
            self.isAncestor = isAncestor
        }
    }

    /// The commit the remote branch was at when it last answered. Nil when it answered that the branch is gone.
    package var commit: String?
    /// When the remote last answered. Nil before the first answer.
    package var checkedAt: Date?
    package var ancestry: Ancestry?
    /// When the last check failed (offline, no access, too slow); cleared by an answer.
    package var failedAt: Date?
    /// How many checks in a row failed.
    package var failures: Int

    package init(commit: String? = nil, checkedAt: Date? = nil, ancestry: Ancestry? = nil, failedAt: Date? = nil, failures: Int = 0) {
        self.commit = commit
        self.checkedAt = checkedAt
        self.ancestry = ancestry
        self.failedAt = failedAt
        self.failures = failures
    }

    /// The remote's commit is known but nobody has asked whether HEAD has it (HEAD or the commit moved since).
    package func needsAncestry(head: String?) -> Bool {
        guard let commit, let head else { return false }
        return ancestry?.remote != commit || ancestry?.head != head
    }

    /// The memory after a check. `isAncestor` belongs to `head` and the answered commit.
    package func recording(_ check: RemoteChecker.Check, head: String?, at now: Date) -> RemoteMemory {
        var memory = self
        switch check.answer {
        case .commit(let id):
            memory.commit = id
            memory.checkedAt = now
            memory.failedAt = nil
            memory.failures = 0
            memory.ancestry = nil
            if let head, let isAncestor = check.isAncestor { memory.ancestry = Ancestry(head: head, remote: id, isAncestor: isAncestor) }
        case .gone:
            memory.commit = nil
            memory.checkedAt = now
            memory.failedAt = nil
            memory.failures = 0
            memory.ancestry = nil
        case .failed:
            memory.failedAt = now
            memory.failures += 1
        case .notApplicable:
            break
        }
        return memory
    }

    /// The memory after only the ancestor question was asked again.
    package func recordingAncestry(head: String, isAncestor: Bool) -> RemoteMemory {
        guard let commit else { return self }
        var memory = self
        memory.ancestry = Ancestry(head: head, remote: commit, isAncestor: isAncestor)
        return memory
    }
}

/// Asks where a branch is on its remote. It only reads: nothing is downloaded and nothing is written to the repository.
package struct RemoteChecker: Sendable {
    package enum Answer: Sendable, Equatable {
        /// The remote branch is at this commit.
        case commit(String)
        /// The remote answered and has no such branch.
        case gone
        /// No answer (offline, no access, too slow, git failed).
        case failed
        /// Nothing to ask: the branch follows a local branch, or has no upstream.
        case notApplicable
    }

    package struct Check: Sendable, Equatable {
        package var answer: Answer
        /// For `.commit`: whether HEAD has that commit. Nil when unknown or not asked.
        package var isAncestor: Bool?

        package init(answer: Answer, isAncestor: Bool? = nil) {
            self.answer = answer
            self.isAncestor = isAncestor
        }
    }

    package let git: GitRunner
    /// How long one call to the remote may take before it is killed.
    package var timeLimit: TimeInterval

    package init(git: GitRunner = GitRunner(), timeLimit: TimeInterval = 15) {
        self.git = git
        self.timeLimit = timeLimit
    }

    /// Where `branch` of the repository in `root` follows on its remote, and the answer of the remote about it.
    /// `head` is HEAD's commit id: with it, the ancestor question is asked at once.
    package func check(root: String, branch: String, head: String?, cancel: CancelToken? = nil) -> Check {
        let answer = ask(root: root, branch: branch, cancel: cancel)
        guard case .commit(let id) = answer, let head else { return Check(answer: answer) }
        return Check(answer: answer, isAncestor: isAncestor(id, of: head, in: root))
    }

    /// Whether `commit` is part of what `head` has. A commit this clone does not have is not.
    package func isAncestor(_ commit: String, of head: String, in root: String) -> Bool {
        (try? git.run(["merge-base", "--is-ancestor", commit, head], in: root)) != nil
    }

    private func ask(root: String, branch: String, cancel: CancelToken?) -> Answer {
        let format = "--format=%(upstream:remotename)%00%(upstream:remoteref)"
        guard let output = try? git.run(["for-each-ref", format, "refs/heads/" + branch], in: root) else { return .failed }
        let fields = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .newlines).split(
            separator: "\0", omittingEmptySubsequences: false).map(String.init)
        // A branch that follows a local branch has remote "." and nothing to ask.
        guard fields.count == 2, !fields[0].isEmpty, fields[0] != ".", !fields[1].isEmpty else { return .notApplicable }
        let remote = fields[0]
        let ref = fields[1]
        do {
            let reply = try git.runRemote(["ls-remote", remote, ref], in: root, limit: .init(seconds: timeLimit, cancel: cancel))
            for line in String(decoding: reply, as: UTF8.self).split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                if parts.count == 2, parts[1] == ref, Self.isCommitID(parts[0]) { return .commit(parts[0]) }
            }
            return .gone
        } catch {
            return .failed
        }
    }

    private static func isCommitID(_ text: String) -> Bool {
        (text.count == 40 || text.count == 64) && text.allSatisfy(\.isHexDigit)
    }
}

/// When the remote is asked. Pure: the clock is passed in.
package enum RemoteSchedule {
    package enum Trigger: Sendable {
        /// The window became the key window.
        case becameKey
        /// The window became visible (not minimized, hidden or covered) again.
        case becameVisible
        /// The five-minute timer ran out while the window is visible.
        case timer
        /// The first scan of a folder is in.
        case firstScan
        /// Refresh.
        case manual
    }

    /// Between two checks of a window.
    package static let interval: TimeInterval = 300
    /// A repository whose check keeps failing is left alone this long (Refresh asks again at once).
    package static let failureWait: TimeInterval = 1800
    /// The timer may run this early without being too early.
    private static let slack: TimeInterval = 1

    /// Whether a run is due. `lastRun` is when the window's last run ended.
    package static func isDue(_ trigger: Trigger, now: Date, lastRun: Date?) -> Bool {
        switch trigger {
        case .manual:
            return true
        case .firstScan:
            return lastRun == nil
        case .becameKey, .becameVisible:
            guard let lastRun else { return true }
            return now.timeIntervalSince(lastRun) >= interval
        case .timer:
            guard let lastRun else { return true }
            return now.timeIntervalSince(lastRun) >= interval - slack
        }
    }

    /// Seconds from `now` until the timer is due.
    package static func timerDelay(now: Date, lastRun: Date?) -> TimeInterval {
        guard let lastRun else { return interval }
        return max(0, interval - now.timeIntervalSince(lastRun))
    }

    /// Whether a repository is asked in this run: not within the failure wait, unless the user asked. One failure is
    /// often a network that is not up yet (a laptop just opened), so the wait starts with the second failure in a row.
    package static func isRepositoryDue(failedAt: Date?, failures: Int, now: Date, manual: Bool) -> Bool {
        guard !manual, let failedAt, failures >= 2 else { return true }
        return now.timeIntervalSince(failedAt) >= failureWait
    }
}
