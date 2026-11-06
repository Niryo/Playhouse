import SwiftUI

enum VStackComponent: PluginComponent {
    static let type = "vstack"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        AnyView(VStack(alignment: ctx.horizontalAlignment, spacing: ctx.cgFloat("spacing")) { ctx.children })
    }
}
