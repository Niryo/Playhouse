import SwiftUI

/// One installed plugin's surface: the app's standard modal header (the
/// plugin's icon and name and a close button, `AtomModalHeader`) and the atoms
/// its script renders, kept live as its placement's context changes. The
/// surface pads both by its presentation's `inset` and spaces the script's
/// root atoms apart, so a plugin needs no title or outer padding of its own.
/// An inline plugin has no header: it is a section of its sidebar.
/// Host calls are answered by `PluginHost`, as a built-in plugin's are.
struct PluginSurfaceView: View {
    let plugin: PluginRecord
    let props: [String: PluginValue]
    let actions: PluginUIActions
    @State private var runtime: PluginRuntime?
    @State private var loadError: String?

    var body: some View {
        let inset = plugin.surfaceInset
        VStack(alignment: .leading, spacing: 0) {
            if plugin.presentationKind == .inline {
                // A section of its sidebar: no header, and the sidebar's own room
                // instead of a scroll view, so the plugin can scroll its own lists.
                content.padding(.horizontal, inset)
            } else {
                AtomModalHeader(
                    title: plugin.name, icon: plugin.icon, titleSize: plugin.presentationKind == .popover ? 15 : 19,
                    idPrefix: "plugin-surface", onClose: actions.close
                )
                .padding([.horizontal, .top], inset)
                .padding(.bottom, 4)
                ScrollView {
                    content
                        .padding(.horizontal, inset)
                        .padding(.top, inset / 2)
                        .padding(.bottom, inset)
                        .hoverRevealScrollers()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plugin-surface-\(plugin.id)")
        .task(id: plugin.entryPath) { load() }
        .onChange(of: props) { _, props in runtime?.updateProps(props) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let runtime {
                ForEach(runtime.tree.root.children) { node in
                    PluginNodeView(node: node, runtime: runtime)
                }
                errors(runtime.errors)
            } else if let loadError {
                errors([loadError])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var host: PluginHost { PluginHost(plugin: plugin, actions: actions) }

    private func errors(_ errors: [String]) -> some View {
        ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
            Text(error)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .accessibilityIdentifier("plugin-error")
        }
    }

    private func load() {
        do {
            let source = try String(contentsOfFile: plugin.entryPath, encoding: .utf8)
            let runtime = try PluginRuntime(source: source, sourceName: URL(fileURLWithPath: plugin.entryPath).lastPathComponent, props: props)
            runtime.onHostCall = { [weak runtime] call in
                Task { @MainActor in
                    let result = await host.answer(kind: call.kind, name: call.name, arguments: call.arguments)
                    runtime?.answerHostCall(call.id, result: result)
                }
            }
            // Calls made while the script first ran, before the handler was set.
            for call in runtime.pendingHostCalls {
                Task { @MainActor in runtime.answerHostCall(call.id, result: await host.answer(kind: call.kind, name: call.name, arguments: call.arguments)) }
            }
            self.runtime = runtime
        } catch {
            loadError = error.localizedDescription
        }
    }
}

extension PluginRecord {
    var presentationKind: PluginPresentation { PluginPresentation(rawValue: presentation) ?? .popover }

    /// The surface's size: the manifest's, or the presentation's default.
    var surfaceSize: CGSize {
        let defaults: CGSize = switch presentationKind {
        case .popover: CGSize(width: 320, height: 260)
        case .modal: CGSize(width: 520, height: 420)
        case .sidebar: CGSize(width: 360, height: 0)
        case .page, .inline: CGSize(width: 0, height: 0)
        }
        return CGSize(width: width ?? defaults.width, height: height ?? defaults.height)
    }

    /// The padding around the surface's header and content: a sheet's or a
    /// page's matches the app's own sheets, and a popover's is tighter.
    var surfaceInset: CGFloat {
        switch presentationKind {
        case .popover: 16
        case .sidebar: 20
        case .inline: 10
        case .modal, .page: CGFloat(ModalProps.defaultInset)
        }
    }
}
