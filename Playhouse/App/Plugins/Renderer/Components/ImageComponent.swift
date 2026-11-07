import AppKit
import SwiftUI

enum ImageComponent: PluginComponent {
    static let type = "image"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        guard let url = ctx.fileURL("src"), let image = NSImage(contentsOf: url) else {
            return AnyView(PluginPlaceholder(symbol: "photo", message: "Can't load image \"\(ctx.string("src") ?? "")\".", identifier: "plugin-error"))
        }
        let picture = Image(nsImage: image).resizable()
        let sized = ctx.string("fit") == "fill" ? AnyView(picture.scaledToFill()) : AnyView(picture.scaledToFit())
        return AnyView(
            sized
                .clipShape(RoundedRectangle(cornerRadius: ctx.cgFloat("cornerRadius") ?? 0))
                .accessibilityLabel(ctx.string("alt") ?? url.deletingPathExtension().lastPathComponent)
        )
    }
}

enum AvatarComponent: PluginComponent {
    static let type = "avatar"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let size = ctx.cgFloat("size") ?? 28
        let initials = initials(ctx.string("text") ?? "")
        let content: AnyView
        if let url = ctx.fileURL("src"), let image = NSImage(contentsOf: url) {
            content = AnyView(Image(nsImage: image).resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle()))
        } else {
            content = AnyView(
                Circle().fill(ctx.color("color") ?? WorkspaceTheme.accent)
                    .frame(width: size, height: size)
                    .overlay(Text(initials).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white))
            )
        }
        return AnyView(content.accessibilityElement(children: .ignore).accessibilityLabel(ctx.string("text") ?? "Avatar"))
    }

    /// The first letters of up to two words: "Ada Lovelace" is "AL".
    static func initials(_ name: String) -> String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}
