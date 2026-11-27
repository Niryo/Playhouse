import AppKit
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseViews
import PlayhouseUI
import SwiftUI

// The plain-text editor behind `PHNativeTextEditor`: an AppKit text view in a scroll view.


/// A plain-text editor for a skill's instructions. SwiftUI's `TextEditor`
/// applies the system's smart dashes and quotes, which would turn Markdown's
/// `---` into an em dash.
package struct SkillTextEditor: NSViewRepresentable {
    @PHBinding package var text: String
    package let identifier: String
    package var isEditable = true

    package func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    package func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .bezelBorder
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = .monospacedSystemFont(ofSize: PHPlatformFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isEditable = isEditable
        textView.string = text
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier(identifier)
        HoverRevealScrollers.install(on: scrollView)
        return scrollView
    }

    package func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        guard textView.string != text else { return }
        textView.string = text
    }

    package final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: PHBinding<String>
        package init(text: PHBinding<String>) { self.text = text }
        package func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }

    package init(text: PHBinding<String>, identifier: String, isEditable: Bool = true) {
        _text = text
        self.identifier = identifier
        self.isEditable = isEditable
    }
}
