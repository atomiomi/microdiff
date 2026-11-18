import MicroDiffCore
import Testing

extension PerfSuite {
    @Suite struct CoreIO {
        @Test func directoryList() {
            let path = Fixtures.flatFolder.path
            #expect(DirectoryLister.list(path).count == 5000)
            let m = measure { blackHole(DirectoryLister.list(path)) }
            #expect(report("directory-list-5000-files", m, budgetMs: 10))
        }

        @Test func fileTreeRows() {
            let dir = Fixtures.wideFolder
            let snapshot = WorkspaceSnapshot(rootPath: dir.path, isGitRepo: false)
            var tree = FileTree(rootPath: dir.path, rootName: "wide")
            for d in 0..<50 { tree.setExpanded(true, path: "d" + (d < 10 ? "0" : "") + "\(d)") }

            #expect(tree.rows(snapshot: snapshot).count == 1 + 50 + 5000)

            // Cold: the listing cache is dropped before every run, so every folder is read from disk.
            let cold = measure(before: { tree.invalidate() }) { blackHole(tree.rows(snapshot: snapshot)) }
            #expect(report("filetree-rows-50x100-cold", cold, budgetMs: 15))

            blackHole(tree.rows(snapshot: snapshot))
            let warm = measure { blackHole(tree.rows(snapshot: snapshot)) }
            #expect(report("filetree-rows-50x100-warm", warm, budgetMs: 3))
        }

        @Test func repoScan() {
            let root = Fixtures.bigRepo.path
            let scanner = RepoScanner()
            #expect(scanner.scan(root: root).totalChangeCount == 250)
            let m = measure(iterations: 7) { blackHole(scanner.scan(root: root)) }
            #expect(report("repo-scan-2000-files-250-changes", m, budgetMs: 80))
        }

        @Test func repoScanWithNestedRepo() {
            let root = Fixtures.nestedRepo.path
            let scanner = RepoScanner()
            let snapshot = scanner.scan(root: root)
            #expect(snapshot.repos.count == 2 && snapshot.totalChangeCount == 40 && snapshot.nestedRepoPaths == ["inner"])
            let m = measure(iterations: 7) { blackHole(scanner.scan(root: root)) }
            #expect(report("repo-scan-nested-repo-500-files-40-changes", m, budgetMs: 80))
        }

        /// 30 clean submodules where nothing moves: after the first scan they cost a few `stat` calls each, no process.
        /// The budget is mostly git's own: `git status --ignore-submodules=none` looks into every submodule (about 7 ms each).
        @Test func repoScanWithManyCleanSubmodules() {
            let root = Fixtures.submoduleRepo.path
            let scanner = RepoScanner()
            let snapshot = scanner.scan(root: root)
            #expect(snapshot.repos.count == 1 && snapshot.quietRepos.count == 30)
            #expect(snapshot.quietRepos.allSatisfy { $0.isSubmodule && $0.upstream == "origin/main" })
            let m = measure(iterations: 7) { blackHole(scanner.scan(root: root)) }
            #expect(report("repo-scan-30-clean-submodules-warm", m, budgetMs: 300))

            // What git itself needs for the same repository (the parent's status with every submodule looked into, and
            // `.gitmodules`): the scan may add very little to it.
            let git = scanner.git
            let own = measure(iterations: 7) {
                blackHole(scanner.readStatus(in: root))
                blackHole(try? git.run(["config", "--file", ".gitmodules", "-z", "--get-regexp", "path"], in: root, allowedExitCodes: [0, 1]))
            }
            #expect(report("repo-scan-30-clean-submodules-git-only", own, budgetMs: 300))
            #expect(m.median < own.median * 1.25 + 5, "the quiet submodules add little to what git costs anyway")

            let plain = RepoScanner()
            let plainRoot = Fixtures.plainRepo.path
            #expect(plain.scan(root: plainRoot).quietRepos.isEmpty)
            let base = measure(iterations: 7) { blackHole(plain.scan(root: plainRoot)) }
            #expect(report("repo-scan-200-files-no-submodules", base, budgetMs: 80))
        }

        @Test func repoScanWithIgnoredFolder() throws {
            let root = Fixtures.ignoredRepo.path
            let scanner = RepoScanner()
            let status = try #require(scanner.readStatus(in: root))
            #expect(Set(status.ignored) == ["node_modules/", ".nuxt/", ".env", "debug.log"])
            let m = measure(iterations: 7) { blackHole(scanner.readStatus(in: root)) }
            #expect(report("status-20k-ignored", m, budgetMs: 80))
        }

        /// The editor's change bars after a pause in typing: the HEAD version against the text, through git, off the
        /// main thread. Measured for a 5,000-line file with 20 edited lines.
        @Test func changeMarks() throws {
            let git = GitRunner()
            let base = try #require(ChangeMarks.base(MarkSource(repoRoot: Fixtures.docRepo.path, headPath: "Big.swift"), git: git))
            let text = Fixtures.docRepoText
            let rows = try #require(ChangeMarks.compute(text: text, base: base, repoRoot: Fixtures.docRepo.path, git: git))
            #expect((0..<rows.rowCount).filter { rows.row(at: $0).mark == .modified }.count == 20)
            let m = measure(iterations: 7) {
                blackHole(ChangeMarks.compute(text: text, base: base, repoRoot: Fixtures.docRepo.path, git: git))
            }
            #expect(report("edit-change-marks-5000-lines", m, budgetMs: 25))
        }

        @Test func documentLoad() throws {
            let scanner = RepoScanner()
            let repo = try #require(scanner.scan(root: Fixtures.docRepo.path).repos.first)
            let request = DocumentRequest(path: repo.rootPath + "/Big.swift", repo: repo, change: repo.changes[0], mode: .diff)
            let loader = DocumentLoader(scanner: scanner)
            guard case .text(let document) = loader.load(request) else { Issue.record("no text document"); return }
            #expect(document.patch.hunks.count == 20)
            let m = measure(iterations: 7) { blackHole(loader.load(request)) }
            #expect(report("document-load-diff-5000-lines-20-hunks", m, budgetMs: 30))
        }

        @Test func textBufferFromFile() {
            let path = Fixtures.bigFile
            let m = measure { blackHole(try? TextBuffer(contentsOfFile: path)) }
            #expect(report("textbuffer-file-10mb", m, budgetMs: 25))
        }
    }
}
