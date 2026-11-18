import Foundation

package enum TreeRowKind: UInt8, Sendable, Hashable {
    /// A repository header (root repo or submodule section).
    case repo
    case directory
    case file
}

/// One visible row of the sidebar tree, already flattened for drawing.
package struct TreeRow: Sendable, Hashable, Identifiable {
    /// Stable across refreshes. Format: "<repoIndex>|<r|d|f>|<path>".
    package var id: String
    package var kind: TreeRowKind
    /// 0 for repo rows. Children of a repo start at 1.
    package var depth: Int
    /// Text to show: repo name, directory name (may be a compacted chain like "ui/widgets"), or file name.
    package var name: String
    /// Changes tab: repo-relative path of the directory or file ("" for repo rows).
    /// Files tab: workspace-relative path ("" for the root row).
    package var path: String
    /// Index into `WorkspaceSnapshot.repos` of the repository this row belongs to. -1 when it belongs to none
    /// (files tab rows without a change, or a folder that is not a git repository).
    package var repoIndex: Int
    /// Repo and directory rows: whether children are shown.
    package var isExpanded: Bool
    /// File rows: the change of this file, if it has one.
    package var change: FileChange?
    /// Repo rows: branch label to show on the right.
    package var branch: String?
    /// Repo rows: this section is a submodule. Directory rows (files tab): this folder is a submodule.
    package var isSubmodule: Bool
    /// Directory rows in the files tab: set when something inside changed (drawn as a colored dot, or a letter for submodules).
    /// The kind is the common kind of all changes inside, or `.modified` when they are mixed.
    package var dirMark: ChangeKind?
    /// Draw extra space above this row (between repo sections).
    package var gapBefore: Bool
    /// Files tab: git ignores this file or folder, or it lies inside an ignored folder. Drawn dimmed. Never set in the changes tab.
    package var isIgnored: Bool
    /// Directory rows (files tab): this folder is a nested git repository (not a submodule).
    package var isNestedRepo: Bool

    package init(
        id: String,
        kind: TreeRowKind,
        depth: Int,
        name: String,
        path: String,
        repoIndex: Int,
        isExpanded: Bool = false,
        change: FileChange? = nil,
        branch: String? = nil,
        isSubmodule: Bool = false,
        dirMark: ChangeKind? = nil,
        gapBefore: Bool = false,
        isIgnored: Bool = false,
        isNestedRepo: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.depth = depth
        self.name = name
        self.path = path
        self.repoIndex = repoIndex
        self.isExpanded = isExpanded
        self.change = change
        self.branch = branch
        self.isSubmodule = isSubmodule
        self.dirMark = dirMark
        self.gapBefore = gapBefore
        self.isIgnored = isIgnored
        self.isNestedRepo = isNestedRepo
    }

    package static func makeID(repoIndex: Int, kind: TreeRowKind, path: String) -> String {
        let k = switch kind {
        case .repo: "r"
        case .directory: "d"
        case .file: "f"
        }
        return "\(repoIndex)|\(k)|\(path)"
    }
}

/// Sort order shared by both trees: directories before files, then by name ignoring ASCII case,
/// ties broken by plain byte order so the order is total and stable.
package enum TreeSort {
    package static func lessThan(_ a: String, _ b: String) -> Bool {
        var ai = a.utf8.makeIterator()
        var bi = b.utf8.makeIterator()
        while true {
            let x = ai.next()
            let y = bi.next()
            switch (x, y) {
            case (nil, nil): return a.utf8.lexicographicallyPrecedes(b.utf8)
            case (nil, _): return true
            case (_, nil): return false
            case let (x?, y?):
                let lx = (x >= 65 && x <= 90) ? x + 32 : x
                let ly = (y >= 65 && y <= 90) ? y + 32 : y
                if lx != ly { return lx < ly }
            }
        }
    }
}
