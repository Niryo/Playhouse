import SwiftUI

enum CodeComponent: PluginComponent {
    static let type = "code"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        AnyView(
            Text(ctx.string("text") ?? "")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(ctx.color("color") ?? Color.primary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                .textSelection(.enabled)
        )
    }
}
