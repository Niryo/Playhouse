import SwiftUI

enum IconComponent: PluginComponent {
    static let type = "icon"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let name = ctx.string("name") ?? "questionmark"
        let image = Image(systemName: name)
            .font(.system(size: ctx.cgFloat("size") ?? 16))
            .accessibilityLabel(name)
        guard let color = ctx.color("color") else { return AnyView(image) }
        return AnyView(image.foregroundStyle(color))
    }
}
