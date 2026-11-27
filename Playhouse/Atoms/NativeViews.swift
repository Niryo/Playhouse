import Foundation
import PlayhouseCore
import PlayhouseUI

/// The views each platform builds from its own native controls rather than from atoms: text
/// editing and selectable rich text (AppKit's `NSTextView` on macOS), the terminal (SwiftTerm), the
/// diff view (Monaco in a web view) and a few input controls. Atoms and composites only name the
/// `PHNative…` stand-ins below; each draws through `NativeViews.factory`, which the macOS app
/// installs at launch (`MacNativeViews`). A Linux build installs GTK implementations instead,
/// and nothing that shows these views changes.
@MainActor
package protocol NativeViewFactory {
    func chatEditor(_ editor: PHNativeChatEditor) -> PHAnyView
    func effortSlider(_ slider: PHNativeEffortSlider) -> PHAnyView
    func selectableText(_ text: PHNativeSelectableText) -> PHAnyView
    func codeBlockText(_ text: PHNativeCodeBlockText) -> PHAnyView
    func textEditor(_ editor: PHNativeTextEditor) -> PHAnyView
    /// A task's shells; one session outlives the panel showing it.
    func makeTerminalSession() -> any NativeTerminalSession
    func terminalPanel(_ panel: PHNativeTerminalPanel) -> PHAnyView
    func diffEditor(_ editor: PHNativeDiffEditor) -> PHAnyView
    /// Throws away the shared diff editor so the next one loads it afresh, as after it failed.
    func resetDiffEditor()
    /// The platform's own section at the end of the Settings window (updates, on macOS).
    func settingsSection() -> PHAnyView
}

/// One task's shells: one pane per created repository worktree. The session outlives the panel:
/// hiding the panel keeps the shells and their scrollback, and only closing the task's
/// conversation (or restarting after an exit) ends them.
@MainActor
package protocol NativeTerminalSession: AnyObject {
    /// Starts the shells the first time the panel opens for this task; later calls reuse running
    /// shells, open a pane for a worktree created since, and close one the task no longer has.
    func startIfNeeded(taskID: UUID, workspaceManager: WorkspaceManager)
    func terminate()
}

@MainActor
package enum NativeViews {
    /// The process's native views; until the app installs them, each stand-in draws nothing.
    package static var factory: any NativeViewFactory = UnavailableNativeViews()
}

/// The factory of a process that installed none.
package struct UnavailableNativeViews: NativeViewFactory {
    package init() {}
    package func chatEditor(_ editor: PHNativeChatEditor) -> PHAnyView { PHAnyView(PHEmptyView()) }
    package func effortSlider(_ slider: PHNativeEffortSlider) -> PHAnyView { PHAnyView(PHEmptyView()) }
    package func selectableText(_ text: PHNativeSelectableText) -> PHAnyView { PHAnyView(PHText(text.text)) }
    package func codeBlockText(_ text: PHNativeCodeBlockText) -> PHAnyView { PHAnyView(PHText(text.attributedText.string)) }
    package func textEditor(_ editor: PHNativeTextEditor) -> PHAnyView { PHAnyView(PHText(editor.text)) }
    package func makeTerminalSession() -> any NativeTerminalSession { NoTerminalSession() }
    package func terminalPanel(_ panel: PHNativeTerminalPanel) -> PHAnyView { PHAnyView(PHEmptyView()) }
    package func diffEditor(_ editor: PHNativeDiffEditor) -> PHAnyView { PHAnyView(PHEmptyView()) }
    package func resetDiffEditor() {}
    package func settingsSection() -> PHAnyView { PHAnyView(PHEmptyView()) }
}

private final class NoTerminalSession: NativeTerminalSession {
    func startIfNeeded(taskID: UUID, workspaceManager: WorkspaceManager) {}
    func terminate() {}
}

/// The composer's text editor. The native text view owns wrapping and document sizing; SwiftUI
/// only receives a bounded viewport height and never asks a multiline text field for its ideal size.
package struct PHNativeChatEditor: PHView {
    @PHBinding package var text: String
    @PHBinding package var height: CGFloat
    @PHBinding package var isFocused: Bool
    /// Each new value moves the keyboard into the editor once, with the caret at the end.
    package let focusRequest: Int
    package let isEnabled: Bool
    package let autofocusOnAppear: Bool
    package let accessibilityHelp: String
    /// The text view's own accessibility identifier and label.
    package var inputTestID: String?
    package var inputLabel: String?
    package let onSubmit: () -> Void
    package let onSteerSubmit: () -> Void
    package let onPasteImage: (Data) -> Void
    /// Escape, for a native owner that closes on it; without one the text view keeps its own.
    package var onCancel: (() -> Void)? = nil
    /// The selected range, in UTF-16 offsets, whenever it changes.
    package var onSelectionChange: (NSRange) -> Void = { _ in }
    package var mentions = ChatEditorMentions()

    package init(
        text: PHBinding<String>, height: PHBinding<CGFloat>, isFocused: PHBinding<Bool>, focusRequest: Int,
        isEnabled: Bool, autofocusOnAppear: Bool, accessibilityHelp: String, inputTestID: String? = nil,
        inputLabel: String? = nil, onSubmit: @escaping () -> Void, onSteerSubmit: @escaping () -> Void,
        onPasteImage: @escaping (Data) -> Void, onCancel: (() -> Void)? = nil,
        onSelectionChange: @escaping (NSRange) -> Void = { _ in }, mentions: ChatEditorMentions = ChatEditorMentions()
    ) {
        _text = text
        _height = height
        _isFocused = isFocused
        self.focusRequest = focusRequest
        self.isEnabled = isEnabled
        self.autofocusOnAppear = autofocusOnAppear
        self.accessibilityHelp = accessibilityHelp
        self.inputTestID = inputTestID
        self.inputLabel = inputLabel
        self.onSubmit = onSubmit
        self.onSteerSubmit = onSteerSubmit
        self.onPasteImage = onPasteImage
        self.onCancel = onCancel
        self.onSelectionChange = onSelectionChange
        self.mentions = mentions
    }

    package var body: some PHView { NativeViews.factory.chatEditor(self) }
}

/// An undrawn native slider over the drawn effort track, so pointer clicks, drags, and arrow keys
/// behave exactly as the platform's slider does.
package struct PHNativeEffortSlider: PHView {
    @PHBinding package var selection: String
    package let choices: [String]

    package init(selection: PHBinding<String>, choices: [String]) {
        _selection = selection
        self.choices = choices
    }

    package var body: some PHView { NativeViews.factory.effortSlider(self) }
}

/// Selectable rich text: transcript prose and the Markdown atom's text. The native text view
/// lays out and draws all of it, reports selections for comments and side chats, and draws
/// their highlights.
package struct PHNativeSelectableText: PHView {
    package let text: String
    /// Commented ranges of `text`, rendered orange.
    package let highlightedRanges: [NSRange]
    /// `@` mentions in `text`, rendered in the accent color.
    package var mentionRanges: [NSRange] = []
    /// Ranges of `text` a side chat discusses, rendered purple unless a comment covers them too.
    package var chatRanges: [NSRange] = []
    /// A click inside a commented or side-chatted range, selecting nothing, reports that range
    /// (a commented one first) and where it is in the text.
    package var onHighlightClick: ((NSRange, CGRect) -> Void)? = nil
    package var responseAnnotations: [ResponseAnnotationReference] = []
    package var responseCommentSourcePrefix = ""
    package var isAssistantText = false
    package var textColor: PHPlatformColor = .labelColor
    package let onSelection: (NSRange, String, CGRect) -> Void
    package var formattedText: NSAttributedString? = nil
    package var font: PHPlatformFont = .systemFont(ofSize: 16)
    package var wholeMessageText: String? = nil
    package var accessibilityBlocks: [SelectableTextAccessibilityBlock] = []
    /// False keeps the text from being selected; its links still open.
    package var allowsSelection = true
    /// Opens only web and mail links, as plugin text may; any other link does nothing.
    package var restrictsLinks = false
    /// Reports `accessibilityBlocks` as static texts, read by their labels, instead of groups
    /// that only locate their part of the text.
    package var blocksAreText = false
    /// Set on the text view itself, which a SwiftUI identifier around it may not reach.
    package var accessibilityIdentifier: String? = nil

    package var body: some PHView { NativeViews.factory.selectableText(self) }

    package init(text: String, highlightedRanges: [NSRange], mentionRanges: [NSRange] = [], chatRanges: [NSRange] = [], onHighlightClick: ((NSRange, CGRect) -> Void)? = nil, responseAnnotations: [ResponseAnnotationReference] = [], responseCommentSourcePrefix: String = "", isAssistantText: Bool = false, textColor: PHPlatformColor = .labelColor, onSelection: @escaping (NSRange, String, CGRect) -> Void, formattedText: NSAttributedString? = nil, font: PHPlatformFont = .systemFont(ofSize: 16), wholeMessageText: String? = nil, accessibilityBlocks: [SelectableTextAccessibilityBlock] = [], allowsSelection: Bool = true, restrictsLinks: Bool = false, blocksAreText: Bool = false, accessibilityIdentifier: String? = nil) {
        self.text = text
        self.highlightedRanges = highlightedRanges
        self.mentionRanges = mentionRanges
        self.chatRanges = chatRanges
        self.onHighlightClick = onHighlightClick
        self.responseAnnotations = responseAnnotations
        self.responseCommentSourcePrefix = responseCommentSourcePrefix
        self.isAssistantText = isAssistantText
        self.textColor = textColor
        self.onSelection = onSelection
        self.formattedText = formattedText
        self.font = font
        self.wholeMessageText = wholeMessageText
        self.accessibilityBlocks = accessibilityBlocks
        self.allowsSelection = allowsSelection
        self.restrictsLinks = restrictsLinks
        self.blocksAreText = blocksAreText
        self.accessibilityIdentifier = accessibilityIdentifier
    }
}

/// One part of a selectable text (a paragraph, a list item) as its own accessibility element.
package struct SelectableTextAccessibilityBlock: Equatable {
    package let identifier: String
    package let label: String
    package let range: NSRange

    package init(identifier: String, label: String, range: NSRange) {
        self.identifier = identifier
        self.label = label
        self.range = range
    }
}

/// A code block's text: selectable, laid out at its full height, never editable.
package struct PHNativeCodeBlockText: PHView {
    package let attributedText: NSAttributedString

    package var body: some PHView { NativeViews.factory.codeBlockText(self) }

    package init(attributedText: NSAttributedString) {
        self.attributedText = attributedText
    }
}

/// A plain-text editor for Markdown and configuration text, with the platform's editing.
package struct PHNativeTextEditor: PHView {
    @PHBinding package var text: String
    package let identifier: String
    package var isEditable = true

    package var body: some PHView { NativeViews.factory.textEditor(self) }

    package init(text: PHBinding<String>, identifier: String, isEditable: Bool = true) {
        _text = text
        self.identifier = identifier
        self.isEditable = isEditable
    }
}

/// The terminal panel of a task: a header with restart and close, and a pane per shell.
package struct PHNativeTerminalPanel: PHView {
    package let session: any NativeTerminalSession
    /// Restarting a shell starts it in the task's worktree again.
    package let workspaceManager: WorkspaceManager
    package let onClose: () -> Void

    package var body: some PHView { NativeViews.factory.terminalPanel(self) }

    package init(session: any NativeTerminalSession, workspaceManager: WorkspaceManager, onClose: @escaping () -> Void) {
        self.session = session
        self.workspaceManager = workspaceManager
        self.onClose = onClose
    }
}

/// A file's changes side by side, in the platform's diff editor (Monaco, on macOS).
package struct PHNativeDiffEditor: PHView {
    package let diff: WorkspaceFileDiff
    /// The editor's color theme: "vs-dark" or "vs".
    package let theme: String
    @PHBinding package var isReady: Bool
    @PHBinding package var loadError: String?
    @PHBinding package var diffChangeCount: Int?
    @PHBinding package var presentation: DiffEditorPresentation?

    package var body: some PHView { NativeViews.factory.diffEditor(self) }

    package init(diff: WorkspaceFileDiff, theme: String, isReady: PHBinding<Bool>, loadError: PHBinding<String?>, diffChangeCount: PHBinding<Int?>, presentation: PHBinding<DiffEditorPresentation?>) {
        self.diff = diff
        self.theme = theme
        _isReady = isReady
        _loadError = loadError
        _diffChangeCount = diffChangeCount
        _presentation = presentation
    }
}
