import SwiftUI

enum LabelComponent: PluginComponent {
    static let type = "label"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let text = ctx.string("text") ?? ""
        let font = TextComponent.font(ctx.string("style"))
        let content: AnyView
        if let icon = ctx.string("icon") {
            content = ctx.bool("iconOnly")
                ? AnyView(Label(text, systemImage: icon).labelStyle(.iconOnly))
                : AnyView(Label(text, systemImage: icon))
        } else {
            content = AnyView(Text(text))
        }
        let styled = content.font(font)
        guard let color = ctx.color("color") else { return AnyView(styled) }
        return AnyView(styled.foregroundStyle(color))
    }
}
