#if os(macOS)
import AppKit
import PlayhouseCore
import SwiftUI

// Pointer, tooltip and theme shims of PlayhouseUI on macOS, built on AppKit.


/// A cursor shown while the pointer rests over a view. It comes from mechanisms the system
/// re-applies for as long as the pointer stays there: SwiftUI's pointer style, and over a control
/// AppKit draws an AppKit view over it that answers the window's cursor updates. A cursor pushed from `onHover` must
/// not be used for this: AppKit sets the window's cursor again whenever it rebuilds cursor rects
/// (after a layout pass, a tooltip, or a neighboring text view's I-beam rect), silently replacing
/// the pushed one with the arrow.
package enum HoverCursorKind {
    /// The pointing hand over a clickable control.
    case pointingHand
    /// The left-right resize arrows over a draggable column divider.
    case resizeLeftRight
    /// The up-down resize arrows over a draggable row divider.
    case resizeUpDown

    package var cursor: NSCursor {
        switch self {
        case .pointingHand: .pointingHand
        case .resizeLeftRight: .resizeLeftRight
        case .resizeUpDown: .resizeUpDown
        }
    }

    @available(macOS 15.0, *)
    package var pointerStyle: PointerStyle {
        switch self {
        case .pointingHand: .link
        case .resizeLeftRight: .columnResize
        case .resizeUpDown: .rowResize
        }
    }
}

/// A view over the content that sets `cursor` for its frame. SwiftUI's pointer style never reaches
/// a control AppKit draws (a bordered or prominent button, a segmented or pop-up picker, a toggle):
/// the window sends its cursor update to that control, which passes it up to the hosting view, and
/// the hosting view shows the arrow. So this view takes the cursor update itself: it is the hit
/// view only while the window dispatches one, and lets clicks, scrolls and drags through to what is
/// under it. Its cursor rect for its frame is what shows the cursor before macOS 15.
private struct HoverCursorArea: NSViewRepresentable {
    let cursor: NSCursor?

    func makeNSView(context: Context) -> CursorAreaView {
        let view = CursorAreaView()
        view.cursor = cursor
        return view
    }

    func updateNSView(_ view: CursorAreaView, context: Context) {
        guard view.cursor !== cursor else { return }
        view.cursor = cursor
        view.window?.invalidateCursorRects(for: view)
    }

    final class CursorAreaView: NSView {
        package var cursor: NSCursor?
        private var area: NSTrackingArea?

        package override func hitTest(_ point: NSPoint) -> NSView? {
            // `currentEvent` outlives its dispatch, so only a cursor update for this window counts.
            guard cursor != nil, let event = NSApp.currentEvent, event.type == .cursorUpdate, event.window === window else { return nil }
            return super.hitTest(point)
        }

        package override func isAccessibilityElement() -> Bool { false }

        package override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInActiveApp, .inVisibleRect], owner: self)
            addTrackingArea(area)
            self.area = area
        }

        package override func cursorUpdate(with event: NSEvent) {
            if let cursor { cursor.set() } else { super.cursorUpdate(with: event) }
        }

        package override func resetCursorRects() {
            if let cursor { addCursorRect(bounds, cursor: cursor) }
        }
    }
}

extension View {
    /// The pointing hand over a clickable control AppKit draws, or one whose style it inherits: a
    /// bordered or default button, a picker, a toggle, a link, or an AppKit view taking clicks.
    package func buttonHoverPointer() -> some View {
        hoverCursor(.pointingHand, overAppKitControl: true)
    }

    /// The pointing hand over a control SwiftUI draws: a button styled `.plain` in its own modifiers,
    /// or a view made clickable with a tap gesture. SwiftUI's pointer style reaches these, so they
    /// skip the AppKit view, which would otherwise add a view and a tracking area to every row of
    /// the transcript and the board.
    package func plainButtonHoverPointer() -> some View {
        hoverCursor(.pointingHand)
    }

    /// `kind`'s cursor while the pointer is over the view; nil leaves the cursor to what is under it,
    /// keeping the view's identity so a control that turns its cursor on or off keeps its state.
    /// Over a control AppKit draws, SwiftUI's pointer style has no effect, so the AppKit view sets it.
    @ViewBuilder
    package func hoverCursor(_ kind: HoverCursorKind?, overAppKitControl: Bool = false) -> some View {
        if #available(macOS 15.0, *) {
            if overAppKitControl {
                pointerStyle(kind?.pointerStyle)
                    .overlay(HoverCursorArea(cursor: kind?.cursor).accessibilityHidden(true))
            } else {
                pointerStyle(kind?.pointerStyle)
            }
        } else {
            overlay(HoverCursorArea(cursor: kind?.cursor).accessibilityHidden(true))
        }
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

/// A native AppKit tooltip for `text`, carried by a click-through view behind the content.
/// SwiftUI's `.help` alone never presented a tooltip for most of the main window's controls (the
/// board header and the Done panel among them); an `NSView` with its own `toolTip` does.
private struct NativeToolTip: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = ClickThroughView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if nsView.toolTip != text { nsView.toolTip = text }
    }

    private final class ClickThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }
}

extension View {
    /// `.help` that reliably shows a native tooltip on macOS; keeps `.help` for accessibility.
    package func nativeHelp(_ text: String) -> some View {
        // Hidden from accessibility so the extra view cannot become, or resize, the control's element.
        help(text).background(NativeToolTip(text: text).accessibilityHidden(true))
    }

    /// A native button's keyboard shortcut (an `AtomShortcut` spec, usually an
    /// `AppShortcut`), named at the end of its `nativeHelp` hover hint.
    package func shortcutHelp(_ text: String, shortcut spec: String) -> some View {
        let shortcut = AtomShortcut(spec)
        return keyboardShortcut(shortcut?.keyboardShortcut)
            .nativeHelp(shortcut?.help(text) ?? text)
    }
}

extension AtomShortcut {
    /// The SwiftUI shortcut: Return and Escape as the window's default and
    /// cancel actions, or the key with its modifiers.
    package var keyboardShortcut: KeyboardShortcut {
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
    package func actionButtonHoverEmphasis(padding: CGFloat = 4) -> some View {
        modifier(ActionButtonHoverEmphasis(padding: padding))
    }
}


package enum WorkspaceTheme {
    package static let windowBackground = adaptive(dark: (0x1E, 0x1E, 0x1E), light: .windowBackgroundColor)
    package static let panelBackground = adaptive(dark: (0x25, 0x25, 0x26), light: .controlBackgroundColor)
    package static let inputBackground = adaptive(dark: (0x3C, 0x3C, 0x3C), light: .textBackgroundColor)
    package static let conversationText = adaptive(dark: (0xC5, 0xC5, 0xC5), light: .labelColor)
    package static let accent = Color(nsColor: NSColor(srgbRed: 0, green: 122.0 / 255.0, blue: 204.0 / 255.0, alpha: 1))

    private static func adaptive(dark: (UInt8, UInt8, UInt8), light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            guard appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua else { return light }
            return NSColor(
                srgbRed: CGFloat(dark.0) / 255,
                green: CGFloat(dark.1) / 255,
                blue: CGFloat(dark.2) / 255,
                alpha: 1
            )
        })
    }
}
#endif
