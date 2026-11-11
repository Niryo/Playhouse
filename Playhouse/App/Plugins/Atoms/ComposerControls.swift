import AppKit
import SwiftUI

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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ChatEditorScrollView {
        let scroll = ChatEditorScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
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
        init(_ parent: NativeChatEditor) {
            self.parent = parent
            handledFocusRequest = parent.focusRequest
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? ChatEditorTextView else { return }
            parent.text = editor.string
            (editor.enclosingScrollView as? ChatEditorScrollView)?.requestTextLayout()
        }

        func textDidBeginEditing(_ notification: Notification) { parent.isFocused = true }
        func textDidEndEditing(_ notification: Notification) { parent.isFocused = false }
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

    override func cancelOperation(_ sender: Any?) {
        guard let onCancel else { return super.cancelOperation(sender) }
        onCancel()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)),
           NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil) {
            return isEditable
        }
        return super.validateUserInterfaceItem(item)
    }

    override func keyDown(with event: NSEvent) {
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

struct EffortStepSlider: View {
    @Binding var selection: String
    let choices: [String]

    private let knobDiameter: CGFloat = 20
    private let trackHeight: CGFloat = 6

    private var selectedIndex: Int { choices.firstIndex(of: selection) ?? 0 }
    private var stepCount: Int { max(choices.count - 1, 1) }

    var body: some View {
        GeometryReader { proxy in
            let travel = max(proxy.size.width - knobDiameter, 1)
            let knobX = travel * CGFloat(selectedIndex) / CGFloat(stepCount)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.2))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: knobX + knobDiameter / 2, height: trackHeight)
                ForEach(choices.indices, id: \.self) { index in
                    Circle()
                        .fill(Color.primary.opacity(0.35))
                        .frame(width: 4, height: 4)
                        .offset(x: travel * CGFloat(index) / CGFloat(stepCount) + knobDiameter / 2 - 2)
                }
                Circle()
                    .fill(Color.white)
                    .frame(width: knobDiameter, height: knobDiameter)
                    .offset(x: knobX)
            }
            .frame(width: proxy.size.width, height: knobDiameter, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard !choices.isEmpty else { return }
                let fraction = (value.location.x - knobDiameter / 2) / travel
                let index = min(Int((min(max(fraction, 0), 1) * CGFloat(stepCount)).rounded()), choices.count - 1)
                selection = choices[index]
            })
        }
        .frame(height: knobDiameter)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { moveSelection(by: -1) }
        .onKeyPress(.rightArrow) { moveSelection(by: 1) }
    }

    private func moveSelection(by delta: Int) -> KeyPress.Result {
        guard !choices.isEmpty else { return .ignored }
        selection = choices[min(max(selectedIndex + delta, 0), choices.count - 1)]
        return .handled
    }
}
