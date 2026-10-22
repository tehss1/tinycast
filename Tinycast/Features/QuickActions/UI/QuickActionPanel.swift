import AppKit
import Carbon.HIToolbox

/// Keys go through `sendEvent`, so ↵, ⌘C and Esc need no focused subview to reach the panel.
final class QuickActionPanel: NSPanel {
    enum Key {
        case replace
        case copy
        case cancel
    }

    var onKey: ((Key) -> Void)?
    var onAccessoryKey: ((NSEvent) -> Bool?)?

    init(content: NSView) {
        super.init(
            contentRect: NSRect(origin: .zero, size: content.frame.size),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Above the palette, below a dialog: a failure report must still land on top of it.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .documentWindow
        isReleasedWhenClosed = false
        isRestorable = false
        contentView = content
    }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown, let onKey else {
            super.sendEvent(event)
            return
        }
        // An input method owns Escape and Return until it commits or cancels its marked text.
        if let editor = firstResponder as? NSTextView, editor.hasMarkedText() {
            super.sendEvent(event)
            return
        }
        if let handled = onAccessoryKey?(event) {
            if !handled { super.sendEvent(event) }
            return
        }
        if Int(event.keyCode) == kVK_Escape {
            onKey(.cancel)
            return
        }
        let isReturn = Int(event.keyCode) == kVK_Return
            || Int(event.keyCode) == kVK_ANSI_KeypadEnter
        if isReturn, event.modifierFlags.contains(.command) {
            onKey(.replace)
            return
        }
        if let editor = firstResponder as? NSTextView, editor.isFieldEditor || editor is RequestEditor {
            super.sendEvent(event)
            return
        }
        // ⌘C before the plain keys: the modifier is what separates Copy from anything else here.
        if event.modifierFlags.contains(.command) {
            guard Int(event.keyCode) == kVK_ANSI_C else {
                super.sendEvent(event)
                return
            }
            onKey(.copy)
            return
        }
        if isReturn { onKey(.replace) } else { super.sendEvent(event) }
    }

    class RequestEditor: NSTextView {
        var pasteboard = NSPasteboard.general
        var onPasteScreenshot: ((NSPasteboard) -> Bool)?
        var onPasteImageFiles: (([URL]) -> Bool)?
        var onFocus: ((Bool) -> Void)?
        var onComposition: ((Bool) -> Void)?
        var wantsFocus = false
        private let editingUndoManager = UndoManager()

        override var undoManager: UndoManager? { editingUndoManager }

        override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
            if item.action == #selector(NSText.paste(_:)), isEditable,
                QuickActionRunner.ScreenshotReader.hasCandidate(on: pasteboard)
            { return true }
            return super.validateUserInterfaceItem(item)
        }

        override func paste(_ sender: Any?) {
            guard isEditable else { return }
            _ = readSelection(from: pasteboard)
        }

        override func readSelection(from board: NSPasteboard) -> Bool {
            guard isEditable else { return false }
            if onPasteScreenshot?(board) == true { return true }
            return super.readSelection(from: board)
        }

        override func readSelection(from board: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
            guard isEditable else { return false }
            if onPasteScreenshot?(board) == true { return true }
            undoManager?.beginUndoGrouping()
            defer { undoManager?.endUndoGrouping() }
            let previous = string
            let pasted = super.readSelection(from: board, type: type)
            if pasted, !hasMarkedText() { removePastedImagePaths(previous: previous) }
            return pasted
        }

        private func removePastedImagePaths(previous: String) {
            let prefix = zip(previous, string).prefix { $0 == $1 }.count
            let oldTail = previous.dropFirst(prefix)
            let newTail = string.dropFirst(prefix)
            let suffix = zip(oldTail.reversed(), newTail.reversed()).prefix { $0 == $1 }.count
            let inserted = String(newTail.dropLast(suffix))
            let references = QuickActionRunner.ScreenshotReader.imageReferences(in: inserted)
            guard !references.urls.isEmpty, onPasteImageFiles?(references.urls) == true else { return }
            let start = string.index(string.startIndex, offsetBy: prefix)
            let end = string.index(string.endIndex, offsetBy: -suffix)
            let range = NSRange(start..<end, in: string)
            insertText(references.text, replacementRange: range)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard window?.firstResponder === self, isEditable else {
                return super.performKeyEquivalent(with: event)
            }
            let key = event.charactersIgnoringModifiers?.lowercased()
            if key == "v", modifiers == .command {
                paste(nil)
                return true
            }
            if key == "z", !hasMarkedText(), modifiers == .command || modifiers == [.command, .shift] {
                guard !event.isARepeat else { return true }
                breakUndoCoalescing()
                if modifiers == .command { editingUndoManager.undo() } else { editingUndoManager.redo() }
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
            onComposition?(hasMarkedText())
        }

        override func unmarkText() {
            super.unmarkText()
            onComposition?(hasMarkedText())
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateFocus()
        }

        func updateFocus() {
            if wantsFocus, isEditable, window?.firstResponder !== self { window?.makeFirstResponder(self) }
        }

        override func becomeFirstResponder() -> Bool {
            guard super.becomeFirstResponder() else { return false }
            onFocus?(true)
            return true
        }

        override func resignFirstResponder() -> Bool {
            guard super.resignFirstResponder() else { return false }
            onFocus?(false)
            return true
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
