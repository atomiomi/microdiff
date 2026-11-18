import Foundation

/// Clean submodules, read without running `git status` (which walks the whole working tree) and, while nothing moved,
/// without running git at all.
///
/// A scan finds a few small files in the submodule's git folder: `HEAD`, the branch's loose ref, `packed-refs`,
/// `FETCH_HEAD`, `config`, and the remote-tracking ref the branch followed last time (a push moves only that one). Their
/// content, sizes and modification times are the signature. The same signature as last time means the remembered answer
/// is still true. A different one (a commit, a checkout, a pull, a fetch, a push by anyone) costs one
/// `git for-each-ref` for that submodule. A layout that cannot be read this way (a linked work tree, the reftable
/// format, an unexpected `HEAD`) is asked about on every scan, never guessed.
///
/// The memory lives in the `RepoScanner`, which each workspace owns: nothing is shared between workspaces and it goes
/// with the workspace. Entries exist only for the submodules of the last scan (`keepOnly`), at most `limit`. Safe to use from
/// any thread.
package final class QuietSubmodules: @unchecked Sendable {
    private struct FileStamp: Equatable {
        var size: Int64
        var seconds: Int
        var nanoseconds: Int
    }

    private struct Signature: Equatable {
        var head: String
        var stamps: [FileStamp?]
    }

    /// What `git for-each-ref` said about the checked-out branch.
    private struct Answer {
        var branch: String
        var headOID: String
        var upstream: String?
        var isAhead: Bool
        var isBehind: Bool
        /// The full name of the remote-tracking ref (`refs/remotes/origin/main`).
        var trackingRef: String?
    }

    private struct Entry {
        /// The `.git` entry the git folder was worked out from.
        var dotGit: FileStamp
        var gitDir: String?
        /// Nil when the layout cannot be read: the next scan asks again.
        var signature: Signature?
        /// Nil when the branch has no commit yet: nothing to list.
        var answer: Answer?
    }

    /// Most submodules remembered (a workspace with more simply asks about the others on every scan).
    package static let limit = 1024

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    package init() {}

    /// Submodules remembered right now.
    package var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// The submodule in `folder` as a repository without changes. Nil when it is not checked out, on no branch (detached),
    /// or has no commit yet.
    package func read(folder: String, displayPath: String, git: GitRunner) -> RepoSnapshot? {
        guard let dotGit = Self.stamp(folder + "/.git") else {
            forget(folder)
            return nil
        }
        let known = lookup(folder)
        let valid = known.flatMap { $0.dotGit == dotGit ? $0 : nil }
        let gitDir = valid?.gitDir ?? Self.gitFolder(of: folder)

        var branch: String?
        var signature: Signature?
        if let gitDir, Self.isPlain(gitDir), let head = Self.readHead(in: gitDir) {
            if head.hasPrefix("ref: refs/heads/") {
                let name = String(head.dropFirst("ref: refs/heads/".count))
                branch = name
                signature = Self.signature(gitDir: gitDir, dotGit: dotGit, head: head, branch: name, tracking: valid?.answer?.trackingRef)
                if let valid, valid.signature == signature { return valid.answer.map { snapshot($0, folder, displayPath) } }
            } else if RemoteChecker.isCommitID(head) {
                // Detached: no branch, no upstream, nothing to ask.
                forget(folder)
                return nil
            }
        }

        // Moved, or not readable this way: ask.
        guard let name = branch ?? Self.currentBranch(in: folder, git: git), let result = Self.ask(branch: name, folder: folder, git: git) else {
            forget(folder)
            return nil
        }
        var stored = signature
        if let gitDir, let signature, result?.trackingRef != valid?.answer?.trackingRef, let result {
            // The tracking ref is known now: it belongs in the signature.
            stored = Self.signature(gitDir: gitDir, dotGit: dotGit, head: signature.head, branch: name, tracking: result.trackingRef)
        }
        store(folder, Entry(dotGit: dotGit, gitDir: gitDir, signature: stored, answer: result))
        return result.map { snapshot($0, folder, displayPath) }
    }

    /// Forgets every submodule that is not in `folders` (gone from `.gitmodules`, not checked out, or with changes now).
    package func keepOnly(_ folders: Set<String>) {
        lock.lock()
        entries = entries.filter { folders.contains($0.key) }
        lock.unlock()
    }

    // MARK: - Memory

    private func lookup(_ folder: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[folder]
    }

    private func store(_ folder: String, _ entry: Entry?) {
        lock.lock()
        defer { lock.unlock() }
        guard let entry else {
            entries[folder] = nil
            return
        }
        if entries[folder] == nil, entries.count >= Self.limit { entries.removeAll(keepingCapacity: true) }
        entries[folder] = entry
    }

    private func forget(_ folder: String) {
        store(folder, nil)
    }

    private func snapshot(_ answer: Answer, _ folder: String, _ displayPath: String) -> RepoSnapshot {
        RepoSnapshot(
            rootPath: folder, displayPath: displayPath, name: displayPath, isSubmodule: true, branchLabel: answer.branch, hasHead: true,
            changes: [], headOID: answer.headOID, upstream: answer.upstream, isAhead: answer.isAhead, isBehind: answer.isBehind)
    }

    // MARK: - The git folder

    private static func stamp(_ path: String) -> FileStamp? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileStamp(size: Int64(info.st_size), seconds: Int(info.st_mtimespec.tv_sec), nanoseconds: Int(info.st_mtimespec.tv_nsec))
    }

    /// The git folder of a checked-out submodule: its `.git` folder (an old-style clone) or what the `.git` file points to.
    private static func gitFolder(of folder: String) -> String? {
        let dotGit = folder + "/.git"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }
        guard let data = FileManager.default.contents(atPath: dotGit),
              let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first,
              line.hasPrefix("gitdir:")
        else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        return URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: folder, isDirectory: true)).standardizedFileURL.path
    }

    /// An ordinary git folder: not a linked work tree (`commondir`) and not the reftable format.
    private static func isPlain(_ gitDir: String) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: gitDir + "/HEAD") && !manager.fileExists(atPath: gitDir + "/commondir")
            && !manager.fileExists(atPath: gitDir + "/reftable")
    }

    private static func readHead(in gitDir: String) -> String? {
        guard let data = FileManager.default.contents(atPath: gitDir + "/HEAD") else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func signature(gitDir: String, dotGit: FileStamp, head: String, branch: String, tracking: String?) -> Signature {
        var paths = ["refs/heads/" + branch, "packed-refs", "FETCH_HEAD", "config"]
        if let tracking { paths.append(tracking) }
        return Signature(head: head, stamps: [dotGit] + paths.map { stamp(gitDir + "/" + $0) })
    }

    // MARK: - Asking git

    /// The branch HEAD is on, from git itself (for a layout that cannot be read directly). Nil when detached or on failure.
    private static func currentBranch(in folder: String, git: GitRunner) -> String? {
        guard let output = try? git.run(["symbolic-ref", "--short", "-q", "HEAD"], in: folder) else { return nil }
        let name = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// One call that only reads refs. The outer nil is a failed call; the inner nil, a branch without a commit.
    private static func ask(branch: String, folder: String, git: GitRunner) -> Answer?? {
        let format = "--format=%(objectname)%00%(upstream:short)%00%(upstream:track)%00%(upstream)"
        guard let output = try? git.run(["for-each-ref", format, "refs/heads/" + branch], in: folder) else { return nil }
        let line = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .newlines)
        let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 4, !fields[0].isEmpty else { return .some(nil) }
        let track = fields[2]
        return .some(Answer(
            branch: branch, headOID: fields[0], upstream: fields[1].isEmpty ? nil : fields[1],
            isAhead: track.contains("ahead"), isBehind: track.contains("behind"), trackingRef: fields[3].isEmpty ? nil : fields[3]))
    }
}
