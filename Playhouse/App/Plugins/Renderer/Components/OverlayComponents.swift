import SwiftUI

enum MenuComponent: PluginComponent {
    static let type = "menu"
    static let handlesOwnInput = true

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let title = ctx.string("title")
        let icon = ctx.string("icon")
        let help = ctx.string("tooltip") ?? title ?? "Menu"
        return AnyView(
            Menu {
                ctx.view(of: ctx.menuChildren)
            } label: {
                if let title, let icon {
                    Label(title, systemImage: icon)
                } else if let icon {
                    Image(systemName: icon)
                } else {
                    Text(title ?? "Menu")
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(ctx.bool("indicator") ? .visible : .hidden)
            .fixedSize()
            .buttonHoverPointer()
            .nativeHelp(help)
            .accessibilityLabel(help)
        )
    }
}

enum MenuItemComponent: PluginComponent {
    static let type = "menu-item"
    static let handlesOwnInput = true

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let title = ctx.string("title") ?? ""
        let symbol = ctx.bool("checked") ? "checkmark" : ctx.string("icon")
        return AnyView(
            Button(role: ctx.bool("destructive") ? .destructive : nil) {
                ctx.tap()
            } label: {
                if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
            }
            .buttonHoverPointer()
            .nativeHelp(ctx.string("tooltip") ?? title)
        )
    }
}

enum ContextMenuComponent: PluginComponent {
    static let type = "context-menu"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 8) { ctx.view(of: ctx.contentChildren) }
                .contextMenu { ctx.view(of: ctx.menuChildren) }
        )
    }
}

/// What a presentation component's `open` prop and dismissal look like to SwiftUI: the
/// plugin's state is the source of truth, and closing asks the plugin to set it.
private func presented(_ ctx: PluginRenderContext, dismiss: String = "onDismiss") -> Binding<Bool> {
    Binding(
        get: { ctx.bool("open") },
        set: { isPresented in
            if !isPresented, ctx.bool("open"), ctx.has(dismiss) { ctx.fire(dismiss) }
        }
    )
}

/// Sheets, alerts and dialogs draw nothing in place; they hang off an empty anchor.
private struct EmptyAnchor: View {
    var body: some View { Color.clear.frame(width: 0, height: 0).accessibilityHidden(true) }
}

enum PopoverComponent: PluginComponent {
    static let type = "popover"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let edge: Edge = switch ctx.string("edge") {
        case "top": .top
        case "leading": .leading
        case "trailing": .trailing
        default: .bottom
        }
        let anchor = Array(ctx.node.children.prefix(1))
        let content = Array(ctx.node.children.dropFirst())
        return AnyView(
            ctx.view(of: anchor)
                .popover(isPresented: presented(ctx), arrowEdge: edge) {
                    VStack(alignment: .leading, spacing: 8) { ctx.view(of: content) }
                        .padding(12)
                        .frame(minWidth: 180, alignment: .leading)
                }
        )
    }
}

enum SheetComponent: PluginComponent {
    static let type = "sheet"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        AnyView(
            EmptyAnchor().sheet(isPresented: presented(ctx)) {
                VStack(alignment: .leading, spacing: 10) { ctx.children }
                    .padding(20)
                    .frame(width: ctx.cgFloat("contentWidth") ?? 360, alignment: .leading)
            }
        )
    }
}

enum AlertComponent: PluginComponent {
    static let type = "alert"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        AnyView(
            EmptyAnchor().alert(ctx.string("title") ?? "", isPresented: presented(ctx)) {
                // The dismissal reaches the plugin through the binding, whichever way the alert closes.
                Button(ctx.string("buttonTitle") ?? "OK") {}
                    .buttonHoverPointer()
                    .nativeHelp("Dismiss")
            } message: {
                if let message = ctx.string("message") { Text(message) }
            }
        )
    }
}

enum ConfirmDialogComponent: PluginComponent {
    static let type = "confirm-dialog"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        AnyView(PluginConfirmDialog(ctx: ctx))
    }
}

private struct PluginConfirmDialog: View {
    let ctx: PluginRenderContext
    /// Set by the confirm button so the dialog closing behind it doesn't also report a cancel.
    @State private var confirmed = false

    private var isPresented: Binding<Bool> {
        Binding(
            get: { ctx.bool("open") },
            set: { open in
                guard !open, ctx.bool("open") else { return }
                if confirmed { confirmed = false } else if ctx.has("onCancel") { ctx.fire("onCancel") }
            }
        )
    }

    var body: some View {
        EmptyAnchor().confirmationDialog(ctx.string("title") ?? "", isPresented: isPresented, titleVisibility: .visible) {
            Button(ctx.string("confirmTitle") ?? "Confirm", role: ctx.bool("destructive") ? .destructive : nil) {
                confirmed = true
                ctx.fire("onConfirm")
            }
            .buttonHoverPointer()
            .nativeHelp("Confirm")
            Button(ctx.string("cancelTitle") ?? "Cancel", role: .cancel) {}
                .buttonHoverPointer()
                .nativeHelp("Cancel")
        } message: {
            if let message = ctx.string("message") { Text(message) }
        }
    }
}
