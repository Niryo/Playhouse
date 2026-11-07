import SwiftUI

enum TextEditorComponent: PluginComponent {
    static let type = "text-editor"
    static let handlesOwnInput = true

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        AnyView(PluginTextEditor(ctx: ctx))
    }
}

private struct PluginTextEditor: View {
    let ctx: PluginRenderContext
    @State private var text = ""

    private var value: String { ctx.string("value") ?? "" }

    var body: some View {
        let lines = max(ctx.number("minLines") ?? 3, 1)
        TextEditor(text: $text)
            .font(ctx.bool("monospaced") ? .system(.body, design: .monospaced) : .body)
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(minHeight: CGFloat(lines) * 17 + 8)
            .background(WorkspaceTheme.inputBackground, in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topLeading) {
                if text.isEmpty, let placeholder = ctx.string("placeholder") {
                    Text(placeholder).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
                }
            }
            .nativeHelp(ctx.string("tooltip") ?? ctx.string("placeholder") ?? "Text editor")
            .onAppear { text = value }
            .onChange(of: value) { _, newValue in
                if newValue != text { text = newValue }
            }
            .onChange(of: text) { _, newText in
                if newText != value { ctx.input(newText) }
            }
    }
}
