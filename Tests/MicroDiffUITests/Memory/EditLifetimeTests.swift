import MicroDiffCore
import MicroDiffTestSupport
import Testing

@testable import MicroDiffUI

/// Edit mode costs nothing until it is used and gives the text back when it is not: a tab's text storage, layout and
/// undo history live while the tab is in edit mode or unsaved, and once its text was changed, until the tab closes. The editor view itself, once made, stays with the window
/// (empty) and goes with it: making text views again and again leaves memory behind in AppKit.
extension UITests {
    @MainActor
    @Suite(.serialized)
    struct EditLifetimeTests {
        private func aliveNames(_ refs: [(String, WeakRef<AnyObject>)]) -> [String] {
            refs.filter { !$0.1.isGone }.map(\.0)
        }

        @Test("tabs never typed in: after the last leaves edit mode no text system is alive and the editor holds no buffer")
        func lastTabLeavesEditMode() async {
            let repo = editRepo()
            let controller = editController(repo.path)
            var refs: [(String, WeakRef<AnyObject>)] = []
            var editor = WeakRef<AnyObject>(nil)
            withPool {
                for file in ["a.txt", "c.txt"] {
                    controller.openForEdit(file)
                    controller.showEdit(nil)
                    if let buffer = controller.workspace.activeBuffer {
                        refs += [
                            ("\(file) buffer", WeakRef<AnyObject>(buffer)), ("\(file) storage", WeakRef<AnyObject>(buffer.storage)),
                            ("\(file) layout", WeakRef<AnyObject>(buffer.layoutManager)),
                            ("\(file) container", WeakRef<AnyObject>(buffer.container)), ("\(file) undo", WeakRef<AnyObject>(buffer.undoManager)),
                        ]
                    }
                }
                OffscreenPainter().paint(controller.rootView)
                editor = WeakRef(controller.editor)
                controller.showRead(nil)
                controller.workspace.selectTab(0)
                controller.showRead(nil)
            }
            #expect(refs.count == 10)
            await waitIdle(controller.workspace)
            #expect(controller.editorIsIdle)
            #expect(controller.textView?.textStorage == nil, "the text view is not attached to any text")
            let gone = await eventually { aliveNames(refs).isEmpty }
            #expect(gone, "still alive: \(aliveNames(refs))")
            #expect(!editor.isGone, "the editor stays with the window")
            withPool { controller.showEdit(nil) }
            #expect(controller.editor === editor.object, "and is used again")
            #expect(controller.editorText == "alpha\nbeta\ngamma\n")
        }

        @Test("a buffer is released when its tab is neither in edit mode nor unsaved, or is closed")
        func buffers() async {
            let repo = editRepo()
            let controller = editController(repo.path, prompts: FakePrompts([.dontSave]))
            var refs: [String: (storage: WeakRef<AnyObject>, layout: WeakRef<AnyObject>, undo: WeakRef<AnyObject>)] = [:]
            withPool {
                for file in ["a.txt", "b.txt", "c.txt"] {
                    controller.openForEdit(file)
                    controller.showEdit(nil)
                    let buffer = controller.workspace.activeBuffer
                    refs[file] = (WeakRef(buffer?.storage), WeakRef(buffer?.layoutManager), WeakRef(buffer?.undoManager))
                }
                // a.txt: unsaved, then out of edit mode. b.txt: clean, out of edit mode. c.txt: stays in edit mode.
                controller.workspace.selectTab(0)
                controller.type("x")
                controller.showRead(nil)
                controller.workspace.selectTab(1)
                controller.showRead(nil)
            }
            func gone(_ file: String) -> Bool {
                guard let ref = refs[file] else { return false }
                return ref.storage.isGone && ref.layout.isGone && ref.undo.isGone
            }
            #expect(await eventually { gone("b.txt") })
            #expect(!gone("a.txt"), "unsaved")
            #expect(!gone("c.txt"), "in edit mode")

            withPool { controller.closeTab(nil) }
            withPool {
                controller.workspace.selectTab(0)
                controller.closeTab(nil)
            }
            #expect(controller.workspace.tabNames == ["c.txt"])
            #expect(await eventually { gone("a.txt") })
            withPool { controller.closeTab(nil) }
            #expect(await eventually { gone("c.txt") })
            #expect(controller.workspace.buffers.isEmpty)
            await waitIdle(controller.workspace)
            #expect(controller.editorIsIdle)
        }

        @Test("an edited tab keeps its buffer after saving and leaving edit mode, until the tab closes")
        func editedBufferStaysUntilTheTabCloses() async {
            let repo = editRepo()
            let controller = editController(repo.path)
            var refs: [(String, WeakRef<AnyObject>)] = []
            withPool {
                controller.openForEdit("a.txt")
                controller.showEdit(nil)
                controller.type("x")
                if let buffer = controller.workspace.activeBuffer {
                    refs = [("storage", WeakRef(buffer.storage)), ("layout", WeakRef(buffer.layoutManager)), ("undo", WeakRef(buffer.undoManager))]
                }
                controller.saveDocument(nil)
                controller.showRead(nil)
            }
            await waitIdle(controller.workspace)
            try? await Task.sleep(for: .milliseconds(50))
            #expect(aliveNames(refs).count == 3, "kept for its undo history")
            #expect(controller.editorIsIdle)
            withPool { controller.closeTab(nil) }
            let gone = await eventually { aliveNames(refs).isEmpty }
            #expect(gone, "still alive: \(aliveNames(refs))")
        }

        @Test("closing a window with tabs in edit mode and unsaved edits frees all of it, the editor too")
        func windowTeardown() async {
            let repo = editRepo()
            var refs: [(String, WeakRef<AnyObject>)] = []
            withPool {
                let controller = editController(repo.path, prompts: FakePrompts([.dontSave]))
                controller.openForEdit("a.txt")
                controller.showEdit(nil)
                controller.type("unsaved")
                controller.openForEdit("c.txt")
                controller.showEdit(nil)
                OffscreenPainter().paint(controller.rootView)
                let buffers = controller.workspace.buffers.values
                refs = [
                    ("controller", WeakRef(controller)), ("window", WeakRef(controller.window)), ("workspace", WeakRef(controller.workspace)),
                    ("editor", WeakRef(controller.editor)), ("textView", WeakRef(controller.textView)),
                ] + buffers.flatMap { buffer in
                    [("storage", WeakRef<AnyObject>(buffer.storage)), ("layout", WeakRef<AnyObject>(buffer.layoutManager)),
                     ("undo", WeakRef<AnyObject>(buffer.undoManager)), ("buffer", WeakRef<AnyObject>(buffer))]
                }
                #expect(!controller.windowShouldClose(controller.window))
            }
            #expect(refs.count == 13)
            let gone = await eventually { aliveNames(refs).isEmpty }
            #expect(gone, "still alive: \(aliveNames(refs))")
        }
    }
}
