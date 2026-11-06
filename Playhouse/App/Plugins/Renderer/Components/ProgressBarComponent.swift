import SwiftUI

enum ProgressBarComponent: PluginComponent {
    static let type = "progress-bar"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let label = ctx.string("label")
        guard let value = ctx.number("value") else {
            return AnyView(ProgressView {
                if let label { Text(label) }
            }.progressViewStyle(.linear))
        }
        let total = max(ctx.number("total") ?? 100, 0.0001)
        let clamped = min(max(value, 0), total)
        let percent = Int((clamped / total * 100).rounded())
        return AnyView(
            ProgressView(value: clamped, total: total) {
                if let label { Text(label) }
            } currentValueLabel: {
                if ctx.bool("showValue") { Text("\(percent)%") }
            }
            .progressViewStyle(.linear)
            .accessibilityValue("\(percent)%")
        )
    }
}
