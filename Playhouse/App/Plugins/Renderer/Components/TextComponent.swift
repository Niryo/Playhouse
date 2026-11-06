import SwiftUI

enum TextComponent: PluginComponent {
    static let type = "text"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        var text = Text(ctx.string("text") ?? "").font(font(ctx.string("style")))
        if let weight = weight(ctx.string("weight")) { text = text.fontWeight(weight) }
        if ctx.bool("monospaced") { text = text.monospaced() }
        if let color = ctx.color("color") { text = text.foregroundColor(color) }
        return AnyView(text.lineLimit(ctx.number("lineLimit").map { Int($0) }))
    }

    static func font(_ style: String?) -> Font {
        switch style {
        case "largeTitle": .largeTitle
        case "title": .title
        case "headline": .headline
        case "subheadline": .subheadline
        case "callout": .callout
        case "footnote": .footnote
        case "caption": .caption
        default: .body
        }
    }

    static func weight(_ name: String?) -> Font.Weight? {
        switch name {
        case "regular": .regular
        case "medium": .medium
        case "semibold": .semibold
        case "bold": .bold
        default: nil
        }
    }
}
