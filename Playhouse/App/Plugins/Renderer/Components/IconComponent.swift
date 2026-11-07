import AppKit
import SwiftUI

enum IconComponent: PluginComponent {
    static let type = "icon"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let size = ctx.cgFloat("size") ?? 16
        let content: AnyView
        if let url = ctx.fileURL("src"), let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            content = AnyView(
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                    .frame(width: size, height: size)
                    .accessibilityLabel(url.deletingPathExtension().lastPathComponent)
            )
        } else {
            let name = ctx.string("name") ?? "questionmark"
            content = AnyView(
                Image(systemName: name)
                    .font(.system(size: size, weight: TextComponent.weight(ctx.string("weight")) ?? .regular))
                    .symbolRenderingMode(rendering(ctx.string("rendering")))
                    .accessibilityLabel(name)
            )
        }
        guard let color = ctx.color("color") else { return content }
        return AnyView(content.foregroundStyle(color))
    }

    private static func rendering(_ name: String?) -> SymbolRenderingMode {
        switch name {
        case "hierarchical": .hierarchical
        case "multicolor": .multicolor
        default: .monochrome
        }
    }
}
