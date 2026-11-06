import SwiftUI

enum ButtonComponent: PluginComponent {
    static let type = "button"
    static let handlesOwnInput = true

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let title = ctx.string("title") ?? ""
        let button = Button(role: ctx.bool("destructive") ? .destructive : nil) {
            ctx.tap()
        } label: {
            if let icon = ctx.string("icon") {
                Label(title, systemImage: icon)
            } else {
                Text(title)
            }
        }
        .buttonHoverPointer()
        .nativeHelp(ctx.string("tooltip") ?? title)
        switch ctx.string("style") {
        case "prominent": return AnyView(button.buttonStyle(.borderedProminent))
        case "borderless": return AnyView(button.buttonStyle(.borderless))
        case "plain": return AnyView(button.buttonStyle(.plain))
        default: return AnyView(button.buttonStyle(.bordered))
        }
    }
}
