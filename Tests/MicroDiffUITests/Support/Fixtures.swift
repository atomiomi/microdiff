import Foundation
import MicroDiffTestSupport

/// Throwaway repositories the UI tests run against. Built once per call; the files are removed
/// when the returned object is released.
enum Fixture {
    /// 40 numbered Swift-looking lines, so a change in the middle leaves folds above and below.
    static func numberedLines(replacing replacements: [Int: String] = [:]) -> String {
        (1...40).map { replacements[$0] ?? "let value\($0) = \($0)" }.joined(separator: "\n") + "\n"
    }

    static let binaryOld = Data([0, 1, 2, 3, 4, 5, 6, 7, 0, 9, 10, 11, 0, 13, 14, 15])
    static let binaryNew = Data([0, 9, 9, 9, 4, 5, 6, 7, 0, 9, 10, 11, 0, 13, 14, 15])

    /// One of everything, on top of a first commit:
    /// modified `src/app.swift` (two hunks, folds in between), modified `src/other.swift`,
    /// modified binary `data.bin`, deleted `docs/old.txt`, staged rename `docs/rename-me.txt` -> `docs/renamed.txt`,
    /// untracked `new/deep/fresh.txt`. Unchanged: `README.md`, `src/ui/widgets/panel.swift`.
    static func changesRepo() -> TestRepo {
        let repo = TestRepo()
        repo.write("README.md", "# fixture\n\nsome words\n")
        repo.write("src/app.swift", numberedLines())
        repo.write("src/other.swift", "let other = 1\nlet more = 2\n")
        repo.write("src/ui/widgets/panel.swift", "struct Panel {}\n")
        repo.write("docs/old.txt", "old one\nold two\n")
        repo.write("docs/rename-me.txt", "will be renamed\nand stay the same\n")
        repo.write("data.bin", binaryOld)
        repo.commitAll("first")

        repo.write("src/app.swift", numberedLines(replacing: [20: "let value20 = 2000", 36: "let value36 = 3600"]))
        repo.write("src/other.swift", "let other = 10\nlet more = 2\n")
        repo.write("data.bin", binaryNew)
        repo.remove("docs/old.txt")
        repo.git("mv", "docs/rename-me.txt", "docs/renamed.txt")
        repo.write("new/deep/fresh.txt", "fresh file\nsecond line\n")
        return repo
    }

    /// A parent repository whose submodule `vendor/lib` has a modified `lib.c` inside.
    static func submoduleRepo() -> TestRepo {
        let library = TestRepo()
        library.write("lib.c", "int lib(void) {\n    return 1;\n}\n")
        library.commitAll("lib")

        let repo = TestRepo()
        repo.write("main.c", "int main(void) { return 0; }\n")
        repo.addSubmodule(from: library, at: "vendor/lib")
        repo.commitAll("with submodule")

        repo.write("vendor/lib/lib.c", "int lib(void) {\n    return 2;\n}\n")
        return repo
    }

    static func cleanRepo() -> TestRepo {
        let repo = TestRepo()
        repo.write("README.md", "# clean\n")
        repo.commitAll("only commit")
        return repo
    }

    /// A folder with a file in it that is not a git repository.
    static func plainFolder() -> TempDir {
        let dir = TempDir(prefix: "microdiff-plain")
        dir.write("notes/todo.txt", "nothing\n")
        dir.write("top.txt", "top\n")
        return dir
    }
}

/// The last component of a path.
func folderName(_ path: String) -> String {
    (path as NSString).lastPathComponent
}
