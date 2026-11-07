import SwiftUI

enum ButtonComponent: PluginComponent {
    static let type = "button"
    static let handlesOwnInput = true

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let title = ctx.string("title") ?? ""
        let button = Button(role: ctx.bool("destructive") ? .destructive : nil) {
            ctx.tap()
        } label: {
            if let icon = ctx.string("icon") {
                Label(title, systemImage: icon)
            } else {
                Text(title)
            }
        }
        .buttonHoverPointer()
        .nativeHelp(ctx.string("tooltip") ?? title)
        .controlSize(PluginControlSize.size(ctx.string("size")))
        .pluginShortcut(ctx.string("shortcut"))
        switch ctx.string("style") {
        case "prominent": return AnyView(button.buttonStyle(.borderedProminent))
        case "borderless": return AnyView(button.buttonStyle(.borderless))
        case "plain": return AnyView(button.buttonStyle(.plain))
        case "link": return AnyView(button.buttonStyle(.link))
        default: return AnyView(button.buttonStyle(.bordered))
        }
    }
}

enum PluginControlSize {
    static func size(_ name: String?) -> ControlSize {
        switch name {
        case "mini": .mini
        case "small": .small
        case "large": .large
        default: .regular
        }
    }
}

extension View {
    /// Binds a shortcut written like "cmd+s", "cmd+shift+k" or "return".
    @ViewBuilder
    func pluginShortcut(_ text: String?) -> some View {
        if let text, let shortcut = PluginShortcut.parse(text) {
            keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
        } else {
            self
        }
    }
}

enum PluginShortcut {
    static func parse(_ text: String) -> (key: KeyEquivalent, modifiers: EventModifiers)? {
        var modifiers: EventModifiers = []
        var key: KeyEquivalent?
        for part in text.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command", "⌘": modifiers.insert(.command)
            case "shift", "⇧": modifiers.insert(.shift)
            case "opt", "option", "alt", "⌥": modifiers.insert(.option)
            case "ctrl", "control", "⌃": modifiers.insert(.control)
            case "return", "enter", "↩": key = .return
            case "escape", "esc": key = .escape
            case "tab": key = .tab
            case "space": key = .space
            case "delete", "backspace": key = .delete
            default:
                guard part.count == 1, let character = part.first else { return nil }
                key = KeyEquivalent(character)
            }
        }
        return key.map { ($0, modifiers) }
    }
}
