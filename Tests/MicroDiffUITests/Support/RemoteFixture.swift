import AppKit
import MicroDiffCore
import MicroDiffTestSupport

@testable import MicroDiffUI

// Helpers for the remote-check tests. No `import Testing` here (it cannot be combined with Foundation in one file).

/// A clock the tests move by hand.
@MainActor
final class MutableClock {
    var now = Date(timeIntervalSince1970: 3_000_000)

    func advance(minutes: Double) {
        now = now.addingTimeInterval(minutes * 60)
    }
}

/// A bare remote, a clone that follows it, and a git that notes every call (and every start and end of `git ls-remote`).
@MainActor
final class RemoteFixture {
    let remote = TestRemote()
    let repo: TestRepo
    let clock = MutableClock()
    private let folder = TempDir(prefix: "microdiff-remote-log")
    private let log: String
    private let remoteLog: String
    private let git: FakeGit

    /// `lsRemote`: shell code that runs between the start and the end note of every `git ls-remote` (a sleep, for example).
    /// `hangs`: every `git ls-remote` starts a `sleep 60` (its pid goes to `hungPid`) and waits for it.
    init(lsRemote: String = "", hangs: Bool = false) {
        repo = remote.clone()
        let folder = folder
        log = folder.path + "/calls"
        remoteLog = folder.path + "/remote"
        let body = hangs ? "sleep 60 &\necho $! >> '\(folder.path)/pid'\nwait" : lsRemote
        git = FakeGit.wrapping(logTo: log, lsRemote: "echo start >> '\(remoteLog)'\n\(body)\necho end >> '\(remoteLog)'")
    }

    var checker: RemoteChecker { RemoteChecker(git: git.runner) }

    func makeMonitor(firstCheckDelay: TimeInterval = 0.05) -> RemoteMonitor {
        let clock = clock
        return RemoteMonitor(checker: checker, firstCheckDelay: firstCheckDelay, clock: { clock.now })
    }

    /// A monitor with the real git and the real clock.
    static func liveMonitor() -> RemoteMonitor {
        RemoteMonitor(clock: Date.init)
    }

    func snapshot() -> RepoSnapshot {
        RepoScanner().scan(root: repo.path).repos[0]
    }

    /// The remote moves on and this clone has not fetched.
    func moveRemote() {
        let other = remote.clone(pushingFirstCommit: false)
        other.write("other-\(UUID().uuidString).txt", "elsewhere\n")
        other.commitAll("elsewhere")
        other.git("push", "--quiet")
    }

    private func lines(_ path: String) -> [String] {
        (fileText(path) ?? "").split(separator: "\n").map(String.init)
    }

    /// Calls to the remote so far.
    var remoteCalls: Int { lines(remoteLog).filter { $0 == "start" }.count }

    /// Calls that asked whether HEAD has a commit.
    var ancestorCalls: Int { lines(log).filter { $0.contains(" merge-base ") }.count }

    /// Calls of any kind.
    var gitCalls: Int { lines(log).count }

    /// The most calls to the remote that were under way at the same time.
    var mostRemoteCallsAtOnce: Int {
        var open = 0
        var most = 0
        for line in lines(remoteLog) {
            open += line == "start" ? 1 : -1
            most = max(most, open)
        }
        return most
    }

    /// Waits until a run is over.
    func idle(_ monitor: RemoteMonitor) async -> Bool {
        await waitUntil { !monitor.isRunning }
    }

    /// Pids of the `sleep`s that hanging `git ls-remote` calls started so far.
    var hungPids: [Int32] {
        (fileText(folder.path + "/pid") ?? "").split(separator: "\n").compactMap { Int32($0) }
    }

    var hungPid: Int32? { hungPids.first }

    /// Whether any of those processes still exists.
    var hungProcessExists: Bool {
        hungPids.contains { kill($0, 0) == 0 }
    }

    /// Calls to the remote made in the repository at `path`.
    func remoteCalls(in path: String) -> Int {
        lines(log).filter { $0.contains(" ls-remote ") && $0.contains("-C \(path) ") }.count
    }

    /// `count` more clones, each of a remote of its own, following `origin/main`. Keep the result alive.
    func moreRepos(_ count: Int) -> [(repo: TestRepo, remote: TestRemote, seed: TestRepo)] {
        (0..<count).map { _ in
            let remote = TestRemote()
            let seed = remote.clone()
            let repo = TestRepo(cloning: remote.path)
            return (repo, remote, seed)
        }
    }

    func snapshot(of repo: TestRepo) -> RepoSnapshot {
        RepoScanner().scan(root: repo.path).repos[0]
    }
}
