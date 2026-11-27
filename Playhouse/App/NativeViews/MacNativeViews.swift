import PlayhouseAtoms
import PlayhouseCore
import PlayhouseViews
import PlayhouseUI
import SwiftUI

/// The native views on macOS: AppKit text views, SwiftTerm's terminal, Monaco in a web view,
/// and the updater's Settings section. Installed as `NativeViews.factory` at launch.
@MainActor
struct MacNativeViews: NativeViewFactory {
    func chatEditor(_ editor: PHNativeChatEditor) -> AnyView {
        AnyView(NativeChatEditor(
            text: editor.$text, height: editor.$height, isFocused: editor.$isFocused, focusRequest: editor.focusRequest,
            isEnabled: editor.isEnabled, autofocusOnAppear: editor.autofocusOnAppear, accessibilityHelp: editor.accessibilityHelp,
            inputTestID: editor.inputTestID, inputLabel: editor.inputLabel, onSubmit: editor.onSubmit,
            onSteerSubmit: editor.onSteerSubmit, onPasteImage: editor.onPasteImage, onCancel: editor.onCancel,
            onSelectionChange: editor.onSelectionChange, mentions: editor.mentions
        ))
    }

    func effortSlider(_ slider: PHNativeEffortSlider) -> AnyView {
        AnyView(EffortAccessibilitySlider(selection: slider.$selection, choices: slider.choices))
    }

    func selectableText(_ text: PHNativeSelectableText) -> AnyView {
        AnyView(SelectableAnnotationText(
            text: text.text, highlightedRanges: text.highlightedRanges, mentionRanges: text.mentionRanges,
            chatRanges: text.chatRanges, onHighlightClick: text.onHighlightClick, responseAnnotations: text.responseAnnotations,
            responseCommentSourcePrefix: text.responseCommentSourcePrefix, isAssistantText: text.isAssistantText,
            textColor: text.textColor, onSelection: text.onSelection, formattedText: text.formattedText, font: text.font,
            wholeMessageText: text.wholeMessageText, accessibilityBlocks: text.accessibilityBlocks,
            allowsSelection: text.allowsSelection, restrictsLinks: text.restrictsLinks, blocksAreText: text.blocksAreText,
            accessibilityIdentifier: text.accessibilityIdentifier
        ))
    }

    func codeBlockText(_ text: PHNativeCodeBlockText) -> AnyView {
        AnyView(CodeBlockTextView(attributedText: text.attributedText))
    }

    func textEditor(_ editor: PHNativeTextEditor) -> AnyView {
        AnyView(SkillTextEditor(text: editor.$text, identifier: editor.identifier, isEditable: editor.isEditable))
    }

    func makeTerminalSession() -> any NativeTerminalSession {
        TaskTerminalSession()
    }

    func terminalPanel(_ panel: PHNativeTerminalPanel) -> AnyView {
        guard let session = panel.session as? TaskTerminalSession else { return AnyView(EmptyView()) }
        let workspaceManager = panel.workspaceManager
        return AnyView(TaskTerminalPanel(
            session: session,
            onRestart: { session.restart(workspaceManager: workspaceManager) },
            onRestartPane: { session.restart($0, workspaceManager: workspaceManager) },
            onClose: panel.onClose
        ))
    }

    func diffEditor(_ editor: PHNativeDiffEditor) -> AnyView {
        AnyView(MonacoDiffEditor(
            diff: editor.diff, theme: editor.theme, isReady: editor.$isReady, loadError: editor.$loadError,
            diffChangeCount: editor.$diffChangeCount, presentation: editor.$presentation
        ))
    }

    func resetDiffEditor() {
        MonacoDiffWebViewHost.shared.reset()
    }

    func settingsSection() -> AnyView {
        AnyView(UpdateSettingsSection())
    }
}

extension TaskTerminalSession: NativeTerminalSession {}
