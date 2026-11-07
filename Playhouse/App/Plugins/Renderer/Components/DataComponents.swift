import SwiftUI

enum BadgeComponent: PluginComponent {
    static let type = "badge"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let tint = ctx.color("color") ?? WorkspaceTheme.accent
        let small = ctx.string("size") == "small"
        let style = ctx.string("style")
        let text = ctx.string("text") ?? ""
        let font: Font = small ? .caption2 : .caption
        let base = ctx.bool("monospaced") ? font.monospaced() : font
        let content: AnyView
        if let icon = ctx.string("icon") {
            content = AnyView(Label(text, systemImage: icon))
        } else {
            content = AnyView(Text(text))
        }
        let label = content.font(base.weight(.semibold)).padding(.horizontal, small ? 5 : 7).padding(.vertical, small ? 1 : 2)
        switch style {
        case "solid": return AnyView(label.foregroundStyle(.white).background(tint, in: Capsule()))
        case "outline": return AnyView(label.foregroundStyle(tint).overlay(Capsule().strokeBorder(tint)))
        default: return AnyView(label.foregroundStyle(tint).background(tint.opacity(0.12), in: Capsule()))
        }
    }
}

enum ChipComponent: PluginComponent {
    static let type = "chip"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let tint = ctx.color("color") ?? Color.secondary
        let selected = ctx.bool("selected")
        return AnyView(
            HStack(spacing: 5) {
                if let icon = ctx.string("icon") { Image(systemName: icon).font(.caption) }
                Text(ctx.string("text") ?? "").font(.caption)
                if ctx.bool("removable") {
                    Button {
                        ctx.fire("onRemove")
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 12, height: 12).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .buttonHoverPointer()
                    .nativeHelp("Remove")
                    .accessibilityLabel("Remove \(ctx.string("text") ?? "")")
                    .accessibilityIdentifier("plugin-node-\(ctx.node.id)-remove")
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(selected ? 0.18 : 0), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(selected ? 0.9 : 0.5)))
        )
    }
}

enum CardComponent: PluginComponent {
    static let type = "card"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let radius = ctx.cgFloat("cornerRadius") ?? 10
        let shape = RoundedRectangle(cornerRadius: radius)
        let content = VStack(alignment: .leading, spacing: ctx.cgFloat("spacing") ?? 8) { ctx.children }
            .padding(ctx.cgFloat("inset") ?? 12)
        switch ctx.string("style") {
        case "material": return AnyView(content.background(.regularMaterial, in: shape).overlay(shape.strokeBorder(Color(nsColor: .separatorColor))))
        case "dashed": return AnyView(content.overlay(shape.strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))))
        case "plain": return AnyView(content)
        default: return AnyView(content.background(WorkspaceTheme.panelBackground, in: shape).overlay(shape.strokeBorder(Color(nsColor: .separatorColor))))
        }
    }
}

enum StatusDotComponent: PluginComponent {
    static let type = "status-dot"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let size = ctx.cgFloat("size") ?? 8
        return AnyView(Circle().fill(ctx.color("color") ?? WorkspaceTheme.accent).frame(width: size, height: size))
    }
}

enum EmptyStateComponent: PluginComponent {
    static let type = "empty-state"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let content = VStack(spacing: 6) {
            if let icon = ctx.string("icon") { Image(systemName: icon).font(.title2).foregroundStyle(.secondary) }
            Text(ctx.string("title") ?? "").font(.headline)
            if let message = ctx.string("message") {
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .combine)
        guard ctx.string("style") == "dashed" else { return AnyView(content) }
        return AnyView(
            content
                .padding(20)
                .frame(maxWidth: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        )
    }
}

enum HintComponent: PluginComponent {
    static let type = "hint"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let tone = ctx.color("tone") ?? Color.secondary
        let text = ctx.string("text") ?? ""
        let content: AnyView = ctx.string("icon").map { AnyView(Label(text, systemImage: $0)) } ?? AnyView(Text(text))
        if ctx.string("style") == "capsule" {
            return AnyView(
                content.font(.callout).foregroundStyle(tone)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            )
        }
        return AnyView(content.font(.system(size: 10)).foregroundStyle(tone).textSelection(.enabled))
    }
}
