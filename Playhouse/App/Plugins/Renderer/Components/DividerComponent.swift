import AppKit
import SwiftUI

enum DividerComponent: PluginComponent {
    static let type = "divider"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let line = Color(nsColor: .separatorColor)
        switch ctx.string("axis") {
        case "vertical": return AnyView(Rectangle().fill(line).frame(width: 1))
        case "horizontal": return AnyView(Rectangle().fill(line).frame(height: 1))
        // A plain Divider already runs across the stack it sits in.
        default: return AnyView(Divider())
        }
    }
}
