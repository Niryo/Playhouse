import AppKit
import SwiftUI

enum IconButtonComponent: PluginComponent {
    static let type = "icon-button"
    static let handlesOwnInput = true

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let icon = ctx.string("icon") ?? "questionmark"
        let title = ctx.string("title") ?? icon
        let points: CGFloat = switch ctx.string("size") {
        case "mini": 10
        case "regular": 15
        default: 12
        }
        let button = Button(role: ctx.bool("destructive") ? .destructive : nil) {
            ctx.tap()
        } label: {
            Image(systemName: icon)
                .font(.system(size: points))
                .foregroundStyle(ctx.color("color") ?? (ctx.bool("destructive") ? Color.red : Color.secondary))
                .frame(width: points + 8, height: points + 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonHoverPointer()
        .nativeHelp(ctx.string("tooltip") ?? title)
        .accessibilityLabel(title)
        return ctx.bool("emphasis") ? AnyView(button.actionButtonHoverEmphasis()) : AnyView(button)
    }
}

enum CopyButtonComponent: PluginComponent {
    static let type = "copy-button"
    static let handlesOwnInput = true

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        AnyView(PluginCopyButton(ctx: ctx))
    }
}

/// Puts text on the clipboard and shows a checkmark for a moment, like the app's code blocks.
private struct PluginCopyButton: View {
    let ctx: PluginRenderContext
    @State private var copied = false

    var body: some View {
        let title = ctx.string("title")
        let icon = copied ? "checkmark" : (ctx.string("icon") ?? "doc.on.doc")
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ctx.string("text") ?? "", forType: .string)
            copied = true
            if ctx.has("onCopy") { ctx.fire("onCopy") }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            if let title {
                Label(copied ? "Copied" : title, systemImage: icon)
            } else {
                Image(systemName: icon).frame(width: 22, height: 20).contentShape(Rectangle())
            }
        }
        .buttonStyle(.borderless)
        .buttonHoverPointer()
        .nativeHelp(ctx.string("tooltip") ?? title ?? "Copy")
        .accessibilityLabel(title ?? "Copy")
    }
}
