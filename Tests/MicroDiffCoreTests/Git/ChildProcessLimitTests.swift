import Dispatch
import MicroDiffCore
import Testing

/// The time limit and the cancel switch of `ChildProcess.run`.
@Suite struct ChildProcessLimitTests {
    private func shell(_ script: String, limit: ChildProcess.Limit?) -> ChildProcess.Result? {
        ChildProcess.run(path: "/bin/sh", arguments: ["sh", "-c", script], environment: ChildProcess.environment(overriding: [:]), limit: limit)
    }

    /// Polls until `condition` holds or about `seconds` passed.
    private func eventually(seconds: Int = 5, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<(seconds * 200) {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func aProcessThatFinishesInTimeIsLeftAlone() throws {
        let result = try #require(shell("echo hello; echo oops >&2; exit 3", limit: .init(seconds: 10)))
        #expect(!result.wasStopped)
        #expect(result.exitCode == 3)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "hello\n")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "oops\n")
    }

    @Test func aProcessThatRunsTooLongIsKilledAtTheLimit() throws {
        let start = ContinuousClock.now
        let result = try #require(shell("sleep 60", limit: .init(seconds: 0.4)))
        let took = ContinuousClock.now - start
        #expect(result.wasStopped)
        #expect(took >= .milliseconds(350))
        #expect(took < .seconds(5))
    }

    @Test func everythingTheProcessStartedIsKilledToo() async throws {
        let folder = TempDir()
        let pidFile = folder.path + "/pid"
        let result = try #require(shell("sleep 60 & echo $! > '\(pidFile)'; wait", limit: .init(seconds: 0.4)))
        #expect(result.wasStopped)
        let pid = try #require(fileText(pidFile).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        #expect(await eventually { !processExists(pid) }, "the grandchild is gone")
    }

    @Test func aGrandchildHoldingThePipeDoesNotKeepUsWaiting() throws {
        // The shell exits at once, its background child keeps stdout open for a minute.
        let start = ContinuousClock.now
        let result = try #require(shell("sleep 60 & exit 0", limit: .init(seconds: 0.4)))
        #expect(result.wasStopped)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func cancellingStopsTheProcessAtOnce() async throws {
        let token = CancelToken()
        // Not a Task: the process runs on the thread that waits for it, and the task pool may be busy with other tests.
        // Timed from the moment of cancelling: a busy machine may be slow to start the process or the timer.
        nonisolated(unsafe) var cancelledAt: ContinuousClock.Instant?
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            cancelledAt = .now
            token.cancel()
        }
        let result = try #require(shell("sleep 60", limit: .init(seconds: 60, cancel: token)))
        let end = ContinuousClock.now
        #expect(result.wasStopped)
        #expect(try #require(cancelledAt) <= end)
        #expect(end - (cancelledAt ?? end) < .seconds(3))
    }

    @Test func aTokenCancelledBeforehandStopsItAtTheFirstLook() throws {
        let token = CancelToken()
        token.cancel()
        let result = try #require(shell("sleep 60", limit: .init(seconds: 60, cancel: token)))
        #expect(result.wasStopped)
    }

    @Test func stoppedRunsLeaveNoDescriptorsBehind() throws {
        _ = shell("sleep 60", limit: .init(seconds: 0.05))
        let before = openDescriptorCount()
        for _ in 0..<40 { _ = shell("sleep 60", limit: .init(seconds: 0.05)) }
        // Other tests open and close files meanwhile; a leak would be two descriptors per run.
        #expect(openDescriptorCount() < before + 30)
    }

    @Test func withoutALimitNothingChanges() throws {
        let result = try #require(shell("echo plain", limit: nil))
        #expect(!result.wasStopped)
        #expect(result.exitCode == 0)
    }

    @Test func aLimitedProcessHasNoControllingTerminal() throws {
        let result = try #require(shell("ps -o tty= -p $$", limit: .init(seconds: 10)))
        #expect(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "??")
    }
}
