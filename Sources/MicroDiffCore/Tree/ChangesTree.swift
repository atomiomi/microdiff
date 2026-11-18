import Foundation

/// The "changes" tab: one section per repository, each a folder tree of its changed files.
package struct ChangesTree: Sendable {
    private struct FileItem: Sendable {
        var name: String
        var change: FileChange
    }

    private struct Dir: Sendable {
        var name: String
        /// Repo-relative path of this directory.
        var path: String
        var dirs: [Int] = []
        var files: [FileItem] = []
    }

    private struct Section: Sendable {
        var name: String
        var branch: String
        var isSubmodule: Bool
        var rootPath: String
        /// A nested repository without changes: its header is listed (when asked to) and nothing else.
        var isQuiet: Bool
        /// Index 0 is the repo root. Children are referenced by index, so a walk never hashes strings.
        var nodes: [Dir]
    }

    private let sections: [Section]
    /// Section indexes in the order they are listed: the root repository, then the others by `displayPath`.
    private let order: [Int]
    /// Total number of file rows when everything is expanded (= `snapshot.totalChangeCount`).
    package let fileCount: Int

    /// Builds the tree once. One dictionary lookup per path component, then one sort per folder.
    package init(snapshot: WorkspaceSnapshot) {
        fileCount = snapshot.totalChangeCount
        let all = snapshot.allRepos
        let quietStart = snapshot.repos.count
        let sections = all.enumerated().map { position, repo in
            var nodes = [Dir(name: "", path: "")]
            var index: [String: Int] = ["": 0]
            for change in repo.changes {
                let parts = change.path.split(separator: "/", omittingEmptySubsequences: true)
                guard let last = parts.last else { continue }
                var parent = 0
                var path = ""
                for part in parts.dropLast() {
                    path = path.isEmpty ? String(part) : path + "/" + part
                    if let known = index[path] {
                        parent = known
                    } else {
                        let id = nodes.count
                        nodes.append(Dir(name: String(part), path: path))
                        nodes[parent].dirs.append(id)
                        index[path] = id
                        parent = id
                    }
                }
                nodes[parent].files.append(FileItem(name: String(last), change: change))
            }
            let names = nodes.map(\.name)
            for i in nodes.indices {
                nodes[i].dirs.sort { TreeSort.lessThan(names[$0], names[$1]) }
                nodes[i].files.sort { TreeSort.lessThan($0.name, $1.name) }
            }
            return Section(
                name: repo.name, branch: repo.branchLabel, isSubmodule: repo.isSubmodule, rootPath: repo.rootPath,
                isQuiet: position >= quietStart, nodes: nodes)
        }
        self.sections = sections
        let rest = all.indices.dropFirst().sorted { all[$0].displayPath < all[$1].displayPath }
        order = all.isEmpty ? [] : [0] + rest
    }

    /// The visible rows, top to bottom.
    ///
    /// - Each repo in `snapshot.repos` gives one `.repo` row (depth 0, `name` = repo name, `branch` = branchLabel,
    ///   `isSubmodule`, `path` ""), followed by its tree at depth 1+. Every repo row except the first has `gapBefore == true`.
    /// - Directories come before files; both sorted with `TreeSort.lessThan` on their name.
    /// - Compaction: a directory whose only child is a directory is merged with it into one row
    ///   (`name` "ui/widgets", `path` the deepest directory path). Chains merge fully. A directory with any file child is not merged downward.
    /// - File rows: `name` = last path component of `change.path`, `path` = `change.path`, `change` set.
    ///   A renamed file is placed by its NEW path.
    /// - Everything is expanded unless its row id is in `collapsed`. A collapsed repo or directory row is still listed
    ///   (with `isExpanded == false`), its descendants are not.
    /// - Row ids use `TreeRow.makeID`. For compacted directories the id path is the deepest directory path.
    /// - A nested repository without changes (`WorkspaceSnapshot.quietRepos`) gives a `.repo` row alone, with nothing under
    ///   it, only when its `rootPath` is in `listedQuiet`; its `repoIndex` counts on after the repositories with changes.
    ///   Among the others it sits by `displayPath`.
    package func rows(collapsed: Set<String> = [], listedQuiet: Set<String> = []) -> [TreeRow] {
        var rows: [TreeRow] = []
        rows.reserveCapacity(fileCount + sections.count * 4)
        for repoIndex in order {
            let section = sections[repoIndex]
            if section.isQuiet, !listedQuiet.contains(section.rootPath) { continue }
            let id = TreeRow.makeID(repoIndex: repoIndex, kind: .repo, path: "")
            let isExpanded = !collapsed.contains(id)
            rows.append(TreeRow(
                id: id, kind: .repo, depth: 0, name: section.name, path: "", repoIndex: repoIndex,
                isExpanded: isExpanded, branch: section.branch, isSubmodule: section.isSubmodule,
                gapBefore: !rows.isEmpty
            ))
            if isExpanded, !section.isQuiet {
                appendChildren(of: 0, in: section, repoIndex: repoIndex, depth: 1, collapsed: collapsed, into: &rows)
            }
        }
        return rows
    }

    private func appendChildren(
        of node: Int, in section: Section, repoIndex: Int, depth: Int,
        collapsed: Set<String>, into rows: inout [TreeRow]
    ) {
        let nodes = section.nodes
        for child in nodes[node].dirs {
            // Merge single-directory chains into one row.
            var deepest = child
            var name = nodes[child].name
            while nodes[deepest].files.isEmpty, nodes[deepest].dirs.count == 1 {
                deepest = nodes[deepest].dirs[0]
                name += "/" + nodes[deepest].name
            }
            let path = nodes[deepest].path
            let id = TreeRow.makeID(repoIndex: repoIndex, kind: .directory, path: path)
            let isExpanded = !collapsed.contains(id)
            rows.append(TreeRow(
                id: id, kind: .directory, depth: depth, name: name, path: path,
                repoIndex: repoIndex, isExpanded: isExpanded
            ))
            if isExpanded {
                appendChildren(of: deepest, in: section, repoIndex: repoIndex, depth: depth + 1, collapsed: collapsed, into: &rows)
            }
        }
        for file in nodes[node].files {
            rows.append(TreeRow(
                id: TreeRow.makeID(repoIndex: repoIndex, kind: .file, path: file.change.path),
                kind: .file, depth: depth, name: file.name, path: file.change.path,
                repoIndex: repoIndex, change: file.change
            ))
        }
    }
}
