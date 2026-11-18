import CoreServices
import Foundation

/// Decides which file-system events should trigger a refresh.
package enum FSEventFilter {
    /// `path` is an absolute path reported by FSEvents.
    ///
    /// Relevant: everything outside a `.git` directory.
    /// Inside a `.git` directory (any path with a "/.git/" component, including `.git/modules/...`) only these are relevant,
    /// because they mean the commit, branch or staged state changed: a last component equal to `HEAD`, `index` or `ORIG_HEAD`,
    /// and anything under a `refs/` directory (reflogs under `logs/` are excluded: they only echo those changes). Everything else in `.git` (objects, logs, `index.lock`, `FETCH_HEAD`, ...) is noise.
    /// A path that IS a `.git` directory itself (ends with "/.git") is not relevant.
    package static func isRelevant(path: String) -> Bool {
        var path = Substring(path)
        if path.hasSuffix("/") { path = path.dropLast() }
        // A `.git` file or folder itself (also a submodule's `.git` pointer file) carries no state change.
        if path.hasSuffix("/.git") || path == ".git" { return false }
        guard let marker = path.range(of: "/.git/") else {
            return !path.hasPrefix(".git/") || isGitState(path.dropFirst(5))
        }
        return isGitState(path[marker.upperBound...])
    }

    /// `inside` is the part of a path after the `.git/` component.
    private static func isGitState(_ inside: Substring) -> Bool {
        let parts = inside.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = parts.last else { return false }
        if parts.dropLast().contains("logs") { return false }
        if last == "HEAD" || last == "index" || last == "ORIG_HEAD" { return true }
        return parts.dropLast().contains("refs")
    }
}

/// Watches a folder tree with FSEvents and calls back, coalesced, when something relevant changed.
package final class FSWatcher: @unchecked Sendable {
    /// What the stream's C callback talks to. The stream retains it (see `start`), so a late callback can never
    /// touch freed memory, and it holds no reference back to the watcher, so there is no cycle.
    private final class Box: @unchecked Sendable {
        let onChange: @Sendable () -> Void
        private let lock = NSLock()
        private var active = false

        init(onChange: @escaping @Sendable () -> Void) {
            self.onChange = onChange
        }

        var isActive: Bool {
            get { lock.withLock { active } }
            set { lock.withLock { active = newValue } }
        }

        /// Called on the stream's queue with the batch's paths.
        func deliver(_ paths: UnsafeBufferPointer<UnsafePointer<CChar>>) {
            guard paths.contains(where: { FSEventFilter.isRelevant(path: String(cString: $0)) }) else { return }
            DispatchQueue.main.async { [self] in
                // A hop queued before `stop()` must not fire after it.
                if isActive { onChange() }
            }
        }
    }

    private let path: String
    private let latency: TimeInterval
    private let box: Box
    private let queue = DispatchQueue(label: "microdiff.fswatcher")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    /// - Parameters:
    ///   - path: absolute folder to watch recursively.
    ///   - latency: FSEvents coalescing window in seconds.
    ///   - onChange: called on the main queue, at most once per batch of events, only when at least one event passes `FSEventFilter`.
    package init(path: String, latency: TimeInterval = 0.15, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.latency = latency
        box = Box(onChange: onChange)
    }

    deinit {
        stop()
    }

    /// Starts watching. Calling it twice is harmless.
    package func start() {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Box>.fromOpaque(info).retain()
                return UnsafeRawPointer(info)
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Box>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            // Without kFSEventStreamCreateFlagUseCFTypes the paths arrive as a plain C array: no bridging cost.
            let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            box.deliver(UnsafeBufferPointer(start: paths, count: count))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(
            nil, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else { return }

        box.isActive = true
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            box.isActive = false
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
    }

    /// Stops watching. Safe to call when not started. Also called from `deinit`.
    package func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let current = stream else { return }
        stream = nil
        box.isActive = false
        FSEventStreamStop(current)
        FSEventStreamInvalidate(current)
        FSEventStreamRelease(current)
    }
}
