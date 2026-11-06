import SwiftUI

enum ZStackComponent: PluginComponent {
    static let type = "zstack"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        AnyView(ZStack(alignment: ctx.alignment("alignment") ?? .center) { ctx.children })
    }
}
