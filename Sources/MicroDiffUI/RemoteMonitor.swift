import Foundation
import MicroDiffCore

/// Finds out whether the repositories of a window have something to pull, by asking each remote where the branch is.
///
/// It only asks (`git ls-remote`): nothing is downloaded and the repository is not touched. One run at a time, the
/// repositories one after another off the main thread. Runs start on the triggers of `RemoteSchedule`; no timer runs
/// while the window is not visible. Until `enable()` is called (and after `stop()`) it never contacts anyone, but still
/// turns what git knows locally into marks (`sync(for:)`).
final class RemoteMonitor {
    private struct Key: Hashable {
        var root: String
        var branch: String
        var upstream: String
    }

    /// What one step of a run needs about a repository.
    private struct Job {
        var key: Key
        var head: String?
    }

    private let checker: RemoteChecker
    private let clock: () -> Date
    /// How long after the first scan the first run starts.
    private let firstCheckDelay: TimeInterval

    private var memory: [Key: RemoteMemory] = [:]
    private var repos: [RepoSnapshot] = []
    private(set) var isEnabled = false
    private var isVisible = false
    private var hasScheduledFirstCheck = false
    private var lastRun: Date?
    private(set) var isRunning = false
    /// Refresh came while a run was going: another one follows.
    private var manualWaiting = false
    private var task: Task<Void, Never>?
    private var cancel = CancelToken()
    private var timer: Timer?
    private var firstTimer: Timer?

    /// A timer is waiting to start a run (none while the window is not visible, or after `stop`).
    var hasPendingTimer: Bool { timer != nil || firstTimer != nil }

    /// The marks of some repository changed.
    var onChange: (() -> Void)?

    init(checker: RemoteChecker = RemoteChecker(), firstCheckDelay: TimeInterval = 1, clock: @escaping () -> Date = Date.init) {
        self.checker = checker
        self.firstCheckDelay = firstCheckDelay
        self.clock = clock
    }

    // MARK: - Marks

    private func key(of repo: RepoSnapshot) -> Key? {
        guard let upstream = repo.upstream, repo.hasHead else { return nil }
        return Key(root: repo.rootPath, branch: repo.branchLabel, upstream: upstream)
    }

    /// The marks for a repository: what git knows locally, corrected by what the remote said.
    func sync(for repo: RepoSnapshot) -> RepoSync? {
        RepoSync.make(
            upstream: repo.upstream, isAhead: repo.isAhead, isBehind: repo.isBehind, head: repo.headOID,
            memory: key(of: repo).flatMap { memory[$0] })
    }

    // MARK: - Lifecycle

    func enable() {
        isEnabled = true
    }

    /// Ends everything: the run in progress is killed, timers stop, what was learned is dropped.
    func stop() {
        isEnabled = false
        cancel.cancel()
        task?.cancel()
        task = nil
        isRunning = false
        manualWaiting = false
        timer?.invalidate()
        timer = nil
        firstTimer?.invalidate()
        firstTimer = nil
        onChange = nil
        repos = []
        memory = [:]
    }

    // MARK: - Events

    /// A scan finished: these are the repositories now.
    func update(repos newRepos: [RepoSnapshot]) {
        repos = newRepos
        let keys = Set(newRepos.compactMap(key(of:)))
        // A repository that changed its branch or upstream starts from nothing.
        memory = memory.filter { keys.contains($0.key) }
        guard isEnabled else { return }
        if !hasScheduledFirstCheck, !newRepos.isEmpty, isVisible {
            hasScheduledFirstCheck = true
            firstTimer = Timer.scheduledTimer(withTimeInterval: firstCheckDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.firstTimer = nil
                    self?.trigger(.firstScan)
                }
            }
        }
        if !isRunning, needsAncestry { run(remote: false, manual: false) }
    }

    func windowBecameKey() {
        trigger(.becameKey)
    }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            trigger(.becameVisible)
            armTimer()
        } else {
            timer?.invalidate()
            timer = nil
            firstTimer?.invalidate()
            firstTimer = nil
            // Looked at again later: the first check is not given up.
            if lastRun == nil { hasScheduledFirstCheck = false }
        }
    }

    /// Refresh: always asks, also the repositories that failed lately.
    func refresh() {
        trigger(.manual)
    }

    private func trigger(_ trigger: RemoteSchedule.Trigger) {
        guard isEnabled else { return }
        guard RemoteSchedule.isDue(trigger, now: clock(), lastRun: lastRun) else { return }
        if isRunning {
            if trigger == .manual { manualWaiting = true }
            return
        }
        run(remote: true, manual: trigger == .manual)
    }

    private func armTimer() {
        timer?.invalidate()
        timer = nil
        guard isEnabled, isVisible, !isRunning else { return }
        let delay = RemoteSchedule.timerDelay(now: clock(), lastRun: lastRun)
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil
                self.trigger(.timer)
                self.armTimer()
            }
        }
    }

    // MARK: - Runs

    private var needsAncestry: Bool {
        repos.contains { repo in key(of: repo).flatMap { memory[$0] }?.needsAncestry(head: repo.headOID) == true }
    }

    /// One run over the repositories, one after another. With `remote` the remote is asked (except for a repository
    /// in its failure wait, unless `manual`); without, only the local question "does HEAD have that commit" is asked
    /// where HEAD or the remote's commit changed.
    private func run(remote: Bool, manual: Bool) {
        guard isEnabled, !isRunning, !repos.isEmpty else { return }
        isRunning = true
        let jobs = repos.compactMap { repo in key(of: repo).map { Job(key: $0, head: repo.headOID) } }
        let checker = checker
        let token = cancel
        task = Task { [weak self] in
            for job in jobs {
                guard let self, !Task.isCancelled, !token.isCancelled else { return }
                let now = clock()
                let known = memory[job.key]
                let asksRemote = remote && RemoteSchedule.isRepositoryDue(
                    failedAt: known?.failedAt, failures: known?.failures ?? 0, now: now, manual: manual)
                let asksAncestry = !asksRemote && known?.needsAncestry(head: job.head) == true
                guard asksRemote || asksAncestry else { continue }
                let commit = known?.commit
                let check = await Task.detached(priority: .utility) { () -> RemoteChecker.Check in
                    if asksRemote { return checker.check(root: job.key.root, branch: job.key.branch, head: job.head, cancel: token) }
                    let isAncestor = job.head.flatMap { head in commit.map { checker.isAncestor($0, of: head, in: job.key.root) } }
                    return RemoteChecker.Check(answer: commit.map { .commit($0) } ?? .notApplicable, isAncestor: isAncestor)
                }.value
                guard !Task.isCancelled, !token.isCancelled else { return }
                record(check, for: job, asksRemote: asksRemote)
            }
            self?.finishRun(remote: remote)
        }
    }

    private func record(_ check: RemoteChecker.Check, for job: Job, asksRemote: Bool) {
        // The repository may be gone (or follow another branch) since the run began.
        guard let repo = repos.first(where: { key(of: $0) == job.key }) else { return }
        let before = sync(for: repo)
        let old = memory[job.key] ?? RemoteMemory()
        if asksRemote {
            memory[job.key] = old.recording(check, head: job.head, at: clock())
        } else if let head = job.head, let isAncestor = check.isAncestor {
            memory[job.key] = old.recordingAncestry(head: head, isAncestor: isAncestor)
        }
        if before != sync(for: repo) { onChange?() }
    }

    private func finishRun(remote: Bool) {
        isRunning = false
        task = nil
        if remote { lastRun = clock() }
        if manualWaiting {
            manualWaiting = false
            run(remote: true, manual: true)
            return
        }
        armTimer()
        if needsAncestry { run(remote: false, manual: false) }
    }
}
