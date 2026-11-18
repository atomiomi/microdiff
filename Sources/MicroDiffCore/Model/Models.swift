import Foundation

/// How a file differs from the last commit (HEAD). Staged and unstaged changes are merged.
package enum ChangeKind: UInt8, Sendable, Hashable, CaseIterable {
    case modified
    case added
    case deleted
    case renamed
    case conflicted

    /// The single status letter shown in the UI.
    package var letter: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .conflicted: "U"
        }
    }
}

/// One changed file inside one repository.
package struct FileChange: Sendable, Hashable {
    /// Repo-relative path, "/"-separated, no leading slash.
    package var path: String
    /// Previous repo-relative path. Only set for renames.
    package var oldPath: String?
    package var kind: ChangeKind
    /// True for files git does not track yet. They are shown as `added`.
    package var isUntracked: Bool

    package init(path: String, oldPath: String? = nil, kind: ChangeKind, isUntracked: Bool = false) {
        self.path = path
        self.oldPath = oldPath
        self.kind = kind
        self.isUntracked = isUntracked
    }
}

/// A submodule entry as reported by `git status` of its parent repository.
package struct SubmoduleState: Sendable, Hashable {
    /// Path relative to the parent repository.
    package var path: String
    /// The submodule is checked out at a different commit than the parent records.
    package var commitChanged: Bool
    /// The submodule has changes to tracked files inside.
    package var hasModifiedContent: Bool
    /// The submodule has untracked files inside.
    package var hasUntrackedContent: Bool

    package init(path: String, commitChanged: Bool, hasModifiedContent: Bool, hasUntrackedContent: Bool) {
        self.path = path
        self.commitChanged = commitChanged
        self.hasModifiedContent = hasModifiedContent
        self.hasUntrackedContent = hasUntrackedContent
    }
}

/// Parsed result of one `git status --porcelain=v2 --branch -z` call.
package struct RepoStatus: Sendable, Hashable {
    /// Current branch name. Nil when HEAD is detached.
    package var branch: String?
    /// Full object id of HEAD. Nil when the repository has no commits yet.
    package var headOID: String?
    /// Changed files, in the order git reported them. Submodule entries are NOT included here.
    package var changes: [FileChange]
    /// Submodule entries that git reported as changed in any way.
    package var submodules: [SubmoduleState]
    /// Ignored entries (`--ignored=matching`), repo-relative, in git's order. An ignored directory is ONE entry
    /// and keeps git's trailing slash ("node_modules/"); ignored files have none.
    package var ignored: [String]
    /// Untracked entries that end in `/` (git does not look inside): folders that may be nested git repositories,
    /// repo-relative, trailing slash kept. Whether they really are repositories is for the scanner to check.
    package var nestedRepoCandidates: [String]

    package init(branch: String? = nil, headOID: String? = nil, changes: [FileChange] = [], submodules: [SubmoduleState] = [], ignored: [String] = [], nestedRepoCandidates: [String] = []) {
        self.branch = branch
        self.headOID = headOID
        self.changes = changes
        self.submodules = submodules
        self.ignored = ignored
        self.nestedRepoCandidates = nestedRepoCandidates
    }
}

/// One repository section of the workspace: the root repo, or a submodule with changes inside.
package struct RepoSnapshot: Sendable, Hashable {
    /// Absolute path of this repository's working tree.
    package var rootPath: String
    /// Path relative to the workspace root. "" for the root repository, e.g. "vendor/libgit" for a submodule.
    package var displayPath: String
    /// Header label: the folder name for the root repository, `displayPath` for submodules.
    package var name: String
    package var isSubmodule: Bool
    /// Branch name; the 7-character commit id when HEAD is detached; "no commits" when there is no HEAD.
    package var branchLabel: String
    /// False when the repository has no commits yet.
    package var hasHead: Bool
    package var changes: [FileChange]
    /// Ignored entries relative to this repository (see `RepoStatus.ignored`: directories keep a trailing slash).
    package var ignored: [String]
    /// A separate git repository inside the workspace that the parent does not know (not a submodule). Shown as its
    /// own section like a submodule, but with the repository icon.
    package var isNested: Bool

    package init(rootPath: String, displayPath: String, name: String, isSubmodule: Bool, branchLabel: String, hasHead: Bool, changes: [FileChange], ignored: [String] = [], isNested: Bool = false) {
        self.rootPath = rootPath
        self.displayPath = displayPath
        self.name = name
        self.isSubmodule = isSubmodule
        self.branchLabel = branchLabel
        self.hasHead = hasHead
        self.changes = changes
        self.ignored = ignored
        self.isNested = isNested
    }
}

/// Everything the UI needs to know about the opened folder's git state.
package struct WorkspaceSnapshot: Sendable, Hashable {
    /// Absolute path of the workspace root (the git top level when inside a repository).
    package var rootPath: String
    package var isGitRepo: Bool
    /// The root repository first (always present when `isGitRepo`, even with no changes),
    /// then every submodule or nested repository that has changes inside, sorted by `displayPath`.
    package var repos: [RepoSnapshot]
    /// All known submodule paths relative to the workspace root, sorted. Used to mark submodule folders in the files tab.
    package var submodulePaths: [String]
    /// Workspace-relative paths of nested git repositories (untracked folders that hold their own `.git`, found only
    /// through what git reports), sorted. Includes clean ones. Used to mark their folders in the files tab.
    package var nestedRepoPaths: [String]

    package init(rootPath: String, isGitRepo: Bool, repos: [RepoSnapshot] = [], submodulePaths: [String] = [], nestedRepoPaths: [String] = []) {
        self.rootPath = rootPath
        self.isGitRepo = isGitRepo
        self.repos = repos
        self.submodulePaths = submodulePaths
        self.nestedRepoPaths = nestedRepoPaths
    }

    package var totalChangeCount: Int {
        repos.reduce(0) { $0 + $1.changes.count }
    }
}

/// Row heights used to lay out the diff and file views.
package struct RowMetrics: Sendable, Hashable {
    package var lineHeight: Double
    package var foldHeight: Double

    package init(lineHeight: Double = 20, foldHeight: Double = 26) {
        self.lineHeight = lineHeight
        self.foldHeight = foldHeight
    }
}
