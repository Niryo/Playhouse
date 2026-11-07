import SwiftUI

enum ScrollComponent: PluginComponent {
    static let type = "scroll"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let spacing = ctx.cgFloat("spacing") ?? 8
        if ctx.string("axis") == "horizontal" {
            return AnyView(ScrollView(.horizontal) { HStack(spacing: spacing) { ctx.children } })
        }
        return AnyView(ScrollView(.vertical) { VStack(alignment: .leading, spacing: spacing) { ctx.children }.frame(maxWidth: .infinity, alignment: .leading) })
    }
}
