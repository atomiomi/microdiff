import Foundation

package struct DirEntry: Sendable, Hashable {
    package var name: String
    /// True for directories and for symlinks that point at directories are NOT followed: a symlink is never a directory here.
    package var isDirectory: Bool
    package var isSymlink: Bool

    package init(name: String, isDirectory: Bool, isSymlink: Bool = false) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
    }
}

package enum DirectoryLister {
    /// Names never listed.
    package static let hiddenNames: Set<String> = [".git", ".DS_Store"]

    /// Direct children of the directory at `absolutePath`: directories first, then files, each sorted with `TreeSort.lessThan`.
    /// Hidden dot-files are included, except `hiddenNames`. Uses `readdir` (no per-file stat when the file system reports the type).
    /// Returns [] when the directory cannot be read.
    package static func list(_ absolutePath: String) -> [DirEntry] {
        guard let dir = opendir(absolutePath) else { return [] }
        defer { closedir(dir) }

        var dirs: [DirEntry] = []
        var files: [DirEntry] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." || hiddenNames.contains(name) { continue }

            var type = Int32(entry.pointee.d_type)
            if type == Int32(DT_UNKNOWN) {
                var st = stat()
                guard lstat(absolutePath + "/" + name, &st) == 0 else { continue }
                switch st.st_mode & S_IFMT {
                case S_IFDIR: type = Int32(DT_DIR)
                case S_IFLNK: type = Int32(DT_LNK)
                default: type = Int32(DT_REG)
                }
            }
            if type == Int32(DT_DIR) {
                dirs.append(DirEntry(name: name, isDirectory: true))
            } else {
                files.append(DirEntry(name: name, isDirectory: false, isSymlink: type == Int32(DT_LNK)))
            }
        }
        dirs.sort { TreeSort.lessThan($0.name, $1.name) }
        files.sort { TreeSort.lessThan($0.name, $1.name) }
        return dirs + files
    }
}

/// The "files" tab: the folder tree on disk, loaded lazily (a directory is only read when it is expanded).
package struct FileTree: Sendable {
    package let rootPath: String
    package let rootName: String

    /// Expanded directories as workspace-relative paths. "" is the root, expanded by default.
    package private(set) var expanded: Set<String> = [""]

    private var cache: [String: [DirEntry]] = [:]

    package init(rootPath: String, rootName: String) {
        self.rootPath = rootPath
        self.rootName = rootName
    }

    package mutating func setExpanded(_ expanded: Bool, path: String) {
        if expanded {
            self.expanded.insert(path)
        } else {
            self.expanded.remove(path)
        }
    }

    /// Forgets all cached directory listings (call after the file system changed). Keeps `expanded`.
    package mutating func invalidate() {
        cache.removeAll(keepingCapacity: true)
    }

    /// Expands every ancestor directory of `path` so that the file becomes visible.
    package mutating func reveal(path: String) {
        expanded.insert("")
        var prefix = ""
        for part in path.split(separator: "/", omittingEmptySubsequences: true).dropLast() {
            prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
            expanded.insert(prefix)
        }
    }

    /// The visible rows, top to bottom. Reads newly expanded directories from disk and caches the listing.
    ///
    /// - Row 0 is the root: kind `.repo`, depth 0, `name` = rootName, `path` "", `isExpanded` from `expanded`,
    ///   `branch` = `snapshot.repos.first?.branchLabel` (nil when not a git repo), `repoIndex` 0 when it is a git repo else -1.
    /// - Children of the root start at depth 1. `path` is workspace-relative.
    /// - Directory rows: `isNestedRepo` when the path is in `snapshot.nestedRepoPaths` (marked like a submodule when it has changes).
    ///   `isSubmodule` when the path is in `snapshot.submodulePaths`. `dirMark` when any change of any repo
    ///   in the snapshot lies inside that directory (changes of a submodule repo are located at `displayPath + "/" + change.path`):
    ///   the common `ChangeKind` of those changes, or `.modified` when mixed. Deleted files count too, even though they are not on disk.
    ///   An ignored directory never has a `dirMark`.
    /// - `isIgnored`: the path is an ignored entry of its repository (`RepoSnapshot.ignored`, located at `displayPath + "/" + entry`
    ///   with git's trailing slash removed) or lies inside an ignored directory. Submodule repos that are not in the snapshot
    ///   (clean ones) contribute nothing.
    /// - File rows: `change` and `repoIndex` set when the file is a change of some repo (match on the NEW path for renames).
    ///   Files without a change have `change == nil`, `repoIndex == -1`.
    /// - Row ids: `TreeRow.makeID(repoIndex: 0, kind:, path:)` for every row (stable regardless of change state).
    /// - Directories that no longer exist are dropped silently.
    package mutating func rows(snapshot: WorkspaceSnapshot) -> [TreeRow] {
        let lookup = Lookup(snapshot)
        let rootExpanded = expanded.contains("")
        var rows = [TreeRow(
            id: TreeRow.makeID(repoIndex: 0, kind: .repo, path: ""),
            kind: .repo, depth: 0, name: rootName, path: "",
            repoIndex: snapshot.isGitRepo ? 0 : -1,
            isExpanded: rootExpanded,
            branch: snapshot.isGitRepo ? snapshot.repos.first?.branchLabel : nil
        )]
        if rootExpanded {
            appendChildren(of: "", depth: 1, parentIgnored: false, lookup: lookup, into: &rows)
        }
        return rows
    }

    private mutating func listing(_ dirPath: String) -> [DirEntry] {
        if let cached = cache[dirPath] { return cached }
        let absolute = dirPath.isEmpty ? rootPath : rootPath + "/" + dirPath
        let entries = DirectoryLister.list(absolute)
        cache[dirPath] = entries
        return entries
    }

    private mutating func appendChildren(of dirPath: String, depth: Int, parentIgnored: Bool, lookup: Lookup, into rows: inout [TreeRow]) {
        for entry in listing(dirPath) {
            let path = dirPath.isEmpty ? entry.name : dirPath + "/" + entry.name
            let id: String
            let ignored = parentIgnored || lookup.ignored.contains(path)
            if entry.isDirectory {
                id = TreeRow.makeID(repoIndex: 0, kind: .directory, path: path)
                let isExpanded = expanded.contains(path)
                rows.append(TreeRow(
                    id: id, kind: .directory, depth: depth, name: entry.name, path: path, repoIndex: -1,
                    isExpanded: isExpanded,
                    isSubmodule: lookup.submodules.contains(path),
                    dirMark: ignored ? nil : lookup.marks[path],
                    isIgnored: ignored,
                    isNestedRepo: lookup.nestedRepos.contains(path)
                ))
                if isExpanded {
                    appendChildren(of: path, depth: depth + 1, parentIgnored: ignored, lookup: lookup, into: &rows)
                }
            } else {
                let hit = lookup.changes[path]
                rows.append(TreeRow(
                    id: TreeRow.makeID(repoIndex: 0, kind: .file, path: path),
                    kind: .file, depth: depth, name: entry.name, path: path,
                    repoIndex: hit?.repoIndex ?? -1, change: hit?.change,
                    isIgnored: ignored
                ))
            }
        }
    }

    /// Per-call change index: built once, so rows cost O(1) lookups.
    private struct Lookup {
        var changes: [String: (repoIndex: Int, change: FileChange)] = [:]
        var marks: [String: ChangeKind] = [:]
        var submodules: Set<String>
        var nestedRepos: Set<String>
        /// Workspace-relative ignored entries, trailing slash removed.
        var ignored: Set<String> = []

        init(_ snapshot: WorkspaceSnapshot) {
            submodules = Set(snapshot.submodulePaths)
            nestedRepos = Set(snapshot.nestedRepoPaths)
            changes.reserveCapacity(snapshot.totalChangeCount)
            for (repoIndex, repo) in snapshot.repos.enumerated() {
                for entry in repo.ignored {
                    let trimmed = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
                    ignored.insert(repo.displayPath.isEmpty ? trimmed : repo.displayPath + "/" + trimmed)
                }
                for change in repo.changes {
                    let path = repo.displayPath.isEmpty ? change.path : repo.displayPath + "/" + change.path
                    changes[path] = (repoIndex, change)
                    // Merge the kind into every ancestor directory; a different kind makes it .modified.
                    var end = path.endIndex
                    while let slash = path[..<end].lastIndex(of: "/") {
                        let dir = String(path[..<slash])
                        if let known = marks[dir] {
                            if known != change.kind { marks[dir] = .modified }
                        } else {
                            marks[dir] = change.kind
                        }
                        end = slash
                    }
                }
            }
        }
    }
}
