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
        let body = hangs ? "sleep 60 &\necho $! > '\(folder.path)/pid'\nwait" : lsRemote
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

    /// Pid of the `sleep` a hanging `git ls-remote` started, once it did.
    var hungPid: Int32? {
        fileText(folder.path + "/pid").flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Whether that process still exists.
    var hungProcessExists: Bool {
        hungPid.map { kill($0, 0) == 0 } ?? false
    }
}
