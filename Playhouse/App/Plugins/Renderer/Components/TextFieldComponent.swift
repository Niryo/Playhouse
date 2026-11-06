import SwiftUI

enum TextFieldComponent: PluginComponent {
    static let type = "textfield"
    static let handlesOwnInput = true

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        AnyView(PluginTextField(ctx: ctx))
    }
}

/// Keeps the typed text locally so typing stays smooth, sends every edit to the
/// node's onChange action, and follows the bound value when state changes it.
private struct PluginTextField: View {
    let ctx: PluginRenderContext
    @State private var text = ""

    private var value: String { ctx.string("value") ?? "" }

    var body: some View {
        TextField(ctx.string("placeholder") ?? "", text: $text)
            .textFieldStyle(.roundedBorder)
            .nativeHelp(ctx.string("tooltip") ?? ctx.string("placeholder") ?? "Text field")
            .onAppear { text = value }
            .onChange(of: value) { _, newValue in
                if newValue != text { text = newValue }
            }
            .onChange(of: text) { _, newText in
                if newText != value { ctx.input(newText) }
            }
    }
}
