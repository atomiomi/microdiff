import MicroDiffCore
import Testing

/// Submodules without local changes: found from their git folders, with a process only when something in them moved.
@Suite("RepoScanner: clean submodules")
struct RepoScannerQuietSubmoduleTests {
    /// An outer repository with `count` submodules (`sub0`, `sub1`...), each on `main` following `origin/main`.
    private final class World {
        let outer = TestRepo()
        var remotes: [TestRemote] = []
        var seeds: [TestRepo] = []

        init(_ count: Int) {
            outer.write("main.txt", "m\n")
            outer.commitAll("outer")
            for index in 0..<count {
                let remote = TestRemote()
                seeds.append(remote.clone())
                remotes.append(remote)
                outer.git("submodule", "--quiet", "add", remote.path, "sub\(index)")
            }
            outer.commitAll("submodules")
        }

        func head(_ folder: String) -> String {
            outer.git("rev-parse", "HEAD", in: folder).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// The remote of submodule `index` gets a commit and the submodule fetches it.
        func fetchNewCommit(_ index: Int) {
            seeds[index].write("later.txt", "later\n")
            seeds[index].commitAll("later")
            seeds[index].git("push", "--quiet")
            outer.git("fetch", "--quiet", in: "sub\(index)")
        }
    }

    private let scanner = RepoScanner()

    @Test func aCleanSubmoduleOnABranchIsReportedWithItsBranchUpstreamAndHead() {
        let world = World(2)
        let snapshot = scanner.scan(root: world.outer.path)
        #expect(snapshot.repos.count == 1, "no sections: nothing changed")
        #expect(snapshot.totalChangeCount == 0)
        #expect(snapshot.quietRepos.map(\.displayPath) == ["sub0", "sub1"])
        let first = snapshot.quietRepos[0]
        #expect(first.isSubmodule && !first.isNested)
        #expect(first.name == "sub0" && first.rootPath == world.outer.path + "/sub0")
        #expect(first.branchLabel == "main" && first.hasHead && first.changes.isEmpty)
        #expect(first.upstream == "origin/main")
        #expect(!first.isAhead && !first.isBehind)
        #expect(first.headOID == world.head("sub0"))
        #expect(snapshot.submodulePaths == ["sub0", "sub1"])
    }

    @Test func aheadAfterALocalCommit() {
        let world = World(1)
        world.outer.write("sub0/mine.txt", "mine\n")
        world.outer.commitAll("mine", in: "sub0")
        let quiet = scanner.scan(root: world.outer.path).quietRepos
        #expect(quiet.count == 1)
        #expect(quiet[0].isAhead && !quiet[0].isBehind)
        #expect(quiet[0].headOID == world.head("sub0"))
    }

    @Test func behindAfterAFetchAndBothWhenAlsoAhead() {
        let world = World(1)
        world.fetchNewCommit(0)
        #expect(scanner.scan(root: world.outer.path).quietRepos[0].isBehind)
        world.outer.write("sub0/mine.txt", "mine\n")
        world.outer.commitAll("mine", in: "sub0")
        let quiet = RepoScanner().scan(root: world.outer.path).quietRepos[0]
        #expect(quiet.isAhead && quiet.isBehind)
    }

    @Test func anUpstreamThatIsGoneHasNoMarks() {
        let world = World(1)
        world.outer.git("checkout", "--quiet", "-b", "feature", in: "sub0")
        world.outer.git("push", "--quiet", "-u", "origin", "feature", in: "sub0")
        let other = world.remotes[0].clone(pushingFirstCommit: false)
        other.git("push", "--quiet", "origin", "--delete", "feature")
        world.outer.git("fetch", "--quiet", "--prune", in: "sub0")
        let quiet = scanner.scan(root: world.outer.path).quietRepos[0]
        #expect(quiet.branchLabel == "feature" && quiet.upstream == "origin/feature")
        #expect(!quiet.isAhead && !quiet.isBehind)
    }

    @Test func aDetachedSubmoduleIsNotListedAndNoGitCallIsMadeForIt() {
        let world = World(2)
        world.outer.git("checkout", "--quiet", "--detach", in: "sub0")
        let folder = TempDir()
        let log = folder.path + "/calls"
        let fake = FakeGit.wrapping(logTo: log)
        let snapshot = RepoScanner(git: fake.runner).scan(root: world.outer.path)
        #expect(snapshot.quietRepos.map(\.displayPath) == ["sub1"])
        #expect(!(fileText(log) ?? "").contains("/sub0 "), "git never ran in it")
        withExtendedLifetime((folder, fake)) {}
    }

    @Test func aSubmoduleThatIsNotCheckedOutIsSkipped() {
        let world = World(2)
        world.outer.git("submodule", "--quiet", "deinit", "-f", "sub0")
        let snapshot = scanner.scan(root: world.outer.path)
        #expect(snapshot.quietRepos.map(\.displayPath) == ["sub1"])
        #expect(snapshot.submodulePaths == ["sub0", "sub1"])
    }

    @Test func aSubmoduleInsideASubmoduleIsFoundWithinTheDepthCap() {
        let deepRemote = TestRemote()
        _ = deepRemote.clone()
        let midRemote = TestRemote()
        let mid = midRemote.clone()
        mid.git("submodule", "--quiet", "add", deepRemote.path, "deep")
        mid.commitAll("deep")
        mid.git("push", "--quiet")
        let outer = TestRepo()
        outer.write("main.txt", "m\n")
        outer.commitAll("outer")
        outer.git("submodule", "--quiet", "add", midRemote.path, "mid")
        outer.git("submodule", "--quiet", "update", "--init", "--recursive")
        // `update` leaves the inner one on a detached HEAD (which is never listed): put it on its branch.
        outer.git("checkout", "--quiet", "main", in: "mid/deep")
        outer.commitAll("mid")
        let snapshot = scanner.scan(root: outer.path)
        #expect(snapshot.quietRepos.map(\.displayPath) == ["mid", "mid/deep"])
        #expect(snapshot.quietRepos.allSatisfy { $0.isSubmodule && $0.upstream == "origin/main" })
        withExtendedLifetime((deepRemote, midRemote)) {}
    }

    @Test func anOldStyleSubmoduleWithItsGitFolderInsideIsReadToo() {
        let remote = TestRemote()
        _ = remote.clone()
        let outer = TestRepo()
        outer.write("main.txt", "m\n")
        outer.commitAll("outer")
        outer.git("clone", "--quiet", remote.path, "old")
        // Registering a folder that is already a clone keeps its own `.git` folder.
        outer.git("submodule", "--quiet", "add", remote.path, "old")
        outer.commitAll("old")
        let quiet = scanner.scan(root: outer.path).quietRepos
        #expect(quiet.map(\.displayPath) == ["old"])
        #expect(quiet[0].upstream == "origin/main" && quiet[0].branchLabel == "main")
        withExtendedLifetime(remote) {}
    }

    @Test func aSubmoduleWithChangesIsASectionAndGoesBackToQuietWhenClean() {
        let world = World(2)
        #expect(scanner.scan(root: world.outer.path).quietRepos.count == 2)
        world.outer.write("sub0/x.txt", "new\n")
        var snapshot = scanner.scan(root: world.outer.path)
        #expect(snapshot.repos.map(\.displayPath) == ["", "sub0"])
        #expect(snapshot.repos[1].isSubmodule && snapshot.repos[1].upstream == "origin/main")
        #expect(snapshot.quietRepos.map(\.displayPath) == ["sub1"])
        #expect(scanner.quietSubmodules.count == 1, "the one with changes is no longer remembered")
        world.outer.remove("sub0/x.txt")
        snapshot = scanner.scan(root: world.outer.path)
        #expect(snapshot.repos.count == 1)
        #expect(snapshot.quietRepos.map(\.displayPath) == ["sub0", "sub1"])
        #expect(scanner.quietSubmodules.count == 2)
    }

    // MARK: Cost

    @Test func aScanCostsNoProcessForCleanSubmodulesWhileNothingMoved() {
        let world = World(6)
        let folder = TempDir()
        let log = folder.path + "/calls"
        let fake = FakeGit.wrapping(logTo: log)
        let counting = RepoScanner(git: fake.runner)
        func calls() -> [String] { (fileText(log) ?? "").split(separator: "\n").map(String.init) }

        // Before this change a scan of this workspace ran 2 processes: the root's status and `git config` on `.gitmodules`.
        _ = counting.scan(root: world.outer.path)
        let first = calls()
        #expect(first.count == 2 + 6, "the first scan asks each clean submodule once")
        #expect(first.filter { $0.contains(" for-each-ref ") }.count == 6)

        _ = counting.scan(root: world.outer.path)
        _ = counting.scan(root: world.outer.path)
        #expect(calls().count == first.count + 2 + 2, "later scans run only the 2 processes they always did")

        let before = calls().count
        world.outer.write("sub3/mine.txt", "mine\n")
        world.outer.commitAll("mine", in: "sub3")
        _ = counting.scan(root: world.outer.path)
        let afterCommit = Array(calls().dropFirst(before))
        #expect(afterCommit.count == 2 + 1, "a commit in one costs one call for that one")
        #expect(afterCommit.filter { $0.contains(" for-each-ref ") }.count == 1)
        #expect(afterCommit.contains { $0.contains("/sub3 for-each-ref") })

        _ = counting.scan(root: world.outer.path)
        #expect(calls().count == before + 3 + 2, "and then nothing more for it")

        let beforeFetch = calls().count
        world.fetchNewCommit(1)
        let seen = counting.scan(root: world.outer.path)
        #expect(calls().count - beforeFetch == 2 + 1, "a fetch likewise")
        #expect(seen.quietRepos.first { $0.displayPath == "sub1" }?.isBehind == true)
        #expect(seen.quietRepos.first { $0.displayPath == "sub3" }?.isAhead == true)
        withExtendedLifetime((folder, fake)) {}
    }

    @Test func aPushIsNoticedToo() {
        let world = World(1)
        world.outer.write("sub0/mine.txt", "mine\n")
        world.outer.commitAll("mine", in: "sub0")
        #expect(scanner.scan(root: world.outer.path).quietRepos[0].isAhead)
        world.outer.git("push", "--quiet", in: "sub0")
        #expect(!scanner.scan(root: world.outer.path).quietRepos[0].isAhead, "only the remote-tracking ref moved")
    }

    @Test func aCheckoutOfAnotherBranchIsNoticed() {
        let world = World(1)
        _ = scanner.scan(root: world.outer.path)
        world.outer.git("checkout", "--quiet", "-b", "topic", in: "sub0")
        let quiet = scanner.scan(root: world.outer.path).quietRepos[0]
        #expect(quiet.branchLabel == "topic" && quiet.upstream == nil)
        world.outer.git("checkout", "--quiet", "--detach", in: "sub0")
        #expect(scanner.scan(root: world.outer.path).quietRepos.isEmpty)
    }

    // MARK: Memory of answers

    @Test func theMemoryIsForgottenForARemovedOrDeinitializedSubmodule() {
        let world = World(3)
        #expect(scanner.scan(root: world.outer.path).quietRepos.count == 3)
        #expect(scanner.quietSubmodules.count == 3)
        world.outer.git("submodule", "--quiet", "deinit", "-f", "sub0")
        _ = scanner.scan(root: world.outer.path)
        #expect(scanner.quietSubmodules.count == 2)
        world.outer.git("rm", "--quiet", "-f", "sub1")
        _ = scanner.scan(root: world.outer.path)
        #expect(scanner.quietSubmodules.count == 1)
        world.outer.git("checkout", "--quiet", "--detach", in: "sub2")
        _ = scanner.scan(root: world.outer.path)
        #expect(scanner.quietSubmodules.count == 0)
    }

    @Test func scannersShareNothing() {
        let world = World(2)
        let a = RepoScanner()
        let b = RepoScanner()
        #expect(a.quietSubmodules !== b.quietSubmodules)
        _ = a.scan(root: world.outer.path)
        #expect(a.quietSubmodules.count == 2)
        #expect(b.quietSubmodules.count == 0)

        let folder = TempDir()
        let log = folder.path + "/calls"
        let fake = FakeGit.wrapping(logTo: log)
        let other = RepoScanner(git: fake.runner)
        _ = other.scan(root: world.outer.path)
        #expect((fileText(log) ?? "").split(separator: "\n").filter { $0.contains(" for-each-ref ") }.count == 2, "it starts from nothing")
        withExtendedLifetime((folder, fake)) {}
    }

    @Test func theMemoryIsBounded() {
        // Folders that look like checked-out submodules on a branch, and a git that answers the same for all.
        let folders = TempDir()
        let fake = FakeGit("printf '1111111111111111111111111111111111111111\\\\0origin/main\\\\0\\\\0refs/remotes/origin/main\\\\n'")
        let memory = QuietSubmodules()
        for index in 0..<(QuietSubmodules.limit + 200) {
            folders.write("s\(index)/.git/HEAD", "ref: refs/heads/main\n")
            _ = memory.read(folder: folders.path + "/s\(index)", displayPath: "s\(index)", git: fake.runner)
            #expect(memory.count <= QuietSubmodules.limit)
        }
        #expect(memory.count > 0)
        memory.keepOnly([])
        #expect(memory.count == 0)
    }

    @Test func aLayoutThatCannotBeReadIsAskedAboutOnEveryScan() {
        // A linked work tree style git folder (it has `commondir`): never guessed, always asked.
        let world = World(1)
        let folder = TempDir()
        let log = folder.path + "/calls"
        let fake = FakeGit.wrapping(logTo: log)
        let counting = RepoScanner(git: fake.runner)
        world.outer.write(".git/modules/sub0/commondir", ".\n")
        for _ in 0..<3 { #expect(counting.scan(root: world.outer.path).quietRepos.count == 1) }
        let calls = (fileText(log) ?? "").split(separator: "\n")
        #expect(calls.filter { $0.contains(" for-each-ref ") }.count == 3)
        withExtendedLifetime((folder, fake)) {}
    }
}
