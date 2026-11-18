import Foundation
import MicroDiffCore

/// The change bars of a buffer in edit mode: the read view's marks, kept up to date while typing.
///
/// The HEAD version is fetched once (and again when asked: a commit, a checkout). After the text changes and typing
/// pauses for a moment, the marks are computed again off the main thread. One computation at a time; a result for
/// older text is thrown away. Until a new result lands, the old marks stay. Lives only while its tab is in edit mode.
final class ChangeMarker {
    /// Row i is line i of the buffer, with its mark. Nil: no marks (no HEAD version, or not computed yet).
    private(set) var rows: DiffDocument?

    static let pause: Duration = .milliseconds(120)

    private weak var buffer: EditBuffer?
    private let git: GitRunner
    private var source: MarkSource?
    private var base: Data?
    /// Bumped by every text change and every new source: a result computed for an older value is dropped.
    private var version = 0
    /// Bumped by every new source: a HEAD version fetched for an older one is dropped.
    private var sourceVersion = 0
    private var fetching = false
    private var running = false
    /// A computation was asked for while one was running.
    private var rerun = false
    private var waiting: Task<Void, Never>?

    /// `rows` can be given when they are already known (the read view's marks for the same text).
    init(buffer: EditBuffer, git: GitRunner, rows: DiffDocument?) {
        self.buffer = buffer
        self.git = git
        self.rows = rows
    }

    /// No computation running or waiting (for tests).
    var isIdle: Bool { !fetching && !running && waiting == nil }
    var isComputing: Bool { running }

    /// Fetches the HEAD version from `source` (nil: the file has none to compare with) and computes the marks.
    func setSource(_ source: MarkSource?, synchronously: Bool = false) {
        self.source = source
        version += 1
        sourceVersion += 1
        // A fetch for the old source may still run: its result will be dropped.
        fetching = false
        waiting?.cancel()
        waiting = nil
        guard let source else { return apply(nil) }
        if synchronously {
            base = ChangeMarks.base(source, git: git)
            if let base, let text = currentText() { apply(ChangeMarks.compute(text: text, base: base, repoRoot: source.repoRoot, git: git)) }
            else { apply(nil) }
            return
        }
        let sourceVersion = sourceVersion
        let git = git
        fetching = true
        Task { [weak self] in
            let base = await Task.detached(priority: .utility) { ChangeMarks.base(source, git: git) }.value
            guard let self, sourceVersion == self.sourceVersion else { return }
            fetching = false
            self.base = base
            if base == nil { apply(nil) } else { compute() }
        }
    }

    /// The text changed: compute again once typing pauses.
    func textDidChange() {
        version += 1
        waiting?.cancel()
        waiting = Task { [weak self] in
            try? await Task.sleep(for: Self.pause)
            guard !Task.isCancelled, let self else { return }
            waiting = nil
            compute()
        }
    }

    /// Stops all work; the marker is about to be dropped.
    func stop() {
        waiting?.cancel()
        waiting = nil
        version += 1
    }

    private func currentText() -> Data? {
        buffer.map { Data(EditFile.bytes($0.storage.string, format: $0.session.format)) }
    }

    private func compute() {
        guard !running else {
            rerun = true
            return
        }
        guard let base, let source, let buffer else { return }
        let version = version
        // The text is copied here; turning it into the file's bytes and everything after happens off the main thread.
        let text = buffer.storage.string
        let format = buffer.session.format
        let git = git
        running = true
        Task { [weak self] in
            let rows = await Task.detached(priority: .utility) {
                ChangeMarks.compute(text: Data(EditFile.bytes(text, format: format)), base: base, repoRoot: source.repoRoot, git: git)
            }.value
            guard let self else { return }
            running = false
            if version == self.version, let rows { apply(rows) }
            startIfAsked()
        }
    }

    private func startIfAsked() {
        guard rerun else { return }
        rerun = false
        compute()
    }

    private func apply(_ rows: DiffDocument?) {
        self.rows = rows
        buffer?.onMarksChanged?()
    }
}
