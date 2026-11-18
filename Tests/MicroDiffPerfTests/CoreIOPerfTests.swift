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

        @Test func repoScanWithIgnoredFolder() throws {
            let root = Fixtures.ignoredRepo.path
            let scanner = RepoScanner()
            let status = try #require(scanner.readStatus(in: root))
            #expect(Set(status.ignored) == ["node_modules/", ".nuxt/", ".env", "debug.log"])
            let m = measure(iterations: 7) { blackHole(scanner.readStatus(in: root)) }
            #expect(report("status-20k-ignored", m, budgetMs: 80))
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
