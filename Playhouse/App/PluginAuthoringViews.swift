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
                    Text("Popover").tag(PluginPresentation.popover)
                    Text("Modal").tag(PluginPresentation.modal)
                    Text("Side panel").tag(PluginPresentation.sidebar)
                    Text("Page").tag(PluginPresentation.page)
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
                    withAnimation { hasName = true }
                }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonHoverPointer().nativeHelp("Choose how the plugin opens")
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
    @State private var plugin: PluginRecord?
    @State private var revision = ""
    @State private var previewDraft = ""
    @State private var previewComposerFocused = false
    @State private var previewComposerHeight: CGFloat = 36
    @State private var previewSelection = NSRange(location: 0, length: 0)
    @State private var previewEdit: ChatEditorEdit?
    @State private var previewFocusRequest = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Preview").font(.headline).padding()
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plugin-creation-preview")
        .task(id: pluginID) {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
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
        let library = PluginLibrary(dataDirectory: URL(fileURLWithPath: folder).deletingLastPathComponent().path)
        let current = try? library.plugin(id: pluginID, validate: false)
        let source = current.flatMap { try? String(contentsOfFile: $0.entryPath, encoding: .utf8) } ?? ""
        let signature = "\(String(describing: current))\n\(source)"
        if signature != revision {
            plugin = current
            revision = signature
        }
    }
}
