import SwiftUI

enum HeadingComponent: PluginComponent {
    static let type = "heading"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let font: Font = switch ctx.string("level") {
        case "1": .title.bold()
        case "3": .title3.weight(.semibold)
        case "4": .headline
        default: .title2.weight(.semibold)
        }
        return AnyView(Text(ctx.string("text") ?? "").font(font).accessibilityAddTraits(.isHeader))
    }
}
