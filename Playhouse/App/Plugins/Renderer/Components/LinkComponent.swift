import AppKit
import SwiftUI

enum LinkComponent: PluginComponent {
    static let type = "link"
    static let handlesOwnInput = true

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let text = ctx.string("text") ?? ""
        let url = ctx.string("url").flatMap(URL.init(string:)).flatMap { ["http", "https", "mailto"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        return AnyView(
            Button(text) {
                if ctx.has("onTap") { ctx.tap() }
                if let url { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.link)
            .buttonHoverPointer()
            .nativeHelp(ctx.string("tooltip") ?? ctx.string("url") ?? text)
        )
    }
}
