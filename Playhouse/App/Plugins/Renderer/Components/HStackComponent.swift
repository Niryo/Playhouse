import SwiftUI

enum HStackComponent: PluginComponent {
    static let type = "hstack"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        AnyView(HStack(alignment: ctx.verticalAlignment, spacing: ctx.cgFloat("spacing")) { ctx.children })
    }
}
