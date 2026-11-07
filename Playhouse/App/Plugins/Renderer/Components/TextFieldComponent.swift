import SwiftUI

enum TextFieldComponent: PluginComponent {
    static let type = "textfield"
    static let handlesOwnInput = true

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        AnyView(PluginTextField(ctx: ctx, secure: false))
    }
}

enum SecureFieldComponent: PluginComponent {
    static let type = "secure-field"
    static let handlesOwnInput = true

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        AnyView(PluginTextField(ctx: ctx, secure: true))
    }
}

/// Keeps the typed text locally so typing stays smooth, sends every edit to the
/// node's onChange action, and follows the bound value when state changes it.
struct PluginTextField: View {
    let ctx: PluginRenderContext
    var secure = false
    @State private var text = ""
    /// Edits sent to the plugin whose echo through the bound value has not arrived yet.
    @State private var sent: [String] = []

    private var value: String { ctx.string("value") ?? "" }

    var body: some View {
        field
            .nativeHelp(ctx.string("tooltip") ?? ctx.string("placeholder") ?? (secure ? "Secure field" : "Text field"))
            .onAppear { text = value }
            .onChange(of: value) { _, newValue in
                // An echo of an edit that newer keystrokes have already superseded would rewind the field.
                if let echoed = sent.lastIndex(of: newValue) {
                    sent.removeSubrange(...echoed)
                    if !sent.isEmpty { return }
                } else {
                    sent.removeAll()
                }
                if newValue != text { text = newValue }
            }
            .onChange(of: text) { _, newText in
                if newText != value {
                    sent.append(newText)
                    ctx.input(newText)
                }
            }
    }

    @ViewBuilder
    private var field: some View {
        let placeholder = ctx.string("placeholder") ?? ""
        if secure {
            SecureField(placeholder, text: $text).textFieldStyle(.roundedBorder).onSubmit { if ctx.has("onSubmit") { ctx.fire("onSubmit") } }
        } else if ctx.string("style") == "plain" {
            TextField(placeholder, text: $text).textFieldStyle(.plain).onSubmit { if ctx.has("onSubmit") { ctx.fire("onSubmit") } }
        } else {
            TextField(placeholder, text: $text).textFieldStyle(.roundedBorder).onSubmit { if ctx.has("onSubmit") { ctx.fire("onSubmit") } }
        }
    }
}
