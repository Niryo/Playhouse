import SwiftUI

/// A composer change a plugin asks for through `Playhouse.ui.composer`.
enum PluginComposerEdit {
    case setDraft(String)
    case insertText(String)
    case replaceSelection(String)
    case focus
}

/// What a mounted plugin's `Playhouse.ui` calls do in the window showing it.
struct PluginUIActions {
    var close: () -> Void = {}
    var openTask: (UUID) -> Void = { _ in }
    /// Nil where there is no composer (the board's sidebar).
    var composer: ((PluginComposerEdit) -> Void)? = nil
}

/// One installed plugin's surface: its header (name and close button) and the
/// atoms its script renders, kept live as its placement's context changes.
/// `Playhouse.bridge` calls go to the bridge daemon as the CLI's do.
struct PluginSurfaceView: View {
    let plugin: PluginRecord
    let props: [String: PluginValue]
    let actions: PluginUIActions
    @State private var runtime: PluginRuntime?
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AtomLabel(props: LabelProps(text: plugin.name, icon: plugin.icon, size: 13, weight: "semibold"))
                Spacer(minLength: 0)
                AtomButton(common: AtomCommon(testID: "plugin-surface-close", label: "Close \(plugin.name)", help: "Close"), action: actions.close) {
                    AtomIcon(props: IconProps(name: "xmark", size: 11, weight: "semibold", color: "secondary"))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
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
                .padding(14)
                .hoverRevealScrollers()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plugin-surface-\(plugin.id)")
        .task(id: plugin.entryPath) { load() }
        .onChange(of: props) { _, props in runtime?.updateProps(props) }
    }

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
                    let result = await answer(call)
                    runtime?.answerHostCall(call.id, result: result)
                }
            }
            // Calls made while the script first ran, before the handler was set.
            for call in runtime.pendingHostCalls {
                Task { @MainActor in runtime.answerHostCall(call.id, result: await answer(call)) }
            }
            self.runtime = runtime
        } catch {
            loadError = error.localizedDescription
        }
    }

    @MainActor
    private func answer(_ call: PluginRuntime.HostCall) async -> Result<PluginValue, PluginHostError> {
        let text = call.arguments.object?["text"]?.string ?? ""
        if let refusal = PluginHostRules.refusal(kind: call.kind, name: call.name, placement: PluginPlacement(rawValue: plugin.placement)) {
            return .failure(refusal)
        }
        switch (call.kind, call.name) {
        case ("bridge", let command):
            do {
                let value = try await DaemonClient().call(command, BridgeValue(plugin: call.arguments).object ?? [:])
                return .success(PluginValue(bridge: value))
            } catch let error as BridgeCommandError {
                return .failure(PluginHostError(code: error.code, message: error.message))
            } catch {
                return .failure(PluginHostError(code: "operation_failed", message: error.localizedDescription))
            }
        case ("net", "fetch"):
            return await PluginNetwork.fetch(call.arguments)
        case ("ui", "close"):
            actions.close()
        case ("ui", "openTask"):
            guard let id = call.arguments.object?["taskID"]?.string.flatMap(UUID.init(uuidString:)) else {
                return .failure(PluginHostError(code: "invalid_argument", message: "openTask needs a task ID."))
            }
            actions.openTask(id)
        case ("ui", let name) where name.hasPrefix("composer."):
            guard let composer = actions.composer else {
                return .failure(PluginHostError(code: "unavailable", message: "There is no composer at this placement."))
            }
            switch name {
            case "composer.setDraft": composer(.setDraft(text))
            case "composer.insertText": composer(.insertText(text))
            case "composer.replaceSelection": composer(.replaceSelection(text))
            case "composer.focus": composer(.focus)
            default: return .failure(PluginHostError(code: "invalid_argument", message: "Unknown composer action \(name)."))
            }
        default:
            return .failure(PluginHostError(code: "invalid_argument", message: "Unknown host call \(call.kind).\(call.name)."))
        }
        return .success(.null)
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
        case .page: CGSize(width: 0, height: 0)
        }
        return CGSize(width: width ?? defaults.width, height: height ?? defaults.height)
    }
}
