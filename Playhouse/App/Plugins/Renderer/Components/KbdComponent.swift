import SwiftUI

enum KbdComponent: PluginComponent {
    static let type = "kbd"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let keys = caps(ctx.string("keys") ?? "")
        return AnyView(
            HStack(spacing: 3) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    Text(key)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .frame(minWidth: 16)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.gray.opacity(0.4)))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ctx.string("keys") ?? "")
        )
    }

    /// "cmd+shift+k" and "⌘⇧K" both become one cap per key.
    static func caps(_ text: String) -> [String] {
        let parts = text.contains("+") ? text.split(separator: "+").map(String.init) : text.map(String.init)
        return parts.map { part in
            switch part.lowercased() {
            case "cmd", "command": "⌘"
            case "shift": "⇧"
            case "opt", "option", "alt": "⌥"
            case "ctrl", "control": "⌃"
            case "return", "enter": "↩"
            case "escape", "esc": "⎋"
            case "tab": "⇥"
            case "delete", "backspace": "⌫"
            case "space": "␣"
            case "up": "↑"
            case "down": "↓"
            case "left": "←"
            case "right": "→"
            default: part.uppercased()
            }
        }
    }
}
