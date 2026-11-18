import Foundation
import MicroDiffCore
import MicroDiffTestSupport

// Inputs built once per run (lazy statics) and shared by every test, so the suite stays fast
// and no fixture cost lands in a measured region. Temp folders live until the process exits
// (statics are never released; /tmp is cleaned by the OS).
enum Fixtures {
    static let statusData = Generate.statusOutput(records: 10_000)
    static let changesSnapshot = Generate.snapshot(repoSizes: [6000, 3000, 1000], folders: [600, 300, 100])
    static let bigBuffer: Data = Generate.plainText(lines: 200_000)
    static let patchData = Generate.patch(hunks: 50_000)
    static let swift100k = TextBuffer(Data(Generate.swiftSource(lines: 100_000, unique: false).utf8))
    static let vue50k = TextBuffer(Data(Generate.vueSource(lines: 50_000).utf8))

    /// Copies the bytes for real (a plain `Data(data)` shares storage), so memory tests see them.
    static func freshCopy(_ data: Data) -> Data {
        // Exactly `count` bytes: Data(count:), Data(repeating:count:) and Array(buffer) all round big sizes up
        // (10 MB -> 12 MiB), which would blur what the memory tests measure.
        let bytes = data.withUnsafeBytes { source in
            [UInt8](unsafeUninitializedCapacity: source.count) { target, initialized in
                _ = memcpy(target.baseAddress!, source.baseAddress!, source.count)
                initialized = source.count
            }
        }
        return Data(bytes)
    }

    // MARK: - On disk

    /// One folder with 5,000 files.
    static let flatFolder: TempDir = {
        let dir = TempDir(prefix: "perf-flat")
        for i in 0..<5000 { dir.write("file_\(i).txt", "x") }
        return dir
    }()

    /// 50 folders (d00...d49) of 100 files each.
    static let wideFolder: TempDir = {
        let dir = TempDir(prefix: "perf-wide")
        for d in 0..<50 {
            for f in 0..<100 { dir.write(String(format: "d%02d/file_%d.txt", d, f), "x") }
        }
        return dir
    }()

    /// 2,000 tracked files in 100 folders; 200 modified, 50 untracked.
    static let bigRepo: TestRepo = {
        let repo = TestRepo()
        for i in 0..<2000 { repo.write("dir\(i % 100)/file_\(i).txt", "line one\nline two \(i)\n") }
        repo.commitAll("initial")
        for i in 0..<200 { repo.write("dir\(i % 100)/file_\(i).txt", "line one\nline two changed \(i)\nline three\n") }
        for i in 0..<50 { repo.write("untracked/new_\(i).txt", "new \(i)\n") }
        return repo
    }()

    /// A 5,000-line Swift file with 20 one-line edits spread over it.
    static let docRepo: TestRepo = {
        let repo = TestRepo()
        let original = Generate.swiftSource(lines: 5000)
        repo.write("Big.swift", original)
        repo.commitAll("initial")
        var lines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for k in 0..<20 { lines[k * 250 + 10] = "    let edited\(k) = \(k) * 2 // changed" }
        repo.write("Big.swift", lines.joined(separator: "\n"))
        return repo
    }()

    /// 50 tracked files plus an ignored `node_modules` with 20,000 files, a `.nuxt` folder and a few ignored single files.
    static let ignoredRepo: TestRepo = {
        let repo = TestRepo()
        repo.write(".gitignore", "node_modules\n.nuxt\n.env\n*.log\n")
        for k in 0..<50 { repo.write("src/f\(k).ts", "export const a\(k) = \(k)\n") }
        repo.commitAll("initial")
        for d in 0..<200 { for k in 0..<100 { repo.write("node_modules/p\(d)/f\(k).js", "x") } }
        repo.write(".nuxt/a.js", "x")
        repo.write(".env", "A=1")
        repo.write("debug.log", "x")
        repo.write("src/new.ts", "export {}\n")
        return repo
    }()

    /// 200 tracked files, plus a nested repository with 300 files of which 40 are modified.
    static let nestedRepo: TestRepo = {
        let repo = TestRepo()
        for k in 0..<200 { repo.write("src/f\(k).ts", "export const a\(k) = \(k)\n") }
        repo.commitAll("initial")
        repo.git("init", "--quiet", "inner")
        for k in 0..<300 { repo.write("inner/g\(k).ts", "export const b\(k) = \(k)\n") }
        repo.commitAll("nested", in: "inner")
        for k in 0..<40 { repo.write("inner/g\(k).ts", "export const b\(k) = \(k + 1)\n") }
        return repo
    }()

    /// 200 tracked files and 30 clean submodules on `main` following `origin/main`.
    static let submoduleRepo: TestRepo = {
        let source = TestRepo()
        source.write("lib.txt", "library\n")
        source.commitAll("library")
        let repo = TestRepo()
        for k in 0..<200 { repo.write("src/f\(k).ts", "export const a\(k) = \(k)\n") }
        repo.commitAll("initial")
        for k in 0..<30 { repo.addSubmodule(from: source, at: "vendor/lib\(k)") }
        repo.commitAll("submodules")
        keepAlive.append(source)
        return repo
    }()

    /// The same 200 files and nothing else.
    static let plainRepo: TestRepo = {
        let repo = TestRepo()
        for k in 0..<200 { repo.write("src/f\(k).ts", "export const a\(k) = \(k)\n") }
        repo.commitAll("initial")
        return repo
    }()

    /// The submodules were cloned from this (their `origin`): it must outlive them.
    nonisolated(unsafe) private static var keepAlive: [TestRepo] = []

    private static let bigFileDir = TempDir(prefix: "perf-bigfile")

    /// A 10 MB text file.
    static let bigFile: String = bigFileDir.write("big.txt", bigBuffer)

    /// The document the loader builds for `Big.swift`, in the given mode.
    static func document(mode: ViewMode) -> TextDocument {
        let scanner = RepoScanner()
        let snapshot = scanner.scan(root: docRepo.path)
        let repo = snapshot.repos[0]
        let request = DocumentRequest(path: repo.rootPath + "/Big.swift", repo: repo, change: repo.changes[0], mode: mode)
        guard case .text(let document) = DocumentLoader(scanner: scanner).load(request) else { fatalError("no text document") }
        return document
    }

    /// `Big.swift` as it is on disk (20 edited lines against HEAD).
    static let docRepoText: Data = FileManager.default.contents(atPath: docRepo.path + "/Big.swift") ?? Data()

    static let diffDocument = document(mode: .diff)
    static let fileDocument = document(mode: .read)
}
