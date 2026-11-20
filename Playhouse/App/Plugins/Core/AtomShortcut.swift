import Foundation

/// A Button's keyboard shortcut, from its `shortcut` prop: "default" (Return,
/// the window's primary action), "cancel" (Escape, its dismissing action), or
/// modifiers and one key joined by "+", such as "cmd+n", "cmd+shift+d" or
/// "ctrl+`". The modifiers are cmd, shift, option and ctrl, and include cmd,
/// ctrl or option, so a shortcut never takes a key from typing; the key is one
/// character, or return, escape, tab, space or delete. A button with a
/// shortcut names it at the end of its hover hint ("Create a new task (⌘N)").
struct AtomShortcut: Equatable, Sendable {
    enum Modifier: String, CaseIterable, Sendable {
        // In the order macOS draws them.
        case ctrl, option, shift, cmd

        var symbol: String {
            switch self {
            case .ctrl: "⌃"
            case .option: "⌥"
            case .shift: "⇧"
            case .cmd: "⌘"
            }
        }
    }

    /// A key that isn't a character it draws as itself.
    enum NamedKey: String, CaseIterable, Sendable {
        case `return`, escape, tab, space, delete

        var title: String {
            switch self {
            case .return: "Return"
            case .escape: "Esc"
            case .tab: "Tab"
            case .space: "Space"
            case .delete: "Delete"
            }
        }
    }

    enum Key: Equatable, Sendable {
        case character(Character)
        case named(NamedKey)
    }

    /// The window's default action (Return) or cancel action (Escape).
    enum Role: String, Sendable { case `default`, cancel }

    var key: Key
    var modifiers: [Modifier]
    var role: Role?

    init(key: Key, modifiers: [Modifier] = [], role: Role? = nil) {
        self.key = key
        self.modifiers = Modifier.allCases.filter(modifiers.contains)
        self.role = role
    }

    /// Nil for a spec that names no key, an unknown modifier, one twice, or
    /// no cmd, ctrl or option.
    init?(_ spec: String) {
        if let role = Role(rawValue: spec) {
            self.init(key: .named(role == .default ? .return : .escape), role: role)
            return
        }
        // "cmd++" ends in an empty part after the "+" key itself.
        var parts = spec.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if spec.hasSuffix("++") { parts.removeLast(2); parts.append("+") }
        guard let last = parts.popLast(), !last.isEmpty else { return nil }
        var modifiers: [Modifier] = []
        for part in parts {
            guard let modifier = Modifier(rawValue: part.lowercased()), !modifiers.contains(modifier) else { return nil }
            modifiers.append(modifier)
        }
        guard modifiers.contains(where: { $0 != .shift }) else { return nil }
        if let named = NamedKey(rawValue: last.lowercased()) {
            self.init(key: .named(named), modifiers: modifiers)
        } else if last.count == 1, let character = last.lowercased().first {
            self.init(key: .character(character), modifiers: modifiers)
        } else {
            return nil
        }
    }

    /// How a menu draws it: "⌘N", "⇧⌘D", "⌃`", "Esc".
    var display: String {
        let key = switch key {
        case .character(let character): String(character).uppercased()
        case .named(let named): named.title
        }
        return modifiers.map(\.symbol).joined() + key
    }

    /// A hover hint that ends by naming the shortcut.
    func help(_ text: String) -> String {
        "\(text) (\(display))"
    }

    /// `help` named with `spec`'s shortcut, or as it is without a valid one.
    static func help(_ text: String?, shortcut spec: String?) -> String? {
        guard let text, let shortcut = spec.flatMap(AtomShortcut.init) else { return text }
        return shortcut.help(text)
    }
}

/// The app's own keyboard shortcuts, one place for every native button that
/// takes one, so no two claim the same keys. Each is an `AtomShortcut` spec.
enum AppShortcut {
    static let newTask = "cmd+n"
    static let chat = "cmd+shift+c"
    static let doneArchive = "cmd+shift+d"
    static let back = "cmd+["
    static let repositoryPicker = "cmd+shift+r"
    static let sidebar = "ctrl+cmd+s"
    static let terminal = "ctrl+`"
    static let skills = "cmd+shift+k"
    static let planMode = "cmd+shift+p"
    static let stopResponse = "cmd+."
    static let save = "cmd+s"

    /// Keys a plugin's Button can't take: the app's own, and the menu bar's
    /// (Search Tasks, Settings, Hide, Minimize, Close and Quit).
    static let reserved: [AtomShortcut] = [
        newTask, chat, doneArchive, back, repositoryPicker, sidebar, terminal, skills, planMode, stopResponse, save,
        "cmd+f", "cmd+,", "cmd+h", "cmd+m", "cmd+w", "cmd+q",
    ].compactMap(AtomShortcut.init)
}
