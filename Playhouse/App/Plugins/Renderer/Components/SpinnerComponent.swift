import SwiftUI

enum SpinnerComponent: PluginComponent {
    static let type = "spinner"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let size: ControlSize = switch ctx.string("size") {
        case "mini": .mini
        case "small": .small
        case "large": .large
        default: .regular
        }
        return AnyView(HStack(spacing: 8) {
            ProgressView().progressViewStyle(.circular).controlSize(size)
            if let label = ctx.string("label") { Text(label).foregroundStyle(.secondary) }
        })
    }
}
