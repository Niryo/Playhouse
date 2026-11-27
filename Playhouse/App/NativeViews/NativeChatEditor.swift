import AppKit
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseViews
import PlayhouseUI
import SwiftUI

// The composer's native text view and the effort slider's input, behind `PHNativeChatEditor`
// and `PHNativeEffortSlider` (see NativeViews.swift in PlayhouseAtoms): AppKit draws and edits
// the text, wraps it, and sizes the document.

extension NSAttributedString.Key {
    /// Marks the text of an `@` mention, which is drawn in the accent color.
    static let playhouseMention = NSAttributedString.Key("PlayhouseMention")
}

extension NSAttributedString {
    /// The texts drawn as mentions: each whole accent-colored run that holds a mention, so accent
    /// color spilling onto the words around a mention shows in what is read back.
    var drawnMentions: [String] {
        var mentions: [String] = []
        enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: length)) { value, range, _ in
            guard (value as? NSColor) == NSColor.controlAccentColor else { return }
            var marked = false
            enumerateAttribute(.playhouseMention, in: range) { mention, _, stop in
                if mention != nil { marked = true; stop.pointee = true }
            }
            if marked { mentions.append((string as NSString).substring(with: range)) }
        }
        return mentions
    }

    /// What a text view's accessibility title says about its drawn mentions, nil without any.
    var drawnMentionsTitle: String? {
        let mentions = drawnMentions
        return mentions.isEmpty ? nil : "Mentions " + mentions.joined(separator: ", ")
    }
}

// The native text view owns wrapping and document sizing. SwiftUI only receives
// a bounded viewport height; it never asks a multiline TextField for its ideal size.
struct NativeChatEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var isFocused: Bool
    /// Each new value moves the keyboard into the editor once, with the caret at the end.
    let focusRequest: Int
    let isEnabled: Bool
    let autofocusOnAppear: Bool
    let accessibilityHelp: String
    /// The text view's own accessibility identifier and label.
    var inputTestID: String?
    var inputLabel: String?
    let onSubmit: () -> Void
    let onSteerSubmit: () -> Void
    let onPasteImage: (Data) -> Void
    /// Escape, for a native owner that closes on it; without one the text view keeps its own.
    var onCancel: (() -> Void)? = nil
    /// The selected range, in UTF-16 offsets, whenever it changes.
    var onSelectionChange: (NSRange) -> Void = { _ in }
    var mentions = ChatEditorMentions()

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ChatEditorScrollView {
        let scroll = ChatEditorScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        HoverRevealScrollers.install(on: scroll)
        let editor = ChatEditorTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 28))
        editor.isRichText = false
        // Prompts carry code and commands; send exactly the quotes and dashes the user typed.
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = .textColor
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.minSize = NSSize(width: 0, height: 28)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityIdentifier(inputTestID)
        editor.setAccessibilityLabel(inputLabel)
        editor.delegate = context.coordinator
        scroll.documentView = editor
        scroll.onHeightChange = { [weak coordinator = context.coordinator] height in
            // AppKit layout must finish before updating SwiftUI state.
            DispatchQueue.main.async { [weak scroll] in
                guard let scroll, scroll.viewportHeight == height else { return }
                if coordinator?.parent.height != height { coordinator?.parent.height = height }
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: ChatEditorScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ChatEditorTextView else { return }
        editor.onSubmit = onSubmit
        editor.onSteerSubmit = onSteerSubmit
        editor.onPasteImage = onPasteImage
        editor.onCancel = onCancel
        editor.onMentionKey = mentions.onKey
        editor.isEditable = isEnabled
        editor.isSelectable = isEnabled
        editor.setAccessibilityHelp(accessibilityHelp)
        scroll.shouldFocusEditor = isFocused && isEnabled
        scroll.shouldAutofocusEditor = autofocusOnAppear && isEnabled
        let editorOwnsEditing = isFocused && editor.window?.firstResponder === editor
        if editor.string != text, !editorOwnsEditing {
            editor.string = text
            editor.undoManager?.removeAllActions()
            scroll.requestTextLayout()
            editor.colorMentions(mentions.handles)
        }
        if context.coordinator.coloredHandles != mentions.handles {
            context.coordinator.coloredHandles = mentions.handles
            editor.colorMentions(mentions.handles)
        }
        if let edit = mentions.edit, edit.id != context.coordinator.handledEditID {
            context.coordinator.handledEditID = edit.id
            editor.apply(edit)
        }
        if isFocused, isEnabled, editor.window?.firstResponder !== editor {
            if let window = editor.window {
                window.makeFirstResponder(editor)
            } else {
                DispatchQueue.main.async { [weak editor, weak coordinator = context.coordinator] in
                    guard let editor,
                          let coordinator,
                          coordinator.parent.isFocused,
                          coordinator.parent.isEnabled else { return }
                    editor.window?.makeFirstResponder(editor)
                }
            }
        }
        scroll.focusEditorIfNeeded()
        if focusRequest != context.coordinator.handledFocusRequest, isEnabled {
            context.coordinator.handledFocusRequest = focusRequest
            // After this update, so a view that covered the editor has gone.
            DispatchQueue.main.async { [weak editor] in
                guard let editor, editor.window?.makeFirstResponder(editor) == true else { return }
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeChatEditor
        var handledFocusRequest: Int
        var handledEditID: Int?
        var coloredHandles: Set<String> = []
        init(_ parent: NativeChatEditor) {
            self.parent = parent
            handledFocusRequest = parent.focusRequest
            // An edit made before this editor existed is not replayed into it.
            handledEditID = parent.mentions.edit?.id
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? ChatEditorTextView else { return }
            editor.colorMentions(parent.mentions.handles)
            parent.text = editor.string
            (editor.enclosingScrollView as? ChatEditorScrollView)?.requestTextLayout()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.onSelectionChange(editor.selectedRange())
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
            parent.mentions.onEditingChange(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
            parent.mentions.onEditingChange(false)
        }
    }
}

final class ChatEditorScrollView: NSScrollView {
    var onHeightChange: ((CGFloat) -> Void)?
    var shouldFocusEditor = false
    var shouldAutofocusEditor = false
    private var didAutofocusEditor = false
    private(set) var viewportHeight: CGFloat = 28
    private var previousWidth: CGFloat = 0
    private var textLayoutNeeded = true
    private var layoutRequestGeneration = 0

    func requestTextLayout() {
        textLayoutNeeded = true
        layoutRequestGeneration += 1
        let generation = layoutRequestGeneration
        // Let NSTextView finish its edit/layout pass, then update the viewport
        // before another typing burst can reach the next wrapped line.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.layoutRequestGeneration == generation else { return }
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.focusEditorIfNeeded()
        }
    }

    func focusEditorIfNeeded() {
        guard let window,
              let editor = documentView as? NSTextView,
              shouldFocusEditor || (shouldAutofocusEditor && !didAutofocusEditor) else { return }
        if window.makeFirstResponder(editor), shouldAutofocusEditor {
            didAutofocusEditor = true
        }
    }

    override func layout() {
        super.layout()
        guard let editor = documentView as? NSTextView else { return }
        let width = contentSize.width
        guard width > 0, textLayoutNeeded || width != previousWidth else { return }
        textLayoutNeeded = false
        previousWidth = width
        editor.setFrameSize(NSSize(width: width, height: editor.frame.height))
        let font = editor.font ?? NSFont.systemFont(ofSize: 14)
        let inset = editor.textContainerInset
        let laidOutTextHeight: CGFloat
        if let layoutManager = editor.layoutManager, let textContainer = editor.textContainer {
            // Measure with the same TextKit container that wraps the live editor.
            // A separate boundingRect calculation ignores line-fragment padding,
            // so it can report one fewer line exactly as text crosses a wrap.
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            laidOutTextHeight = max(usedRect.maxY, layoutManager.extraLineFragmentRect.maxY)
        } else {
            laidOutTextHeight = 0
        }
        let lineHeight = editor.layoutManager?.defaultLineHeight(for: font) ?? font.pointSize * 1.2
        let contentHeight = ceil(max(lineHeight, laidOutTextHeight) + inset.height * 2)
        let documentHeight = max(28, contentHeight)
        editor.setFrameSize(NSSize(width: width, height: documentHeight))
        documentHeightDidChange(documentHeight)
    }

    func documentHeightDidChange(_ documentHeight: CGFloat) {
        let editor = documentView as? NSTextView
        let font = editor?.font ?? NSFont.systemFont(ofSize: 14)
        let lineHeight = editor?.layoutManager?.defaultLineHeight(for: font) ?? 17
        let verticalInset = editor?.textContainerInset.height ?? 4
        let maximumHeight = ceil(lineHeight * 12 + verticalInset * 2)
        let newHeight = min(maximumHeight, max(28, ceil(documentHeight)))
        if viewportHeight != newHeight {
            viewportHeight = newHeight
            onHeightChange?(newHeight)
        }
    }
}

final class ChatEditorTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onSteerSubmit: (() -> Void)?
    var onPasteImage: ((Data) -> Void)?
    var onCancel: (() -> Void)?
    var onMentionKey: ((ChatEditorKey) -> Bool)?

    override func cancelOperation(_ sender: Any?) {
        if let onCancel { return onCancel() }
        // The window's Escape button (a page's Close, a panel's Cancel) gets the key before the
        // text view's own completion does: the editor keeps focus under a page that covers it,
        // and would otherwise take Escape from that page's cancel shortcut.
        if let event = NSApp.currentEvent, event.type == .keyDown, window?.performKeyEquivalent(with: event) == true { return }
        super.cancelOperation(sender)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)),
           NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil) {
            return isEditable
        }
        return super.validateUserInterfaceItem(item)
    }

    override func keyDown(with event: NSEvent) {
        if let onMentionKey, !hasMarkedText(), event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty {
            let key: ChatEditorKey? = switch event.keyCode {
            case 126: .up
            case 125: .down
            case 36, 76, 48: .accept
            case 53: .dismiss
            default: nil
            }
            if let key, onMentionKey(key) { return }
        }
        if (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText(), isEditable {
            if event.modifierFlags.contains(.shift) {
                insertNewlineIgnoringFieldEditor(nil)
            } else if event.modifierFlags.contains(.command) {
                onSteerSubmit?()
            } else {
                onSubmit?()
            }
            return
        }
        super.keyDown(with: event)
    }

    /// Colors each `@handle` of `handles` in the accent color and the rest as ordinary text.
    func colorMentions(_ handles: Set<String>) {
        guard let storage = textStorage, !hasMarkedText() else { return }
        let matches = MentionText.handles(in: string, known: handles)
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.playhouseMention, range: whole)
        // Not `textColor`, which reads the first character's color: a draft opening with a mention
        // would turn all of its text the accent color.
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: whole)
        for match in matches {
            storage.addAttributes([.foregroundColor: NSColor.controlAccentColor, .playhouseMention: true], range: match.range)
        }
        storage.endEditing()
        typingAttributes[.foregroundColor] = NSColor.textColor
        typingAttributes[.playhouseMention] = nil
        // Read back from what is drawn, so the title names exactly the mentions shown in color.
        setAccessibilityTitle(storage.drawnMentionsTitle)
    }

    func apply(_ edit: ChatEditorEdit) {
        guard edit.range.location >= 0, NSMaxRange(edit.range) <= (string as NSString).length else { return }
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        guard shouldChangeText(in: edit.range, replacementString: edit.text) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.text)
        didChangeText()
        setSelectedRange(NSRange(location: edit.range.location + (edit.text as NSString).length, length: 0))
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        let pasteboard = NSPasteboard.general
        // Prefer the original image bytes. AppKit's NSImage object reader can
        // reject large clipboard representations before the composer gets a
        // chance to resize them for the 10 MB payload limit.
        if let data = pasteboard.data(forType: .png)
                    ?? pasteboard.data(forType: .tiff) {
            onPasteImage?(data)
        } else if let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage {
            if let data = image.tiffRepresentation {
                onPasteImage?(data)
            } else {
                super.paste(sender)
            }
        } else {
            super.paste(sender)
        }
    }
}

/// A discrete effort slider whose knob is an opaque white disc, so it stays solid over any track or popover background.
/// An undrawn native slider over the drawn effort track, so pointer clicks,
/// drags, and arrow keys behave exactly as a macOS slider's do.
struct EffortAccessibilitySlider: NSViewRepresentable {
    @Binding var selection: String
    let choices: [String]

    final class InputSlider: NSSlider {
        // EffortStepSlider draws the control; this one only takes input.
        override func draw(_ dirtyRect: NSRect) {}
        // Clicking the effort track lets the arrow keys step it, as with the
        // visible slider, regardless of the Full Keyboard Access setting.
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            super.mouseDown(with: event)
        }
    }

    final class Coordinator: NSObject {
        var parent: EffortAccessibilitySlider
        init(_ parent: EffortAccessibilitySlider) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) {
            let index = min(max(Int(sender.doubleValue.rounded()), 0), parent.choices.count - 1)
            parent.selection = parent.choices[index]
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> InputSlider {
        let slider = InputSlider(value: 0, minValue: 0, maxValue: 1, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.allowsTickMarkValuesOnly = true
        slider.focusRingType = .none
        // The SwiftUI representation around it is what accessibility reads.
        slider.setAccessibilityElement(false)
        return slider
    }

    func updateNSView(_ slider: InputSlider, context: Context) {
        context.coordinator.parent = self
        slider.maxValue = Double(choices.count - 1)
        slider.numberOfTickMarks = choices.count
        slider.doubleValue = Double(choices.firstIndex(of: selection) ?? 0)
    }
}

