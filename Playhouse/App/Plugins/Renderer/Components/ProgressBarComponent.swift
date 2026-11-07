import SwiftUI

enum ProgressBarComponent: PluginComponent {
    static let type = "progress-bar"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let label = ctx.string("label")
        let tint = ctx.color("color")
        guard let value = ctx.number("value") else {
            return AnyView(ProgressView {
                if let label { Text(label) }
            }.progressViewStyle(.linear).tint(tint))
        }
        let total = max(ctx.number("total") ?? 100, 0.0001)
        let clamped = min(max(value, 0), total)
        let percent = Int((clamped / total * 100).rounded())
        if let thickness = ctx.cgFloat("thickness") {
            return AnyView(
                SlimBar(fraction: clamped / total, thickness: thickness, vertical: ctx.string("axis") == "vertical", tint: tint ?? WorkspaceTheme.accent)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(label ?? "Progress")
                    .accessibilityValue("\(percent)%")
            )
        }
        return AnyView(
            ProgressView(value: clamped, total: total) {
                if let label { Text(label) }
            } currentValueLabel: {
                if ctx.bool("showValue") { Text("\(percent)%") }
            }
            .progressViewStyle(.linear)
            .tint(tint)
            .accessibilityValue("\(percent)%")
        )
    }
}

/// The app's capsule gauges: a token share bar, a usage window, the CPU meter.
private struct SlimBar: View {
    let fraction: Double
    let thickness: CGFloat
    let vertical: Bool
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let length = (vertical ? proxy.size.height : proxy.size.width) * fraction
            ZStack(alignment: vertical ? .bottom : .leading) {
                Capsule().fill(Color.gray.opacity(0.25))
                Capsule().fill(tint).frame(width: vertical ? nil : length, height: vertical ? length : nil)
            }
        }
        .frame(width: vertical ? thickness : nil, height: vertical ? nil : thickness)
        .frame(minWidth: vertical ? nil : 40, minHeight: vertical ? 40 : nil)
    }
}
