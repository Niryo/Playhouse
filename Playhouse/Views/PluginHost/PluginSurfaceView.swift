import Foundation
import PlayhouseCore
import PlayhouseAtoms
import PlayhouseUI

/// One installed plugin's surface: the app's standard modal header (the
/// plugin's icon and name and a close button, `AtomModalHeader`) and the atoms
/// its script renders, kept live as its placement's context changes. The
/// surface pads both by its presentation's `inset` and spaces the script's
/// root atoms apart, so a plugin needs no title or outer padding of its own.
/// An inline or section plugin has no header of its own: it is a section of
/// its sidebar (a section plugin's collapsible header is `PluginSection`'s).
/// Host calls are answered by `PluginHost`, as a built-in plugin's are.
package struct PluginSurfaceView: PHView {
    package let plugin: PluginRecord
    package let props: [String: PluginValue]
    package let actions: PluginUIActions
    /// Keeps the plugin running when its view is rebuilt elsewhere, as a task
    /// card's is when the task moves to another column: the new view takes
    /// over the same runtime and hands it the events of the change.
    package var keepAliveKey: String?
    @PHState private var runtime: PluginRuntime?
    @PHState private var loadError: String?

    package var body: some PHView {
        let inset = plugin.surfaceInset
        PHVStack(alignment: .leading, spacing: 0) {
            if plugin.presentationKind.isInPlace {
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
                PHScrollView {
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
        // A section with nothing to show hides, header included.
        .preference(key: PluginSectionContentKey.self, value: hasContent)
        .task(id: plugin.entryPath) { load() }
        .onDisappear {
            if let keepAliveKey { PluginRuntimeKeepAlive.release(keepAliveKey) }
        }
        .onChange(of: props) { old, props in
            if let keepAliveKey {
                // A kept runtime may be shared: it takes each change once.
                PluginRuntimeKeepAlive.update(keepAliveKey, props: props)
            } else {
                runtime?.updateProps(props)
                for event in Self.events(from: old, to: props) { runtime?.emit(event) }
            }
        }
        .phOnAppActivation {
            runtime?.emit(PluginEvent(name: PluginEvent.appFocus))
        }
    }

    /// The app events a change of the plugin's context amounts to: its task
    /// moving to another column, and each of its saved values changing.
    package static func events(from old: [String: PluginValue], to new: [String: PluginValue]) -> [PluginEvent] {
        var events: [PluginEvent] = []
        if let task = new["task"]?.object, let id = task["id"]?.string, old["task"]?.object?["id"]?.string == id,
           let from = old["task"]?.object?["status"]?.string, let to = task["status"]?.string, from != to {
            events.append(.statusChanged(taskID: id, from: from, to: to))
        }
        let oldState = old["state"]?.object ?? [:], newState = new["state"]?.object ?? [:]
        if let pluginID = new["plugin"]?.object?["id"]?.string {
            for key in Set(oldState.keys).union(newState.keys).sorted() where oldState[key] != newState[key] {
                events.append(.stateChanged(pluginID: pluginID, key: key, value: newState[key] ?? .null))
            }
        }
        return events
    }

    private var content: some PHView {
        PHVStack(alignment: .leading, spacing: 12) {
            if let runtime {
                PHForEach(runtime.tree.root.children) { node in
                    PluginNodeView(node: node, events: runtime)
                }
                errors(runtime.errors)
            } else if let loadError {
                errors([loadError])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hasContent: Bool {
        if let runtime { return !runtime.tree.root.children.isEmpty || !runtime.errors.isEmpty }
        return loadError != nil
    }

    private var host: PluginHost { PluginHost(plugin: plugin, actions: actions) }

    private func errors(_ errors: [String]) -> some PHView {
        PHForEach(Array(errors.enumerated()), id: \.offset) { _, error in
            PHText(error)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .accessibilityIdentifier("plugin-error")
        }
    }

    private func load() {
        if let keepAliveKey, let kept = PluginRuntimeKeepAlive.acquire(keepAliveKey, script: plugin.keepAliveScript) {
            // The same plugin rebuilt: it answers through this view's host from
            // now on and hears what changed while it moved.
            answerHostCalls(of: kept.runtime)
            PluginRuntimeKeepAlive.update(keepAliveKey, props: props)
            runtime = kept.runtime
            return
        }
        do {
            let source = try String(contentsOfFile: plugin.entryPath, encoding: .utf8)
            let runtime = try PluginRuntime(source: source, sourceName: URL(fileURLWithPath: plugin.entryPath).lastPathComponent, props: props)
            answerHostCalls(of: runtime)
            // Calls made while the script first ran, before the handler was set.
            for call in runtime.pendingHostCalls {
                Task { @MainActor in runtime.answerHostCall(call.id, result: await host.answer(kind: call.kind, name: call.name, arguments: call.arguments)) }
            }
            if let keepAliveKey { PluginRuntimeKeepAlive.store(keepAliveKey, runtime: runtime, script: plugin.keepAliveScript, props: props) }
            self.runtime = runtime
            // The prelude keeps it for the listener the plugin's first effects add.
            if PluginLaunch.claim(plugin.id) { runtime.emit(PluginEvent(name: PluginEvent.appLaunched)) }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func answerHostCalls(of runtime: PluginRuntime) {
        let host = host
        runtime.onHostCall = { [weak runtime] call in
            Task { @MainActor in
                let result = await host.answer(kind: call.kind, name: call.name, arguments: call.arguments)
                runtime?.answerHostCall(call.id, result: result)
            }
        }
    }

    package init(plugin: PluginRecord, props: [String: PluginValue], actions: PluginUIActions, keepAliveKey: String? = nil) {
        self.plugin = plugin
        self.props = props
        self.actions = actions
        self.keepAliveKey = keepAliveKey
    }
}

/// The runtimes of plugin views that asked to be kept alive, by key. A view
/// that disappears releases its runtime; if no view takes it over shortly
/// (the rebuilt card appears in the same update), it stops.
@MainActor
package enum PluginRuntimeKeepAlive {
    package struct Entry {
        package var runtime: PluginRuntime
        package var script: String
        package var props: [String: PluginValue]
        package var holders = 0
        package var expiry: Task<Void, Never>?

        package init(runtime: PluginRuntime, script: String, props: [String: PluginValue], holders: Int = 0, expiry: Task<Void, Never>? = nil) {
            self.runtime = runtime
            self.script = script
            self.props = props
            self.holders = holders
            self.expiry = expiry
        }
    }

    private static var entries: [String: Entry] = [:]
    private static let grace: Duration = .seconds(2)

    package static func store(_ key: String, runtime: PluginRuntime, script: String, props: [String: PluginValue]) {
        entries[key]?.expiry?.cancel()
        entries[key] = Entry(runtime: runtime, script: script, props: props, holders: 1)
    }

    /// The kept runtime for `key`, if it runs the same version of the same script.
    package static func acquire(_ key: String, script: String) -> Entry? {
        guard var entry = entries[key], entry.script == script else { return nil }
        entry.expiry?.cancel()
        entry.expiry = nil
        entry.holders += 1
        entries[key] = entry
        return entry
    }

    /// Hands the kept runtime `props` and the events of the change from the
    /// last props it saw, once however many views hold it.
    package static func update(_ key: String, props: [String: PluginValue]) {
        guard let entry = entries[key], entry.props != props else { return }
        entries[key]?.props = props
        entry.runtime.updateProps(props)
        for event in PluginSurfaceView.events(from: entry.props, to: props) { entry.runtime.emit(event) }
    }

    package static func release(_ key: String) {
        guard var entry = entries[key] else { return }
        entry.holders = max(0, entry.holders - 1)
        if entry.holders == 0 {
            entry.expiry = Task { @MainActor in
                try? await Task.sleep(for: grace)
                guard !Task.isCancelled, entries[key]?.holders == 0 else { return }
                entries[key] = nil
            }
        }
        entries[key] = entry
    }
}

extension PluginRecord {
    /// What a kept runtime runs: an edited or reinstalled plugin loads afresh.
    package var keepAliveScript: String { "\(entryPath)#\(version)" }

    package var presentationKind: PluginPresentation { PluginPresentation(rawValue: presentation) ?? .popover }

    /// The surface's size: the manifest's, or the presentation's default.
    package var surfaceSize: CGSize {
        let defaults: CGSize = switch presentationKind {
        case .popover: CGSize(width: 320, height: 260)
        case .modal: CGSize(width: 520, height: 420)
        case .sidebar: CGSize(width: 360, height: 0)
        case .page, .inline, .section, .headless: CGSize(width: 0, height: 0)
        }
        return CGSize(width: width ?? defaults.width, height: height ?? defaults.height)
    }

    /// The padding around the surface's header and content: a sheet's or a
    /// page's matches the app's own sheets, and a popover's is tighter.
    package var surfaceInset: CGFloat {
        switch presentationKind {
        case .popover: 16
        case .sidebar: 20
        case .inline: 10
        // The section's header and the sidebar already inset it.
        case .section: 0
        case .modal, .page: CGFloat(ModalProps.defaultInset)
        case .headless: 0
        }
    }
}
