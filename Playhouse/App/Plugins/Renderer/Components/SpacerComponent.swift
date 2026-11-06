import SwiftUI

enum SpacerComponent: PluginComponent {
    static let type = "spacer"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        AnyView(Spacer(minLength: ctx.cgFloat("minLength")))
    }
}
