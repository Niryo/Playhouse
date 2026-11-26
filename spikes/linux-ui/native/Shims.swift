// Minimal stand-ins for app symbols the card's real sources reference but that
// live in large app files (WorkspaceSupport.swift, TokenStatsView.swift). Only
// these shims are spike code; TaskItemView and the atoms compile from the app.
import SwiftUI

enum WorkspaceTheme {
    static let windowBackground = Color(red: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x1E / 255.0)
    static let panelBackground = Color(red: 0x25 / 255.0, green: 0x25 / 255.0, blue: 0x26 / 255.0)
    static let inputBackground = Color(red: 0x3C / 255.0, green: 0x3C / 255.0, blue: 0x3C / 255.0)
    static let conversationText = Color(red: 0xC5 / 255.0, green: 0xC5 / 255.0, blue: 0xC5 / 255.0)
    static let accent = Color(red: 0, green: 122.0 / 255.0, blue: 204.0 / 255.0)
}

extension View {
    func plainButtonHoverPointer() -> some View { self }
    func hoverCursor(_ kind: Any?, overAppKitControl: Bool = false) -> some View { self }
}

// Copied from WorkspaceSupport.swift: the token counter's hover capsule.
extension View {
    func actionButtonHoverEmphasis(padding: CGFloat = 4) -> some View {
        modifier(ActionButtonHoverEmphasis(padding: padding))
    }
}

private struct ActionButtonHoverEmphasis: ViewModifier {
    @State private var isHovering = false
    var padding: CGFloat = 4

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                Capsule()
                    .fill(Color.accentColor.opacity(isHovering ? 0.14 : 0))
            }
            .scaleEffect(isHovering ? 1.06 : 1)
            .animation(.easeOut(duration: 0.14), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

extension View {
    func nativeHelp(_ text: String) -> some View { help(text) }
}

extension View {
    func buttonHoverPointer() -> some View { self }
    func shortcutHelp(_ text: String, shortcut spec: String) -> some View { help(text) }
}

// Copied from WorkspaceSupport.swift (AtomShortcut → SwiftUI shortcut).
extension AtomShortcut {
    /// The SwiftUI shortcut: Return and Escape as the window's default and
    /// cancel actions, or the key with its modifiers.
    var keyboardShortcut: KeyboardShortcut {
        switch role {
        case .default: return .defaultAction
        case .cancel: return .cancelAction
        case nil: break
        }
        let key: KeyEquivalent = switch key {
        case .character(let character): KeyEquivalent(character)
        case .named(.return): .return
        case .named(.escape): .escape
        case .named(.tab): .tab
        case .named(.space): .space
        case .named(.delete): .delete
        }
        var flags: EventModifiers = []
        for modifier in modifiers {
            switch modifier {
            case .ctrl: flags.insert(.control)
            case .option: flags.insert(.option)
            case .shift: flags.insert(.shift)
            case .cmd: flags.insert(.command)
            }
        }
        return KeyboardShortcut(key, modifiers: flags)
    }
}

extension View {
    func hoverRevealScrollers() -> some View { self }
}
