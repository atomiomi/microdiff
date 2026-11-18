import AppKit
import MicroDiffCore
import MicroDiffTestSupport

@testable import MicroDiffUI

// Helpers for the edit-mode tests. No `import Testing` here (it cannot be combined with Foundation in one file).

/// Answers the questions in place of a dialog and records what was asked and told.
@MainActor
final class FakePrompts {
    /// Answers handed out in order; once used up, every question is answered with Cancel.
    var answers: [SaveAnswer]
    /// Answers to "move to the Trash?" and to "which name?", handed out in order; once used up: Cancel.
    var trashAnswers: [Bool]
    var names: [String?]
    private(set) var questions: [SaveQuestion] = []
    private(set) var trashQuestions: [TrashQuestion] = []
    private(set) var nameQuestions: [String] = []
    private(set) var messages: [String] = []

    init(_ answers: [SaveAnswer] = [], trash: [Bool] = [], names: [String?] = []) {
        self.answers = answers
        trashAnswers = trash
        self.names = names
    }

    /// Holds on to this object: a test can hand it over without keeping it.
    var prompts: Prompts {
        Prompts(
            ask: { question, _, answer in
                self.questions.append(question)
                answer(self.answers.isEmpty ? .cancel : self.answers.removeFirst())
            },
            confirmTrash: { question, _, answer in
                self.trashQuestions.append(question)
                answer(self.trashAnswers.isEmpty ? false : self.trashAnswers.removeFirst())
            },
            askName: { message, _, answer in
                self.nameQuestions.append(message)
                answer(self.names.isEmpty ? nil : self.names.removeFirst())
            },
            tell: { message, _ in self.messages.append(message) })
    }
}

/// A window controller (never shown) on `path`, scanned, with fake prompts.
@MainActor
func editController(_ path: String, prompts: FakePrompts = FakePrompts()) -> MainWindowController {
    let controller = makeController(path)
    controller.prompts = prompts.prompts
    controller.workspace.scanNow()
    return controller
}

@MainActor
extension MainWindowController {
    var editor: EditorView? { rootView.editor }
    var textView: EditorTextView? { editor?.textView }

    /// Opens a repo-relative (or absolute) file synchronously.
    func openForEdit(_ file: String, mode: ViewMode = .read, pin: Bool = true) {
        let path = file.hasPrefix("/") ? file : workspace.rootPath + "/" + file
        workspace.openFile(path, mode: mode, pin: pin, synchronously: true)
    }

    /// Types at the caret like the keyboard does (through the text view, so undo and the delegate see it).
    func type(_ text: String) {
        textView?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// The Return and Tab keys (what their key bindings call).
    func pressReturn() { textView?.insertNewline(nil) }
    func pressTab() { textView?.insertTab(nil) }

    /// Deletes the character before the caret like the delete key.
    func deleteBackward() {
        textView?.deleteBackward(nil)
    }

    func setCaret(_ location: Int, length: Int = 0) {
        textView?.setSelectedRange(NSRange(location: location, length: length))
    }

    var caret: NSRange? { textView?.selectedRange() }
    var editorText: String? { textView?.string }

    /// The undo menu item: the action goes through the first responder like a key press would.
    func undo() { _ = window.firstResponder?.tryToPerform(Selector(("undo:")), with: nil) }
    func redo() { _ = window.firstResponder?.tryToPerform(Selector(("redo:")), with: nil) }
    var canUndo: Bool { textView?.undoManager?.canUndo ?? false }

    var editorScroll: CGPoint { editor?.scrollView.contentView.bounds.origin ?? .zero }

    var editorSpot: ScrollSpot? { editor?.scrollSpot() }

    func scrollEditor(toLine line: Int, offset: CGFloat = 0) {
        editor?.scroll(to: ScrollSpot(line: line, offset: offset))
    }

    /// No tab needs the editor: it is hidden and holds no buffer (or was never made).
    var editorIsIdle: Bool { editor.map { $0.buffer == nil && $0.isHidden && !rootView.showsEditor } ?? true }

    /// Number of pixels in the main area (right of the sidebar, below the tab bar) that are not the background,
    /// as the window would draw it now.
    func inkInMainArea() -> Int {
        let root = rootView
        root.layoutSubtreeIfNeeded()
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return 0 }
        root.cacheDisplay(in: root.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]), let bitmap = Bitmap.decode(png: data) else { return 0 }
        let scale = bitmap.width / Int(root.bounds.width)
        let area = root.codeView.frame
        let region = PixelRegion(
            x: Int(area.minX) * scale, y: Int(area.minY) * scale, width: Int(area.width) * scale, height: Int(area.height) * scale)
        return bitmap.count(notNear: RGB(Theme.background), in: region, tolerance: 6)
    }

    var marker: ChangeMarker? { workspace.activeBuffer?.marker }

    /// The change mark of each line of the open buffer, as the gutter draws them.
    var editorMarks: [LineMark] {
        guard let rows = marker?.rows else { return [] }
        return (0..<rows.rowCount).map { rows.row(at: $0).mark }
    }

    /// Waits until the change bars are computed for the text as it is now.
    func waitForMarks() async {
        _ = await waitUntil { self.marker?.isIdle ?? true }
    }

    var isEditorFirstResponder: Bool { textView != nil && window.firstResponder === textView }
    var stripShown: Bool { editor.map { $0.conflict != nil && !$0.isHidden } ?? false }
}

/// The text of a file on disk.
func fileText(_ path: String) -> String? {
    try? String(contentsOfFile: path, encoding: .utf8)
}

func exists(_ path: String) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: path)) != nil
}

/// The names in a folder, sorted.
func entries(_ path: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
}

func fileBytes(_ path: String) -> [UInt8]? {
    (try? Data(contentsOf: URL(fileURLWithPath: path))).map { [UInt8]($0) }
}

/// Makes a file read-only (or writable again), and its folder too, so a save into it fails.
func setWritable(_ path: String, _ writable: Bool) {
    let folder = (path as NSString).deletingLastPathComponent
    chmod(folder, writable ? 0o755 : 0o555)
}

/// Lets the main run loop turn once: the undo manager closes the typing group at the end of a turn.
@MainActor
func turnRunLoop() async {
    try? await Task.sleep(for: .milliseconds(5))
}

/// A UTF-16 range in words the test files can build without Foundation.
func range(_ location: Int, _ length: Int) -> NSRange { NSRange(location: location, length: length) }

/// A repository for editing: a few text files committed, one modified, plus files that cannot be edited.
@MainActor
func editRepo() -> TestRepo {
    let repo = TestRepo()
    repo.write("a.txt", "alpha\nbeta\ngamma\n")
    repo.write("b.txt", "one\ntwo\n")
    repo.write("c.txt", "first\nsecond\n")
    repo.write("gone.txt", "will be deleted\n")
    repo.write("bin.dat", Data([0, 1, 2, 3, 0, 5]))
    repo.commitAll("first")
    repo.write("b.txt", "one\ntwo\nthree\n")
    repo.remove("gone.txt")
    repo.write("latin1.txt", Data([0x63, 0x61, 0x66, 0xE9, 0x0A]))
    return repo
}

/// `count` numbered lines ("line 1" ...), each ending in a line break.
func numberedText(_ count: Int) -> String {
    (1...count).map { "line \($0)" }.joined(separator: "\n") + "\n"
}
