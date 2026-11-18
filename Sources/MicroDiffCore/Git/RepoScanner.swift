import Foundation

/// Reads git state for a folder: what changed, in which repository, and the diff of single files.
/// All calls are synchronous and safe to run on any thread.
package struct RepoScanner: Sendable {
    package let git: GitRunner
    /// What is remembered about clean submodules between scans (see `QuietSubmodules`). One per scanner: scanners made
    /// separately, one per workspace, share nothing, and it goes when the scanner does. Copies of a scanner share it.
    package let quietSubmodules = QuietSubmodules()

    /// How many levels of nested submodules are followed.
    package static let maxSubmoduleDepth = 3

    package init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    /// The folder the app should treat as the workspace root for `path`:
    /// the git top level when `path` is inside a work tree, otherwise `path` itself.
    /// The returned path is absolute, standardized, symlinks resolved, without a trailing slash.
    package func resolveRoot(for path: String) -> (root: String, isGitRepo: Bool) {
        let resolved = Self.normalized(path)
        guard let output = try? git.run(["rev-parse", "--show-toplevel"], in: resolved) else {
            return (resolved, false)
        }
        let top = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard !top.isEmpty else { return (resolved, false) }
        return (Self.normalized(top), true)
    }

    /// Full scan of the workspace. Never throws: when `root` is not a git repository (or git fails)
    /// the result has `isGitRepo == false` and no repos.
    ///
    /// - Root status: `git status --porcelain=v2 --branch -z --untracked-files=all --ignored=matching`.
    /// - `repos[0]` is always the root repository (name = last path component of `root`, displayPath "").
    /// - A submodule becomes its own `RepoSnapshot` only when it has modified or untracked content inside
    ///   AND scanning it yields at least one change. A submodule that only points at a different commit is not listed.
    ///   Nested submodules are followed up to `maxSubmoduleDepth`; `displayPath` is always relative to the workspace root.
    /// - Nested repositories: git reports an untracked folder that holds its own `.git` as ONE entry with a trailing
    ///   slash and never lists its files. Those entries (at any depth git reports them, in the root repo, in scanned
    ///   submodules and in other nested repos) are dropped from the parent's changes. Each one whose folder really
    ///   contains a `.git` is scanned with one more status call. It gets its own `RepoSnapshot` (`isNested`, not
    ///   `isSubmodule`, name and `displayPath` = path relative to the workspace root, file paths relative to the nested
    ///   repo) when it has changes, and its path is listed in `nestedRepoPaths` either way. One without changes is
    ///   reported in `quietRepos` (same snapshot, no extra git call). A nested repo that the parent
    ///   ignores is not reported by git and so is not found. A folder without `.git`, or one whose status fails
    ///   (removed meanwhile), is skipped. A nested repo without commits works like any other ("no commits").
    ///   Submodules and nested repos share the depth cap `maxSubmoduleDepth`; no folders are searched for repositories.
    /// - Submodule and nested repos are sorted together by `displayPath`.
    /// - `quietRepos` (no local changes, sorted by `displayPath`): nested repositories (their status was read anyway) and
    ///   submodules. A submodule whose status was read and shows nothing is in it. The other registered, checked-out
    ///   submodules on a branch are read from their git folders (`QuietSubmodules`: no status call; a process only when
    ///   something in the folder moved). A detached or not checked out submodule is not listed.
    /// - `submodulePaths` lists every submodule registered in `.gitmodules` (recursively through initialized
    ///   submodules up to `maxSubmoduleDepth`), relative to the workspace root, sorted. Empty when there is no `.gitmodules`.
    /// - `branchLabel`: branch name; first 7 characters of the HEAD oid when detached; "no commits" without HEAD.
    package func scan(root: String) -> WorkspaceSnapshot {
        guard let status = readStatus(in: root) else {
            return WorkspaceSnapshot(rootPath: root, isGitRepo: false)
        }
        let name = (root as NSString).lastPathComponent
        let rootRepo = snapshot(status, rootPath: root, displayPath: "", name: name, isSubmodule: false)

        var found = Found()
        collectChildRepos(of: status, rootPath: root, displayPath: "", depth: 1, into: &found)
        found.repos.sort { $0.displayPath < $1.displayPath }
        found.nestedPaths.sort()

        var paths: [String] = []
        collectSubmodulePaths(rootPath: root, displayPath: "", depth: 1, into: &paths)
        paths.sort()

        // Registered submodules that were not scanned (nothing changed inside, as the parent's status said) and are
        // checked out: read from their git folders, which costs no process while nothing moved.
        var kept: Set<String> = []
        for path in paths where !found.scannedSubmodules.contains(path) {
            let folder = root + "/" + path
            kept.insert(folder)
            if let quiet = quietSubmodules.read(folder: folder, displayPath: path, git: git) { found.quiet.append(quiet) }
        }
        quietSubmodules.keepOnly(kept)
        found.quiet.sort { $0.displayPath < $1.displayPath }

        return WorkspaceSnapshot(
            rootPath: root, isGitRepo: true, repos: [rootRepo] + found.repos, submodulePaths: paths, nestedRepoPaths: found.nestedPaths,
            quietRepos: found.quiet)
    }

    /// The diff of one file against HEAD (staged + unstaged together), parsed.
    ///
    /// Runs `git diff HEAD --no-color --no-ext-diff -U0 -M -- <oldPath?> <path>` inside `repo.rootPath`.
    /// Returns `.empty` without running git when the file is untracked, `added`, or the repo has no HEAD.
    package func patch(for change: FileChange, in repo: RepoSnapshot) throws -> FilePatch {
        guard repo.hasHead, !change.isUntracked, change.kind != .added else { return .empty }
        // Literal pathspecs: a file named "*.txt" or ":foo" must not be treated as a pattern.
        var args = ["--literal-pathspecs", "diff", "HEAD", "--no-color", "--no-ext-diff", "--no-textconv", "-U0", "-M", "--"]
        if let oldPath = change.oldPath { args.append(oldPath) }
        args.append(change.path)
        return DiffParser.parse(try git.run(args, in: repo.rootPath))
    }

    /// Raw bytes of `path` as stored in HEAD (`git cat-file blob HEAD:<path>`). Used to show deleted files.
    package func headContents(path: String, in repo: RepoSnapshot) throws -> Data {
        try git.run(["cat-file", "blob", "HEAD:" + path], in: repo.rootPath)
    }

    // MARK: - Private

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    package func readStatus(in directory: String) -> RepoStatus? {
        // --ignore-submodules=none: do not let the user's config hide dirty submodules.
        // --ignored=matching: an ignored directory is one entry and git does not list what is inside.
        let args = ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all", "--ignore-submodules=none", "--ignored=matching"]
        guard let output = try? git.run(args, in: directory) else { return nil }
        return StatusParser.parse(output)
    }

    private func snapshot(_ status: RepoStatus, rootPath: String, displayPath: String, name: String, isSubmodule: Bool, isNested: Bool = false) -> RepoSnapshot {
        let label: String
        if let oid = status.headOID {
            label = status.branch ?? String(oid.prefix(7))
        } else {
            label = "no commits"
        }
        return RepoSnapshot(
            rootPath: rootPath, displayPath: displayPath, name: name, isSubmodule: isSubmodule,
            branchLabel: label, hasHead: status.headOID != nil, changes: status.changes, ignored: status.ignored, isNested: isNested,
            headOID: status.headOID, upstream: status.upstream, isAhead: status.isAhead, isBehind: status.isBehind)
    }

    /// Adds every submodule and nested repository below `parent` that has changes inside, recursing into those that
    /// were scanned. Every nested repository found (clean or not) is added to `nestedPaths`.
    private struct Found {
        /// Submodules and nested repositories with changes.
        var repos: [RepoSnapshot] = []
        /// Without changes (the ones whose status was read anyway; the others come from `QuietSubmodules`).
        var quiet: [RepoSnapshot] = []
        var nestedPaths: [String] = []
        /// Display paths of the submodules whose status was read.
        var scannedSubmodules: Set<String> = []
    }

    private func collectChildRepos(of parent: RepoStatus, rootPath: String, displayPath: String, depth: Int, into found: inout Found) {
        guard depth <= Self.maxSubmoduleDepth else { return }
        for sub in parent.submodules where sub.hasModifiedContent || sub.hasUntrackedContent {
            let subRoot = rootPath + "/" + sub.path
            let subDisplay = displayPath.isEmpty ? sub.path : displayPath + "/" + sub.path
            guard let status = readStatus(in: subRoot) else { continue }
            found.scannedSubmodules.insert(subDisplay)
            let submodule = snapshot(status, rootPath: subRoot, displayPath: subDisplay, name: subDisplay, isSubmodule: true)
            if status.changes.isEmpty { found.quiet.append(submodule) } else { found.repos.append(submodule) }
            collectChildRepos(of: status, rootPath: subRoot, displayPath: subDisplay, depth: depth + 1, into: &found)
        }
        for candidate in parent.nestedRepoCandidates {
            let path = String(candidate.dropLast())
            let nestedRoot = rootPath + "/" + path
            // `.git` is a folder, or a file in a linked work tree. Without it this is just an untracked folder.
            guard FileManager.default.fileExists(atPath: nestedRoot + "/.git"),
                  let status = readStatus(in: nestedRoot) else { continue }
            let nestedDisplay = displayPath.isEmpty ? path : displayPath + "/" + path
            found.nestedPaths.append(nestedDisplay)
            let nested = snapshot(status, rootPath: nestedRoot, displayPath: nestedDisplay, name: nestedDisplay, isSubmodule: false, isNested: true)
            if status.changes.isEmpty { found.quiet.append(nested) } else { found.repos.append(nested) }
            collectChildRepos(of: status, rootPath: nestedRoot, displayPath: nestedDisplay, depth: depth + 1, into: &found)
        }
    }

    private func collectSubmodulePaths(rootPath: String, displayPath: String, depth: Int, into paths: inout [String]) {
        guard depth <= Self.maxSubmoduleDepth,
              FileManager.default.fileExists(atPath: rootPath + "/.gitmodules"),
              // Exit code 1 = no submodule entries.
              let output = try? git.run(
                  ["config", "--file", ".gitmodules", "-z", "--get-regexp", #"^submodule\..*\.path$"#],
                  in: rootPath, allowedExitCodes: [0, 1])
        else { return }
        // -z output is "key\nvalue\0" per entry.
        for entry in output.split(separator: 0) {
            guard let newline = entry.firstIndex(of: 0x0A) else { continue }
            let path = String(decoding: entry[entry.index(after: newline)...], as: UTF8.self)
            guard !path.isEmpty else { continue }
            let full = displayPath.isEmpty ? path : displayPath + "/" + path
            paths.append(full)
            collectSubmodulePaths(rootPath: rootPath + "/" + path, displayPath: full, depth: depth + 1, into: &paths)
        }
    }
}
