import SwiftUI

enum SearchFieldComponent: PluginComponent {
    static let type = "search-field"
    static let handlesOwnInput = true

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        AnyView(PluginSearchField(ctx: ctx))
    }
}

private struct PluginSearchField: View {
    let ctx: PluginRenderContext
    @State private var text = ""

    private var value: String { ctx.string("value") ?? "" }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(ctx.string("placeholder") ?? "Search", text: $text)
                .textFieldStyle(.plain)
                .onSubmit { if ctx.has("onSubmit") { ctx.fire("onSubmit") } }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .buttonHoverPointer()
                .nativeHelp("Clear")
                .accessibilityLabel("Clear")
                .accessibilityIdentifier("plugin-node-\(ctx.node.id)-clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(WorkspaceTheme.inputBackground, in: RoundedRectangle(cornerRadius: 8))
        .nativeHelp(ctx.string("tooltip") ?? ctx.string("placeholder") ?? "Search")
        .onAppear { text = value }
        .onChange(of: value) { _, newValue in
            if newValue != text { text = newValue }
        }
        .onChange(of: text) { _, newText in
            if newText != value { ctx.input(newText) }
        }
    }
}
