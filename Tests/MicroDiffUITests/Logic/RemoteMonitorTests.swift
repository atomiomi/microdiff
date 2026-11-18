import AppKit
import MicroDiffCore
import MicroDiffTestSupport
import Testing

@testable import MicroDiffUI

extension UITests {
    /// The remote checks of a window: when they run, what they find, that they stop. Remotes are bare repositories in
    /// temporary folders and git is a wrapper that notes its calls: nothing touches a network.
    @MainActor
    @Suite
    struct RemoteMonitorTests {
        /// Runs the first check of a visible, enabled monitor and waits for it to finish.
        private func firstRun(_ fixture: RemoteFixture, _ monitor: RemoteMonitor) async -> Bool {
            monitor.enable()
            monitor.setVisible(true)
            monitor.update(repos: [fixture.snapshot()])
            guard await waitUntil({ fixture.remoteCalls == 1 }) else { return false }
            return await fixture.idle(monitor)
        }

        // MARK: What it finds

        @Test func theFirstScanStartsAFirstCheckThatFindsWhatGitCannotKnow() async {
            let fixture = RemoteFixture()
            fixture.moveRemote()
            let monitor = fixture.makeMonitor()
            var changes = 0
            monitor.onChange = { changes += 1 }
            let repo = fixture.snapshot()
            #expect(monitor.sync(for: repo) == nil, "git alone does not know the remote moved")

            #expect(await firstRun(fixture, monitor))
            #expect(monitor.sync(for: repo)?.pull == true)
            #expect(monitor.sync(for: repo)?.checkedAt == fixture.clock.now)
            #expect(changes == 1)
        }

        @Test func aWindowThatIsNotVisibleWaitsForItsFirstCheckUntilItIs() async {
            let fixture = RemoteFixture()
            fixture.moveRemote()
            let monitor = fixture.makeMonitor()
            monitor.enable()
            monitor.update(repos: [fixture.snapshot()])
            #expect(!monitor.hasPendingTimer)
            try? await Task.sleep(for: .milliseconds(200))
            #expect(fixture.remoteCalls == 0)

            monitor.setVisible(true)
            #expect(await waitUntil { fixture.remoteCalls == 1 })
            #expect(await fixture.idle(monitor))
            #expect(monitor.sync(for: fixture.snapshot())?.pull == true)
        }

        @Test func aRepositoryThatIsUpToDateHasNoMarks() async {
            let fixture = RemoteFixture()
            let monitor = fixture.makeMonitor()
            #expect(await firstRun(fixture, monitor))
            #expect(monitor.sync(for: fixture.snapshot()) == nil)
        }

        @Test func withoutBeingEnabledItNeverAsksButStillShowsWhatGitKnows() async {
            let fixture = RemoteFixture()
            fixture.repo.write("new.txt", "mine\n")
            fixture.repo.commitAll("mine")
            let monitor = fixture.makeMonitor()
            monitor.setVisible(true)
            monitor.update(repos: [fixture.snapshot()])
            monitor.windowBecameKey()
            monitor.refresh()
            try? await Task.sleep(for: .milliseconds(300))
            #expect(fixture.remoteCalls == 0)
            #expect(fixture.gitCalls == 0)
            #expect(!monitor.hasPendingTimer)
            #expect(monitor.sync(for: fixture.snapshot())?.push == true)
        }

        @Test func aFailureGivesNoMarkAndNoMessage() async {
            let fixture = RemoteFixture()
            fixture.repo.git("remote", "set-url", "origin", fixture.repo.path + "/gone")
            let monitor = fixture.makeMonitor()
            var changes = 0
            monitor.onChange = { changes += 1 }
            #expect(await firstRun(fixture, monitor))
            #expect(monitor.sync(for: fixture.snapshot()) == nil)
            #expect(changes == 0)
        }

        // MARK: When it asks

        @Test func becomingKeyAsksAgainOnlyAfterFiveMinutes() async {
            let fixture = RemoteFixture()
            let monitor = fixture.makeMonitor()
            #expect(await firstRun(fixture, monitor))

            fixture.clock.advance(minutes: 4)
            monitor.windowBecameKey()
            try? await Task.sleep(for: .milliseconds(150))
            #expect(fixture.remoteCalls == 1)

            fixture.clock.advance(minutes: 2)
            monitor.windowBecameKey()
            #expect(await waitUntil { fixture.remoteCalls == 2 })
            #expect(await fixture.idle(monitor))
        }

        @Test func becomingVisibleAgainAsksOnlyAfterFiveMinutes() async {
            let fixture = RemoteFixture()
            let monitor = fixture.makeMonitor()
            #expect(await firstRun(fixture, monitor))

            monitor.setVisible(false)
            fixture.clock.advance(minutes: 1)
            monitor.setVisible(true)
            try? await Task.sleep(for: .milliseconds(150))
            #expect(fixture.remoteCalls == 1)

            monitor.setVisible(false)
            fixture.clock.advance(minutes: 10)
            monitor.setVisible(true)
            #expect(await waitUntil { fixture.remoteCalls == 2 })
            #expect(await fixture.idle(monitor))
        }

        @Test func aRefreshAsksAtOnceWhateverTheClockSays() async {
            let fixture = RemoteFixture()
            let monitor = fixture.makeMonitor()
            #expect(await firstRun(fixture, monitor))
            monitor.refresh()
            #expect(await waitUntil { fixture.remoteCalls == 2 })
            #expect(await fixture.idle(monitor))
            monitor.refresh()
            #expect(await waitUntil { fixture.remoteCalls == 3 })
        }

        @Test func noTimerRunsWhileTheWindowIsNotVisible() async {
            let fixture = RemoteFixture()
            let monitor = fixture.makeMonitor()
            #expect(await firstRun(fixture, monitor))
            #expect(monitor.hasPendingTimer, "the five-minute timer waits while visible")
            monitor.setVisible(false)
            #expect(!monitor.hasPendingTimer)
            monitor.setVisible(true)
            #expect(monitor.hasPendingTimer)
            monitor.stop()
            #expect(!monitor.hasPendingTimer)
        }

        // MARK: Failures

        @Test func aRepositoryThatKeepsFailingIsLeftAloneForHalfAnHourButRefreshAsksAgain() async {
            let fixture = RemoteFixture()
            fixture.repo.git("remote", "set-url", "origin", fixture.repo.path + "/gone")
            let monitor = fixture.makeMonitor()
            #expect(await firstRun(fixture, monitor))

            fixture.clock.advance(minutes: 10)
            monitor.windowBecameKey()
            #expect(await waitUntil { fixture.remoteCalls == 2 }, "one failure may be a network that was not up yet: asked again")
            #expect(await fixture.idle(monitor))

            fixture.clock.advance(minutes: 10)
            monitor.windowBecameKey()
            try? await Task.sleep(for: .milliseconds(200))
            #expect(await fixture.idle(monitor))
            #expect(fixture.remoteCalls == 2, "failed twice in a row: in its failure wait")

            fixture.clock.advance(minutes: 10)
            monitor.refresh()
            #expect(await waitUntil { fixture.remoteCalls == 3 }, "a refresh always tries")
            #expect(await fixture.idle(monitor))

            fixture.clock.advance(minutes: 31)
            monitor.windowBecameKey()
            #expect(await waitUntil { fixture.remoteCalls == 4 }, "the wait is over")
        }

        // MARK: One at a time

        @Test func aRefreshDuringARunWaitsForItAndNeverRunsAtTheSameTime() async {
            let fixture = RemoteFixture(lsRemote: "sleep 0.4")
            let monitor = fixture.makeMonitor()
            monitor.enable()
            monitor.setVisible(true)
            monitor.update(repos: [fixture.snapshot()])
            monitor.refresh()
            #expect(await waitUntil { monitor.isRunning })
            monitor.refresh()
            monitor.refresh()
            monitor.windowBecameKey()
            #expect(await waitUntil(timeout: .seconds(20)) { fixture.remoteCalls == 2 && !monitor.isRunning })
            try? await Task.sleep(for: .milliseconds(200))
            #expect(fixture.remoteCalls == 2, "the refreshes during the run became one more run")
            #expect(fixture.mostRemoteCallsAtOnce == 1)
        }

        @Test func repositoriesAreCheckedOneAfterAnother() async {
            let fixture = RemoteFixture(lsRemote: "sleep 0.2")
            let nested = fixture.remote.clone(pushingFirstCommit: false)
            let monitor = fixture.makeMonitor()
            monitor.enable()
            monitor.update(repos: [fixture.snapshot(), RepoScanner().scan(root: nested.path).repos[0]])
            monitor.refresh()
            #expect(await waitUntil(timeout: .seconds(20)) { fixture.remoteCalls == 2 && !monitor.isRunning })
            #expect(fixture.mostRemoteCallsAtOnce == 1)
        }

        // MARK: After a pull

        @Test func afterAPullTheMarkGoesWithOneLocalQuestionAndNoCallToTheRemote() async throws {
            let fixture = RemoteFixture()
            fixture.moveRemote()
            let monitor = fixture.makeMonitor()
            #expect(await firstRun(fixture, monitor))
            #expect(monitor.sync(for: fixture.snapshot())?.pull == true)
            #expect(fixture.ancestorCalls == 1)

            fixture.repo.git("pull", "--quiet", "--ff-only")
            let pulled = fixture.snapshot()
            #expect(monitor.sync(for: pulled) == nil, "git already knows: nothing behind")
            monitor.update(repos: [pulled])
            #expect(await waitUntil { fixture.ancestorCalls == 2 })
            #expect(await fixture.idle(monitor))
            #expect(monitor.sync(for: pulled) == nil)
            #expect(fixture.remoteCalls == 1)

            // Scans that find nothing new ask nothing.
            let calls = fixture.gitCalls
            for _ in 0..<5 { monitor.update(repos: [fixture.snapshot()]) }
            try? await Task.sleep(for: .milliseconds(100))
            #expect(fixture.ancestorCalls == 2)
            #expect(fixture.gitCalls == calls)
        }

        @Test func aNewCommitOfTheRemoteIsFoundWithAskingWhetherHeadHasIt() async {
            let fixture = RemoteFixture()
            let monitor = fixture.makeMonitor()
            #expect(await firstRun(fixture, monitor))
            #expect(monitor.sync(for: fixture.snapshot()) == nil)
            fixture.moveRemote()
            monitor.refresh()
            #expect(await waitUntil { fixture.remoteCalls == 2 })
            #expect(await fixture.idle(monitor))
            #expect(monitor.sync(for: fixture.snapshot())?.pull == true)
        }

        @Test func aChangedBranchOrUpstreamStartsFromNothing() async {
            let fixture = RemoteFixture()
            fixture.moveRemote()
            let monitor = fixture.makeMonitor()
            #expect(await firstRun(fixture, monitor))
            fixture.repo.git("checkout", "--quiet", "-b", "other")
            monitor.update(repos: [fixture.snapshot()])
            #expect(monitor.sync(for: fixture.snapshot()) == nil, "no upstream on the new branch")
            fixture.repo.git("checkout", "--quiet", "main")
            monitor.update(repos: [fixture.snapshot()])
            #expect(monitor.sync(for: fixture.snapshot())?.pull != true, "what was learned on main is forgotten")
        }

        // MARK: Clean nested repositories

        @Test func cleanNestedRepositoriesAreCheckedToo() async {
            let fixture = RemoteFixture()
            let other = TestRemote()
            let seed = other.clone()
            fixture.repo.git("clone", "--quiet", other.path, "inner")
            seed.write("later.txt", "later\n")
            seed.commitAll("later")
            seed.git("push", "--quiet")
            let snapshot = RepoScanner().scan(root: fixture.repo.path)
            #expect(snapshot.repos.count == 1 && snapshot.quietRepos.count == 1)

            let monitor = fixture.makeMonitor()
            monitor.enable()
            monitor.update(repos: snapshot.allRepos)
            monitor.refresh()
            #expect(await waitUntil { fixture.remoteCalls == 2 && !monitor.isRunning })
            #expect(monitor.sync(for: snapshot.quietRepos[0])?.pull == true, "the clean one is behind and git did not know")
            #expect(monitor.sync(for: snapshot.repos[0]) == nil)
            withExtendedLifetime(other) {}
        }

        @Test func aNestedRepositoryThatDisappearsIsForgotten() async {
            let fixture = RemoteFixture()
            let other = TestRemote()
            let seed = other.clone()
            fixture.repo.git("clone", "--quiet", other.path, "inner")
            seed.write("later.txt", "later\n")
            seed.commitAll("later")
            seed.git("push", "--quiet")
            let snapshot = RepoScanner().scan(root: fixture.repo.path)
            let monitor = fixture.makeMonitor()
            monitor.enable()
            monitor.update(repos: snapshot.allRepos)
            monitor.refresh()
            #expect(await waitUntil { fixture.remoteCalls == 2 && !monitor.isRunning })
            #expect(monitor.sync(for: snapshot.quietRepos[0])?.pull == true)

            fixture.repo.remove("inner")
            monitor.update(repos: RepoScanner().scan(root: fixture.repo.path).allRepos)
            #expect(monitor.sync(for: snapshot.quietRepos[0]) == nil, "what was learned about it is gone")
            withExtendedLifetime(other) {}
        }

        // MARK: Stopping

        @Test func stoppingKillsTheCallInProgressAndLetsTheMonitorGo() async {
            let fixture = RemoteFixture(hangs: true)
            var monitor: RemoteMonitor? = fixture.makeMonitor()
            let weakMonitor = WeakRef(monitor)
            monitor?.enable()
            monitor?.update(repos: [fixture.snapshot()])
            monitor?.refresh()
            #expect(await waitUntil { fixture.hungPid != nil })
            #expect(fixture.hungProcessExists)

            monitor?.stop()
            #expect(monitor?.isRunning == false)
            #expect(await eventually { !fixture.hungProcessExists }, "the call was killed, not left to time out")
            monitor = nil
            #expect(await eventually { weakMonitor.isGone })
        }

        @Test func closingTheWindowStopsTheChecksAndFreesEverything() async {
            let fixture = RemoteFixture(hangs: true)
            var controller: MainWindowController? = MainWindowController(path: fixture.repo.path, remote: fixture.makeMonitor())
            let weakController = WeakRef(controller)
            let weakMonitor = WeakRef(controller?.workspace.remote)
            controller?.enableRemoteChecks()
            controller?.workspace.scanNow()
            controller?.refresh(nil)
            #expect(await waitUntil { fixture.hungPid != nil })

            withPool { controller?.window.close() }
            #expect(controller?.workspace.remote.isEnabled == false)
            #expect(await eventually { !fixture.hungProcessExists })
            controller = nil
            #expect(await eventually { weakController.isGone && weakMonitor.isGone })
        }

        @Test func openingAnotherFolderStopsTheOldChecksAndStartsNewOnes() async {
            let fixture = RemoteFixture(hangs: true)
            let other = TestRepo()
            other.write("a.txt", "x\n")
            other.commitAll("first")
            let controller = MainWindowController(path: fixture.repo.path, remote: fixture.makeMonitor())
            controller.enableRemoteChecks()
            let old = controller.workspace.remote
            controller.workspace.scanNow()
            controller.refresh(nil)
            #expect(await waitUntil { fixture.hungPid != nil })

            controller.open(path: other.path)
            #expect(!old.isEnabled)
            #expect(controller.workspace.remote !== old)
            #expect(controller.workspace.remote.isEnabled)
            #expect(await eventually { !fixture.hungProcessExists })
            controller.window.close()
        }

        // MARK: Which windows ask

        @Test func snapshotsAndTestWindowsNeverAsk() {
            _ = NSApplication.shared
            let repo = TestRepo()
            let controller = MainWindowController(path: repo.path)
            #expect(!controller.workspace.remote.isEnabled)
            #expect(!WindowManager(showsWindows: false).checksRemotes)
        }

        @Test func aLiveWindowAsksButSnapshotBenchmarkAndSoakRunsDoNot() {
            _ = NSApplication.shared
            func asks(_ arguments: [String]) -> Bool {
                AppDelegate(options: LaunchOptions(arguments: ["MicroDiff"] + arguments), prescan: nil).windows.checksRemotes
            }
            #expect(asks(["/repo"]))
            #expect(!asks(["/repo", "--snapshot", "out.png"]))
            #expect(!asks(["/repo", "--bench"]))
            #expect(!asks(["/repo", "--soak", "5"]))
            let manager = WindowManager(showsWindows: false, checksRemotes: true)
            let repo = TestRepo()
            let controller = manager.makeWindow(path: repo.path)
            #expect(controller.workspace.remote.isEnabled)
            controller.window.close()
        }
    }
}
