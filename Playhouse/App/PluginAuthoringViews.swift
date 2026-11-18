import AppKit
import SwiftData
import SwiftUI

struct PluginCreationSetup: View {
    let placement: PluginPlacement
    let isStarting: Bool
    let onCancel: () -> Void
    let onStart: (String, PluginPresentation) -> Void
    @State private var name = ""
    @State private var hasName = false
    @State private var presentation: PluginPresentation = .popover
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Button("Back", action: onCancel)
                .buttonHoverPointer().nativeHelp("Cancel plugin creation")
                .accessibilityIdentifier("plugin-creation-back")
            Text(hasName ? "How should it open?" : "Name your plugin")
                .font(.title.bold())
            Text(hasName ? "Choose how \(name) appears when opened." : "Give your plugin a name to get started.")
                .foregroundStyle(.secondary)
            if hasName {
                Picker("How should it open?", selection: $presentation) {
                    ForEach([PluginPresentation.popover, .modal, .sidebar, .page], id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("plugin-creation-presentation")
                HStack {
                    Button("Back") { hasName = false }
                        .buttonHoverPointer().nativeHelp("Change plugin name")
                    Button("Start creating") { onStart(name.trimmingCharacters(in: .whitespacesAndNewlines), presentation) }
                        .disabled(isStarting)
                        .buttonHoverPointer().nativeHelp("Start creating this plugin")
                        .accessibilityIdentifier("plugin-creation-start")
                }
            } else {
                TextField("Plugin name", text: $name)
                    .focused($nameFocused)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("plugin-creation-name")
                Button("Continue") {
                    nameFocused = false
                    // A plugin at the sidebar's bottom always opens as a collapsible section.
                    if placement == .mainSidebarBottom {
                        onStart(name.trimmingCharacters(in: .whitespacesAndNewlines), .section)
                    } else {
                        withAnimation { hasName = true }
                    }
                }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isStarting)
                    .buttonHoverPointer().nativeHelp(placement == .mainSidebarBottom ? "Start creating this plugin" : "Choose how the plugin opens")
                    .accessibilityIdentifier("plugin-creation-continue")
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { nameFocused = true }
        .onChange(of: hasName) { _, hasName in
            if !hasName { nameFocused = true }
        }
    }
}

struct PluginAuthoringPreview: View {
    let task: any ConversationSubject
    let pluginID: String
    /// Closes the editor before a plugin that was never saved is discarded with its conversation.
    let onClose: () -> Void
    @State private var plugin: PluginRecord?
    @State private var isSaved = true
    @State private var hasChanges = false
    @State private var revision = ""
    @State private var versions: [Int] = []
    @State private var operationError: String?
    @State private var confirmDiscard = false
    @State private var previewDraft = ""
    @State private var previewComposerFocused = false
    @State private var previewComposerHeight: CGFloat = 36
    @State private var previewSelection = NSRange(location: 0, length: 0)
    @State private var previewEdit: ChatEditorEdit?
    @State private var previewFocusRequest = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Preview").font(.headline)
                Spacer()
                if let plugin { Text("Version \(plugin.version)").foregroundStyle(.secondary) }
                Menu("Restore version") {
                    ForEach(versions, id: \.self) { version in
                        Button("Version \(version)") { perform("plugin.restore", version: version) }
                            .buttonHoverPointer().nativeHelp("Restore this plugin version")
                    }
                }.disabled(versions.isEmpty)
                // A plugin that was never saved is itself unpublished, so it can always be discarded.
                if !isSaved || hasChanges {
                    Button("Discard changes") { confirmDiscard = true }
                        .buttonHoverPointer().nativeHelp(isSaved ? "Reset the draft to the published plugin" : "Delete this unsaved plugin and its conversation")
                }
                Button("Publish") { perform("plugin.save") }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!hasChanges)
                    .buttonHoverPointer().nativeHelp(hasChanges ? "Publish this plugin draft" : "No unpublished changes")
            }.padding()
            Divider()
            if let plugin, plugin.valid {
                PluginSurfaceView(plugin: plugin, props: PluginContext.props(
                    plugin: plugin, appearance: colorScheme == .dark ? "dark" : "light",
                    task: PluginTaskContext(task: task), composer: PluginComposerContext(draft: previewDraft, selectionLocation: previewSelection.location, selectionLength: previewSelection.length)),
                    actions: PluginUIActions(composer: applyComposerEdit))
                    .id(revision)
                if plugin.placement == PluginPlacement.composerActions.rawValue {
                    NativeChatEditor(text: Binding(get: { previewDraft }, set: { value in
                                         DispatchQueue.main.async { previewDraft = value }
                                     }), height: $previewComposerHeight,
                                     isFocused: $previewComposerFocused, focusRequest: previewFocusRequest,
                                     isEnabled: true, autofocusOnAppear: false, accessibilityHelp: "Preview composer",
                                     inputTestID: "plugin-preview-composer", inputLabel: "Preview message",
                                     onSubmit: {}, onSteerSubmit: {}, onPasteImage: { _ in },
                                     onSelectionChange: { selection in
                                         DispatchQueue.main.async { previewSelection = selection }
                                     },
                                     mentions: ChatEditorMentions(edit: previewEdit))
                        .frame(height: max(36, previewComposerHeight)).padding()
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "square.on.square") .font(.largeTitle)
                    Text("Your plugin preview will appear here") .font(.headline)
                    if let plugin, !plugin.errors.isEmpty {
                        Text(plugin.errors.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Describe your plugin in the conversation to get started.").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert(isSaved ? "Discard changes?" : "Discard plugin?", isPresented: $confirmDiscard) {
            Button("Discard", role: .destructive) { isSaved ? perform("plugin.discard") : discardUnsaved() }
                .buttonHoverPointer().nativeHelp("Discard the unpublished changes")
            Button("Cancel", role: .cancel) { }
                .buttonHoverPointer().nativeHelp("Keep the unpublished changes")
        } message: {
            Text(isSaved ? "The preview will be reset to the published plugin."
                 : "This plugin was never saved. Its draft and this conversation will be deleted.")
        }
        .alert("Plugin operation", isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
            Button("OK") { operationError = nil }
                .buttonHoverPointer().nativeHelp("Dismiss plugin operation message")
        } message: { Text(operationError ?? "") }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plugin-creation-preview")
        .task(id: pluginID) {
            await loadVersions()
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func perform(_ command: String, version: Int? = nil) {
        Task {
            do {
                var arguments: [String: BridgeValue] = ["pluginID": .string(pluginID)]
                if let version { arguments["version"] = .integer(version) }
                let result = try await DaemonClient().call(command, arguments)
                // The bridge decides: a plugin it found unsaved was deleted with this conversation.
                if result.object?["deleted"]?.bool == true { onClose(); return }
                if result.object?["draftSyncFailed"]?.bool == true {
                    operationError = "The plugin was published, but the draft could not be refreshed. Your existing draft was preserved."
                }
                await loadVersions()
                refresh()
            } catch { operationError = error.localizedDescription }
        }
    }

    /// Nothing of a plugin that was never saved is kept: the bridge deletes its draft and
    /// editor conversation, so the editor closes first, as deleting from the Plugins menu does.
    private func discardUnsaved() {
        onClose()
        Task { @MainActor in
            await Task.yield()
            do {
                _ = try await DaemonClient().call("plugin.discard", ["pluginID": .string(pluginID)])
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private func loadVersions() async {
        do {
            let result = try await DaemonClient().call("plugin.versions", ["pluginID": .string(pluginID)])
            versions = try result.object?["versions"]?.decoded([Int].self) ?? []
        } catch { operationError = error.localizedDescription }
    }

    private func applyComposerEdit(_ edit: PluginComposerEdit) {
        let length = (previewDraft as NSString).length
        let location = min(max(0, previewSelection.location), length)
        let selected = min(max(0, previewSelection.length), length - location)
        let range: NSRange
        let text: String
        switch edit {
        case .setDraft(let value): range = NSRange(location: 0, length: length); text = value
        case .insertText(let value): range = NSRange(location: location + selected, length: 0); text = value
        case .replaceSelection(let value): range = NSRange(location: location, length: selected); text = value
        case .focus:
            previewFocusRequest += 1
            return
        }
        previewEdit = ChatEditorEdit(id: (previewEdit?.id ?? 0) + 1, range: range, text: text)
    }

    private func refresh() {
        guard let folder = task.contextFolderPaths.first else { return }
        let draftData = URL(fileURLWithPath: folder).deletingLastPathComponent()
        let library = PluginLibrary(dataDirectory: draftData.path)
        let installed = PluginLibrary(dataDirectory: draftData.deletingLastPathComponent().deletingLastPathComponent().path)
        isSaved = installed.isInstalled(id: pluginID)
        hasChanges = installed.hasDraftChanges(id: pluginID)
        let current = try? library.plugin(id: pluginID, validate: false)
        let source = current.flatMap { try? String(contentsOfFile: $0.entryPath, encoding: .utf8) } ?? ""
        let signature = "\(String(describing: current))\n\(source)"
        if signature != revision {
            plugin = current
            revision = signature
        }
    }
}
