import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

package struct PluginCreationSetup: PHView {
    package let placement: PluginPlacement
    package let isStarting: Bool
    package let onCancel: () -> Void
    package let onStart: (String, PluginPresentation) -> Void
    @PHState private var name = ""
    @PHState private var hasName = false
    @PHState private var presentation: PluginPresentation = .popover
    @PHFocusState private var nameFocused: Bool

    package var body: some PHView {
        AtomStack(props: StackProps(axis: "v", spacing: 20, align: "leading"), common: AtomCommon(maxWidth: 420, fillWidth: true, fillHeight: true, frameAlign: "leading")) {
            AtomButton(props: ButtonProps(style: "automatic"), common: AtomCommon(help: "Cancel plugin creation"), action: onCancel) { AtomText(props: TextProps(text: "Back")) }
                .accessibilityIdentifier("plugin-creation-back")
            AtomText(props: TextProps(text: hasName ? "How should it open?" : "Name your plugin", weight: "bold", textStyle: "title"))
            AtomText(props: TextProps(text: hasName ? "Choose how \(name) appears when opened." : "Give your plugin a name to get started.", color: "secondary"))
            if hasName {
                AtomSegmented(
                    style: "radio", showsLabel: true, selection: $presentation,
                    options: [.popover, .modal, .sidebar, .page], label: { $0.title },
                    common: AtomCommon(testID: "plugin-creation-presentation", label: "How should it open?")
                )
                AtomStack(props: StackProps(axis: "h")) {
                    AtomButton(props: ButtonProps(style: "automatic"), common: AtomCommon(help: "Change plugin name"), action: { hasName = false }) { AtomText(props: TextProps(text: "Back")) }
                    AtomButton(props: ButtonProps(style: "automatic", disabled: isStarting), common: AtomCommon(help: "Start creating this plugin"), action: { onStart(name.trimmingCharacters(in: .whitespacesAndNewlines), presentation) }) { AtomText(props: TextProps(text: "Start creating")) }
                        .accessibilityIdentifier("plugin-creation-start")
                }
            } else {
                AtomTextField(
                    props: TextFieldProps(text: name, placeholder: "Plugin name"),
                    common: AtomCommon(testID: "plugin-creation-name"),
                    onChange: { name = $0 }, focus: $nameFocused
                )
                AtomButton(props: ButtonProps(style: "automatic", disabled: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isStarting), common: AtomCommon(help: placement == .mainSidebarBottom ? "Start creating this plugin" : "Choose how the plugin opens"), action: {
                    nameFocused = false
                    // A plugin at the sidebar's bottom always opens as a collapsible section.
                    if placement == .mainSidebarBottom {
                        onStart(name.trimmingCharacters(in: .whitespacesAndNewlines), .section)
                    } else {
                        phWithAnimation { hasName = true }
                    }
                }) { AtomText(props: TextProps(text: "Continue")) }
                    .accessibilityIdentifier("plugin-creation-continue")
            }
        }
        .onAppear { nameFocused = true }
        .onChange(of: hasName) { _, hasName in
            if !hasName { nameFocused = true }
        }
    }

    package init(placement: PluginPlacement, isStarting: Bool, onCancel: @escaping () -> Void, onStart: @escaping (String, PluginPresentation) -> Void) {
        self.placement = placement
        self.isStarting = isStarting
        self.onCancel = onCancel
        self.onStart = onStart
    }
}

package struct PluginAuthoringPreview: PHView {
    package let task: any ConversationSubject
    package let pluginID: String
    /// Closes the editor before a plugin that was never saved is discarded with its conversation.
    package let onClose: () -> Void
    @PHState private var plugin: PluginRecord?
    @PHState private var isSaved = true
    @PHState private var hasChanges = false
    @PHState private var revision = ""
    @PHState private var versions: [Int] = []
    @PHState private var operationError: String?
    @PHState private var confirmDiscard = false
    @PHState private var previewDraft = ""
    @PHState private var previewComposerFocused = false
    @PHState private var previewComposerHeight: CGFloat = 36
    @PHState private var previewSelection = NSRange(location: 0, length: 0)
    @PHState private var previewEdit: ChatEditorEdit?
    @PHState private var previewFocusRequest = 0
    @PHEnvironment(\.colorScheme) private var colorScheme

    package var body: some PHView {
        AtomStack(props: StackProps(axis: "v", spacing: 0, align: "leading")) {
            AtomStack(props: StackProps(axis: "h"), common: AtomCommon(padding: 16)) {
                AtomText(props: TextProps(text: "Preview", textStyle: "headline"))
                AtomSpacer()
                if let plugin { AtomText(props: TextProps(text: "Version \(plugin.version)", color: "secondary")) }
                AtomMenu(
                    props: MenuProps(
                        text: "Restore version",
                        indicator: true, disabled: versions.isEmpty,
                        items: [versions.map { .init(id: String($0), title: "Version \($0)", help: "Restore this plugin version") }],
                        style: "automatic"
                    ),
                    common: AtomCommon(help: "Restore an earlier saved version of this plugin")
                ) { version in
                    if let version = versions.first(where: { String($0) == version }) {
                        perform("plugin.restore", version: version)
                    }
                }
                // A plugin that was never saved is itself unpublished, so it can always be discarded.
                if !isSaved || hasChanges {
                    AtomButton(props: ButtonProps(style: "automatic"), common: AtomCommon(help: isSaved ? "Reset the draft to the published plugin" : "Delete this unsaved plugin and its conversation"), action: { confirmDiscard = true }) { AtomText(props: TextProps(text: "Discard changes")) }
                }
                AtomButton(props: ButtonProps(style: "automatic", disabled: !hasChanges), action: { perform("plugin.save") }) { AtomText(props: TextProps(text: "Publish")) }.shortcutHelp(hasChanges ? "Publish this plugin draft" : "No unpublished changes", shortcut: AppShortcut.save)
            }
            AtomDivider()
            if let plugin, plugin.valid {
                PluginSurfaceView(plugin: plugin, props: PluginContext.props(
                    plugin: plugin, appearance: colorScheme == .dark ? "dark" : "light",
                    task: PluginTaskContext(task: task), composer: PluginComposerContext(draft: previewDraft, selectionLocation: previewSelection.location, selectionLength: previewSelection.length)),
                    actions: PluginUIActions(composer: applyComposerEdit))
                    .id(revision)
                if plugin.placement == PluginPlacement.composerActions.rawValue {
                    AtomStack(common: AtomCommon(height: Double(max(36, previewComposerHeight)), padding: 16)) {
                        PHNativeChatEditor(text: PHBinding(get: { previewDraft }, set: { value in
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
                    }
                }
            } else {
                AtomStack(props: StackProps(axis: "v", spacing: 10), common: AtomCommon(fillWidth: true, fillHeight: true)) {
                    AtomIcon(props: IconProps(name: PHIcon.squareOnSquare.name, textStyle: "largeTitle"))
                    AtomText(props: TextProps(text: "Your plugin preview will appear here", textStyle: "headline"))
                    if let plugin, !plugin.errors.isEmpty {
                        AtomText(props: TextProps(text: plugin.errors.joined(separator: "\n"), color: "secondary", textStyle: "caption"))
                    } else {
                        AtomText(props: TextProps(text: "Describe your plugin in the conversation to get started.", color: "secondary"))
                    }
                }
            }
        }
        .alert(isSaved ? "Discard changes?" : "Discard plugin?", isPresented: $confirmDiscard) {
            PHButton("Discard", role: .destructive) { isSaved ? perform("plugin.discard") : discardUnsaved() }
                .buttonHoverPointer().nativeHelp("Discard the unpublished changes")
            PHButton("Cancel", role: .cancel) { }
                .buttonHoverPointer().nativeHelp("Keep the unpublished changes")
        } message: {
            PHText(isSaved ? "The preview will be reset to the published plugin."
                 : "This plugin was never saved. Its draft and this conversation will be deleted.")
        }
        .alert("Plugin operation", isPresented: PHBinding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
            PHButton("OK") { operationError = nil }
                .buttonHoverPointer().nativeHelp("Dismiss plugin operation message")
        } message: { PHText(operationError ?? "") }
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
                Platform.services.showErrorAlert(error)
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

    package init(task: any ConversationSubject, pluginID: String, onClose: @escaping () -> Void) {
        self.task = task
        self.pluginID = pluginID
        self.onClose = onClose
    }
}
