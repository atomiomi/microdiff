import MicroDiffCore
import Testing

@Suite struct RemoteSyncTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func ago(_ seconds: Double) -> Date { now.addingTimeInterval(-seconds) }

    // MARK: Marks

    @Test func noUpstreamNoMarks() {
        #expect(RepoSync.make(upstream: nil, isAhead: true, isBehind: true, head: "h", memory: nil) == nil)
    }

    @Test func whatGitKnowsLocallyGivesTheMarksWithoutAnyCheck() {
        let both = RepoSync.make(upstream: "origin/main", isAhead: true, isBehind: true, head: "h", memory: nil)
        #expect(both == RepoSync(upstream: "origin/main", pull: true, push: true, checkedAt: nil))
        #expect(RepoSync.make(upstream: "origin/main", isAhead: false, isBehind: false, head: "h", memory: nil) == nil)
        #expect(RepoSync.make(upstream: "origin/main", isAhead: true, isBehind: false, head: "h", memory: nil)?.pull == false)
    }

    @Test func theRemotesCommitDecidesWhenHeadDoesNotHaveIt() {
        let memory = RemoteMemory(
            commit: "r1", checkedAt: now, ancestry: .init(head: "h", remote: "r1", isAncestor: false))
        let sync = RepoSync.make(upstream: "origin/main", isAhead: false, isBehind: false, head: "h", memory: memory)
        #expect(sync == RepoSync(upstream: "origin/main", pull: true, push: false, checkedAt: now))
    }

    @Test func theRemotesCommitDecidesWhenHeadHasIt() {
        let memory = RemoteMemory(commit: "r1", checkedAt: now, ancestry: .init(head: "h", remote: "r1", isAncestor: true))
        // Even though the last fetch left this clone behind some other commit.
        #expect(RepoSync.make(upstream: "origin/main", isAhead: false, isBehind: true, head: "h", memory: memory) == nil)
    }

    @Test func aBranchThatIsGoneOnTheRemoteHasNothingToPull() {
        let memory = RemoteMemory(commit: nil, checkedAt: now)
        #expect(RepoSync.make(upstream: "origin/main", isAhead: false, isBehind: true, head: "h", memory: memory) == nil)
        let ahead = RepoSync.make(upstream: "origin/main", isAhead: true, isBehind: true, head: "h", memory: memory)
        #expect(ahead == RepoSync(upstream: "origin/main", pull: false, push: true, checkedAt: nil))
    }

    @Test func anAnswerForAnotherHeadIsNotUsed() {
        let memory = RemoteMemory(commit: "r1", checkedAt: now, ancestry: .init(head: "old", remote: "r1", isAncestor: false))
        #expect(RepoSync.make(upstream: "origin/main", isAhead: false, isBehind: false, head: "new", memory: memory) == nil)
        let local = RepoSync.make(upstream: "origin/main", isAhead: false, isBehind: true, head: "new", memory: memory)
        #expect(local == RepoSync(upstream: "origin/main", pull: true, push: false, checkedAt: nil))
    }

    // MARK: Tooltip

    @Test func theToolTipLinesAreThoseThatApplyPullFirst() {
        let both = RepoSync(upstream: "origin/main", pull: true, push: true, checkedAt: ago(120))
        #expect(both.toolTipLines(now: now) == [
            "to pull: new commits on origin/main (checked 2 minutes ago)",
            "to push: commits that are not on origin/main yet",
        ])
        #expect(RepoSync(upstream: "origin/dev", pull: false, push: true).toolTipLines(now: now) == [
            "to push: commits that are not on origin/dev yet"
        ])
        #expect(RepoSync(upstream: "origin/dev", pull: true, push: false).toolTipLines(now: now) == [
            "to pull: new commits on origin/dev"
        ])
        #expect(RepoSync(upstream: "origin/dev", pull: false, push: false).toolTipLines(now: now).isEmpty)
    }

    @Test func theAgeIsWrittenInWords() {
        let cases: [(Double, String)] = [
            (0, "just now"), (59, "just now"), (60, "1 minute ago"), (119, "1 minute ago"), (120, "2 minutes ago"),
            (3599, "59 minutes ago"), (3600, "1 hour ago"), (7200, "2 hours ago"), (86400 * 2, "48 hours ago"), (-30, "just now"),
        ]
        for (seconds, words) in cases { #expect(RepoSync.age(from: ago(seconds), to: now) == words, "\(seconds) s") }
    }

    // MARK: Memory

    @Test func anAnswerIsRememberedWithItsTimeAndAncestry() {
        let memory = RemoteMemory(failedAt: ago(10)).recording(
            .init(answer: .commit("r1"), isAncestor: false), head: "h", at: now)
        #expect(memory == RemoteMemory(
            commit: "r1", checkedAt: now, ancestry: .init(head: "h", remote: "r1", isAncestor: false), failedAt: nil))
        #expect(!memory.needsAncestry(head: "h"))
        #expect(memory.needsAncestry(head: "moved"))
    }

    @Test func aFailureKeepsWhatWasKnownAndNotesWhen() {
        let known = RemoteMemory().recording(.init(answer: .commit("r1"), isAncestor: true), head: "h", at: ago(100))
        let failed = known.recording(.init(answer: .failed), head: "h", at: now)
        #expect(failed.commit == "r1" && failed.checkedAt == ago(100))
        #expect(failed.failedAt == now)
        #expect(failed.failures == 1)
        #expect(failed.recording(.init(answer: .failed), head: "h", at: now).failures == 2)
        #expect(failed.recording(.init(answer: .gone), head: "h", at: now).failures == 0)
    }

    @Test func goneAndNotApplicable() {
        let gone = RemoteMemory().recording(.init(answer: .gone), head: "h", at: now)
        #expect(gone.commit == nil && gone.checkedAt == now)
        #expect(!gone.needsAncestry(head: "h"))
        #expect(RemoteMemory().recording(.init(answer: .notApplicable), head: "h", at: now) == RemoteMemory())
    }

    @Test func theAncestorQuestionIsAskedAgainOnlyWhenHeadOrTheCommitChanged() {
        let memory = RemoteMemory(commit: "r1", checkedAt: now, ancestry: .init(head: "h", remote: "r1", isAncestor: false))
        #expect(!memory.needsAncestry(head: "h"))
        #expect(!memory.needsAncestry(head: nil))
        #expect(memory.needsAncestry(head: "h2"))
        let again = memory.recordingAncestry(head: "h2", isAncestor: true)
        #expect(again.ancestry == .init(head: "h2", remote: "r1", isAncestor: true))
        #expect(!again.needsAncestry(head: "h2"))
        #expect(RemoteMemory(commit: nil).recordingAncestry(head: "h", isAncestor: true).ancestry == nil)
    }

    // MARK: Schedule

    @Test func aManualRefreshIsAlwaysDue() {
        #expect(RemoteSchedule.isDue(.manual, now: now, lastRun: ago(1)))
        #expect(RemoteSchedule.isDue(.manual, now: now, lastRun: nil))
    }

    @Test func becomingKeyOrVisibleIsDueAfterFiveMinutes() {
        for trigger in [RemoteSchedule.Trigger.becameKey, .becameVisible] {
            #expect(RemoteSchedule.isDue(trigger, now: now, lastRun: nil))
            #expect(!RemoteSchedule.isDue(trigger, now: now, lastRun: ago(299)))
            #expect(RemoteSchedule.isDue(trigger, now: now, lastRun: ago(300)))
            #expect(RemoteSchedule.isDue(trigger, now: now, lastRun: ago(3000)))
        }
    }

    @Test func theTimerMayRunASecondEarly() {
        #expect(RemoteSchedule.isDue(.timer, now: now, lastRun: ago(299)))
        #expect(!RemoteSchedule.isDue(.timer, now: now, lastRun: ago(290)))
        #expect(RemoteSchedule.isDue(.timer, now: now, lastRun: nil))
    }

    @Test func theFirstScanIsDueOnlyBeforeAnyRun() {
        #expect(RemoteSchedule.isDue(.firstScan, now: now, lastRun: nil))
        #expect(!RemoteSchedule.isDue(.firstScan, now: now, lastRun: ago(10_000)))
    }

    @Test func theTimerWaitsForTheRestOfTheInterval() {
        #expect(RemoteSchedule.timerDelay(now: now, lastRun: nil) == 300)
        #expect(RemoteSchedule.timerDelay(now: now, lastRun: ago(100)) == 200)
        #expect(RemoteSchedule.timerDelay(now: now, lastRun: ago(1000)) == 0)
    }

    @Test func aRepositoryThatFailedTwiceInARowWaitsHalfAnHourUnlessAskedByHand() {
        #expect(RemoteSchedule.isRepositoryDue(failedAt: nil, failures: 0, now: now, manual: false))
        #expect(RemoteSchedule.isRepositoryDue(failedAt: ago(5), failures: 1, now: now, manual: false), "one failure: asked again")
        #expect(!RemoteSchedule.isRepositoryDue(failedAt: ago(1799), failures: 2, now: now, manual: false))
        #expect(RemoteSchedule.isRepositoryDue(failedAt: ago(1800), failures: 2, now: now, manual: false))
        #expect(RemoteSchedule.isRepositoryDue(failedAt: ago(5), failures: 5, now: now, manual: true))
    }
}
