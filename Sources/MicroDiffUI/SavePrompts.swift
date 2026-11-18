import AppKit

/// What the app asks before unsaved edits would be lost.
enum SaveQuestion: Equatable {
    /// Closing one tab.
    case closeTab(name: String)
    /// Closing the window, quitting, or opening another folder in the window.
    case closeWindow(fileCount: Int)
}

enum SaveAnswer {
    case save, dontSave, cancel
}

/// The dialogs, behind a seam: the app shows alert sheets, tests answer with closures and never see a dialog.
struct Prompts {
    /// Asks a question about unsaved edits; `answer` is called once, later.
    var ask: (_ question: SaveQuestion, _ window: NSWindow, _ answer: @escaping (SaveAnswer) -> Void) -> Void
    /// Tells the user something went wrong (a save failed).
    var tell: (_ message: String, _ window: NSWindow) -> Void

    /// Standard alerts, as sheets on the window.
    static let alerts = Prompts(
        ask: { question, window, answer in
            let alert = NSAlert()
            switch question {
            case let .closeTab(name):
                alert.messageText = "Do you want to save the changes you made to \(name)?"
                alert.addButton(withTitle: "Save")
            case let .closeWindow(count):
                alert.messageText = count == 1
                    ? "Do you want to save the changes you made to 1 file?"
                    : "Do you want to save the changes you made to \(count) files?"
                alert.addButton(withTitle: "Save All")
            }
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Don't Save").keyEquivalent = "d"
            alert.buttons.last?.keyEquivalentModifierMask = .command
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
            alert.beginSheetModal(for: window) { response in
                switch response {
                case .alertFirstButtonReturn: answer(.save)
                case .alertSecondButtonReturn: answer(.dontSave)
                default: answer(.cancel)
                }
            }
        },
        tell: { message, window in
            let alert = NSAlert()
            alert.messageText = message
            alert.beginSheetModal(for: window)
        })
}
