import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

package struct WorkspaceSettingsView: PHView {
    @PHAppStorage(WorkspaceSettings.defaultParentFolderKey, store: WorkspaceSettings.preferencesStore) private var defaultParentFolderPath = ""
    @PHState private var appearance = WorkspaceSettings.preferencesStore.string(forKey: WorkspaceSettings.appearanceKey) ?? "dark"
    @PHState private var tokenUsageColorMax = WorkspaceSettingsManager().tokenUsageColorMax
    @PHState private var cpuUsageColorMax = WorkspaceSettingsManager().cpuUsageColorMax
    @PHState private var statusSoundsEnabled = WorkspaceSettingsManager().statusSoundsEnabled
    @PHState private var autoCompaction = WorkspaceSettingsManager().contextCompaction
    @PHFocusState private var focusedCompactionField: String?
    @PHState private var compactionFieldDrafts: [String: String] = [:]
    @PHState private var pickerError: String?
    @PHState private var tokenUsageError: String?
    @PHState private var cpuUsageError: String?

    private var parentFolderURL: URL? {
        WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath)
    }

    package var body: some PHView {
        PHTabView {
            general
                .tabItem { PHLabel("General", icon: .gearshape) }
            SystemPromptsSettingsView()
                .tabItem { PHLabel("System Prompts", icon: .textBubble) }
        }
        .preferredColorScheme(appearance == "light" ? .light : .dark)
    }

    private var general: some PHView {
        PHForm {
            PHSection("Appearance") {
                PHPicker("Theme", selection: PHBinding(
                    get: { appearance },
                    set: { value in
                        do {
                            try WorkspaceSettingsManager().setAppearance(value)
                            appearance = value
                        } catch {
                            pickerError = error.localizedDescription
                        }
                    }
                )) {
                    PHText("Dark").tag("dark")
                    PHText("Light").tag("light")
                }
                .buttonHoverPointer()
                .accessibilityIdentifier("appearance-picker")
                .accessibilityValue(appearance)
                // The Form's first row carries its scroller reveal.
                .hoverRevealScrollers()
            }
            PHSection("Sounds") {
                PHToggle("Play a sound when a task needs attention", isOn: PHBinding(
                    get: { statusSoundsEnabled },
                    set: { value in
                        WorkspaceSettingsManager().setStatusSoundsEnabled(value)
                        statusSoundsEnabled = value
                    }
                ))
                .buttonHoverPointer()
                .accessibilityIdentifier("status-sounds-toggle")
                PHText("Plays Glass when a task moves to Review and Ping when it moves to Waiting Response.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PHSection("Token usage") {
                PHText("A task card's dot warms from green to red as the task's token use approaches this total.")
                    .fixedSize(horizontal: false, vertical: true)
                PHHStack(spacing: 10) {
                    PHText("Red at")
                    PHTextField("Tokens", value: PHBinding(
                        get: { tokenUsageColorMax },
                        set: { value in
                            do {
                                try WorkspaceSettingsManager().setTokenUsageColorMax(value)
                                tokenUsageColorMax = value
                            } catch {
                                tokenUsageError = error.localizedDescription
                            }
                        }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .accessibilityIdentifier("token-usage-color-max-field")
                    PHText("tokens")
                        .foregroundStyle(.secondary)
                    PHSpacer()
                }
            }
            PHSection("CPU usage") {
                PHText("A running task's left-edge bar warms from green to red as its CPU use approaches this percentage. For Codex tasks, which share one app-server, that's the CPU of commands running in the task's worktree.")
                    .fixedSize(horizontal: false, vertical: true)
                PHHStack(spacing: 10) {
                    PHText("Red at")
                    PHTextField("Percent", value: PHBinding(
                        get: { cpuUsageColorMax },
                        set: { value in
                            do {
                                try WorkspaceSettingsManager().setCPUUsageColorMax(value)
                                cpuUsageColorMax = value
                            } catch {
                                cpuUsageError = error.localizedDescription
                            }
                        }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .accessibilityIdentifier("cpu-usage-color-max-field")
                    PHText("%")
                        .foregroundStyle(.secondary)
                    PHSpacer()
                }
            }
            PHSection("Context compaction") {
                PHToggle("Playhouse compaction triggers", isOn: PHBinding(
                    get: { autoCompaction.enabled },
                    set: { value in saveCompaction(enabled: value) }
                ))
                .buttonHoverPointer()
                .accessibilityIdentifier("auto-compaction-enabled-toggle")
                PHText("Claude and Codex always auto-compact a full context themselves, at their own defaults. These triggers add Playhouse's compactions: Claude sessions compact near prompt-cache expiry, on a cold resume and before model switches; Codex sessions compact before model switches, as Codex does not expose the same cache-expiry signal.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                compactionField("Idle wait", value: PHBinding(
                    get: { autoCompaction.idleMinutes }, set: { saveCompaction(idleMinutes: $0) }
                ), suffix: "minutes", id: "auto-compaction-idle-minutes-field")
                compactionField("Minimum context", value: PHBinding(
                    get: { autoCompaction.minimumTokens }, set: { saveCompaction(minimumTokens: $0) }
                ), suffix: "tokens", id: "auto-compaction-minimum-field")
            }
            PHSection("Suggestions from") {
                PHText("Choose the folder that holds all of your Git repositories. Playhouse suggests repositories from it, and a task without a repository runs there.")
                    .fixedSize(horizontal: false, vertical: true)
                PHHStack(spacing: 10) {
                    PHImage(icon: .folder)
                        .foregroundStyle(.secondary)
                    PHText(parentFolderURL?.path ?? "No folder selected")
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .accessibilityLabel(parentFolderURL?.path ?? "No folder selected")
                        .accessibilityIdentifier("default-parent-folder-path")
                    PHSpacer()
                    PHButton(parentFolderURL == nil ? "Choose…" : "Change…", action: chooseParentFolder)
                    .buttonHoverPointer()
                        .nativeHelp("Choose the folder Playhouse suggests repositories from")
                        .accessibilityIdentifier("choose-default-parent-folder-button")
                    if parentFolderURL != nil {
                        PHButton("Clear") {
                            do {
                                try WorkspaceSettingsManager().setDefaultParentFolder(nil)
                                defaultParentFolderPath = ""
                            } catch {
                                pickerError = error.localizedDescription
                            }
                        }
                        .buttonHoverPointer()
                        .nativeHelp("Clear the folder Playhouse suggests repositories from")
                        .accessibilityIdentifier("clear-default-parent-folder-button")
                    }
                }
                if !defaultParentFolderPath.isEmpty && parentFolderURL == nil {
                    PHLabel("This folder is unavailable. Choose another folder.", icon: .exclamationmarkTriangleFill)
                        .foregroundStyle(.orange)
                }
            }
            PHSection {
                    PHText("Changing this setting affects suggestions for new tasks. It does not change the working folders saved on existing tasks.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            NativeViews.factory.settingsSection()
        }
        .task {
            while !Task.isCancelled {
                let preferences = WorkspaceSettings.preferencesStore
                preferences.synchronize()
                if let updatedAppearance = preferences.string(forKey: WorkspaceSettings.appearanceKey),
                   updatedAppearance != appearance {
                    appearance = updatedAppearance
                }
                let updatedMax = WorkspaceSettingsManager().tokenUsageColorMax
                if updatedMax != tokenUsageColorMax { tokenUsageColorMax = updatedMax }
                let updatedCPUMax = WorkspaceSettingsManager().cpuUsageColorMax
                if updatedCPUMax != cpuUsageColorMax { cpuUsageColorMax = updatedCPUMax }
                let updatedSounds = WorkspaceSettingsManager().statusSoundsEnabled
                if updatedSounds != statusSoundsEnabled { statusSoundsEnabled = updatedSounds }
                if focusedCompactionField == nil {
                    let updatedCompaction = WorkspaceSettingsManager().contextCompaction
                    if updatedCompaction != autoCompaction { autoCompaction = updatedCompaction }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        .onChange(of: focusedCompactionField) { previous, current in
            guard let previous, previous != current else { return }
            commitCompactionField(previous)
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 420)
        .alert("Couldn't choose folder", isPresented: PHBinding(
            get: { pickerError != nil },
            set: { if !$0 { pickerError = nil } }
        )) {
            PHButton("OK", role: .cancel) { pickerError = nil }
            .buttonHoverPointer()
            .nativeHelp("Dismiss folder error")
        } message: {
            PHText(pickerError ?? "Please try again.")
        }
        .alert("Couldn't save token usage setting", isPresented: PHBinding(
            get: { tokenUsageError != nil },
            set: { if !$0 { tokenUsageError = nil } }
        )) {
            PHButton("OK", role: .cancel) { tokenUsageError = nil }
            .buttonHoverPointer()
            .nativeHelp("Dismiss token usage setting error")
        } message: {
            PHText(tokenUsageError ?? "Please try again.")
        }
        .alert("Couldn't save CPU usage setting", isPresented: PHBinding(
            get: { cpuUsageError != nil },
            set: { if !$0 { cpuUsageError = nil } }
        )) {
            PHButton("OK", role: .cancel) { cpuUsageError = nil }
            .buttonHoverPointer()
            .nativeHelp("Dismiss CPU usage setting error")
        } message: {
            PHText(cpuUsageError ?? "Please try again.")
        }
        .alert("Couldn't save context compaction setting", isPresented: PHBinding(
            get: { compactionError != nil }, set: { if !$0 { compactionError = nil } }
        )) {
            PHButton("OK", role: .cancel) { compactionError = nil }
            .buttonHoverPointer()
            .nativeHelp("Dismiss context compaction setting error")
        } message: { PHText(compactionError ?? "Please try again.") }
    }

    @PHState private var compactionError: String?

    private func saveCompaction(enabled: Bool? = nil, idleMinutes: Int? = nil, minimumTokens: Int? = nil) {
        do {
            try WorkspaceSettingsManager().setContextCompaction(enabled: enabled, idleMinutes: idleMinutes, minimumTokens: minimumTokens)
            autoCompaction = WorkspaceSettingsManager().contextCompaction
            compactionError = nil
        } catch { compactionError = error.localizedDescription }
    }

    private func commitCompactionField(_ id: String) {
        guard let draft = compactionFieldDrafts.removeValue(forKey: id) else { return }
        guard let value = ContextCompactionSettings.parseInteger(draft) else {
            compactionError = "Enter a whole number."
            return
        }
        // Focus leaving a field the user did not change must not save the shown
        // value, which can be stale while the field is focused and overwrite a
        // value saved elsewhere (the CLI) in the meantime.
        let shown = id == "auto-compaction-idle-minutes-field" ? autoCompaction.idleMinutes : autoCompaction.minimumTokens
        guard draft != shown.formatted(.number) else {
            autoCompaction = WorkspaceSettingsManager().contextCompaction
            return
        }
        switch id {
        case "auto-compaction-idle-minutes-field": saveCompaction(idleMinutes: value)
        case "auto-compaction-minimum-field": saveCompaction(minimumTokens: value)
        default: break
        }
    }

    private func compactionField(_ label: String, value: PHBinding<Int>, suffix: String, id: String) -> some PHView {
        PHHStack(spacing: 10) {
            PHText(label)
            PHTextField(label, text: PHBinding(
                get: { compactionFieldDrafts[id] ?? value.wrappedValue.formatted(.number) },
                set: { compactionFieldDrafts[id] = $0 }
            ))
                .textFieldStyle(.roundedBorder).frame(width: 120)
                .focused($focusedCompactionField, equals: id)
                .onSubmit { commitCompactionField(id) }
                .accessibilityIdentifier(id)
            PHText(suffix).foregroundStyle(.secondary)
            PHSpacer()
        }
    }

    private func chooseParentFolder() {
        SuggestionsFolderPrompt.chooseFolder(startingAt: parentFolderURL) { selected in
            guard let selected else { return }
            DispatchQueue.main.async {
                let path = selected.standardizedFileURL.path
                do {
                    try WorkspaceSettingsManager().setDefaultParentFolder(path)
                    defaultParentFolderPath = path
                } catch {
                    pickerError = error.localizedDescription
                }
            }
        }
    }

    package init() {}
}

/// Settings > System Prompts: the prompts Playhouse sends on its own that the user can
/// rewrite. Each edit goes through `WorkspaceSettingsManager`, the same code the CLI's
/// `settings set-prompt` and `settings reset-prompt` reach.
package struct SystemPromptsSettingsView: PHView {
    @PHState private var saved = Self.load()
    @PHState private var drafts: [SystemPromptKind: String] = [:]
    @PHState private var saveError: String?

    private static func load() -> [SystemPromptKind: SavedPrompt] {
        let manager = WorkspaceSettingsManager()
        return Dictionary(uniqueKeysWithValues: SystemPromptKind.allCases.map { kind in
            let prompt = manager.systemPrompt(kind)
            return (kind, SavedPrompt(text: prompt.text, isCustom: prompt.isCustom))
        })
    }

    package struct SavedPrompt: Equatable {
        package var text: String
        package var isCustom: Bool

        package init(text: String, isCustom: Bool) {
            self.text = text
            self.isCustom = isCustom
        }
    }

    package var body: some PHView {
        PHForm {
            PHSection {
                PHText("Change how the agent writes these. Playhouse still adds what each flow needs, such as the task's conversation or its Git and outcome rules, so a changed prompt can't break the flow.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // The Form's first row carries its scroller reveal.
                    .hoverRevealScrollers()
            }
            PHForEach(SystemPromptKind.allCases, id: \.self) { kind in
                promptSection(kind)
            }
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 420)
        .task {
            // Follows changes made through the CLI; an edit in progress keeps its draft.
            while !Task.isCancelled {
                WorkspaceSettings.preferencesStore.synchronize()
                let latest = Self.load()
                if latest != saved {
                    for (kind, prompt) in latest where drafts[kind] == saved[kind]?.text {
                        drafts[kind] = prompt.text
                    }
                    saved = latest
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        .alert("Couldn't save system prompt", isPresented: PHBinding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) {
            PHButton("OK", role: .cancel) { saveError = nil }
            .buttonHoverPointer()
            .nativeHelp("Dismiss system prompt error")
        } message: { PHText(saveError ?? "Please try again.") }
    }

    private func promptSection(_ kind: SystemPromptKind) -> some PHView {
        let stored = saved[kind] ?? SavedPrompt(text: kind.defaultText, isCustom: false)
        let draft = drafts[kind] ?? stored.text
        return PHSection {
            PHText(kind.usage)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PHNativeTextEditor(
                text: PHBinding(get: { drafts[kind] ?? stored.text }, set: { drafts[kind] = $0 }),
                identifier: "system-prompt-editor-\(kind.rawValue)"
            )
            .frame(height: kind == .greenFix ? 150 : 90)
            PHHStack(spacing: 10) {
                PHText(stored.isCustom ? "Custom" : "Default")
                    .font(.system(size: 12)).foregroundStyle(stored.isCustom ? PHColor.accentColor : .secondary)
                    .accessibilityIdentifier("system-prompt-status-\(kind.rawValue)")
                PHSpacer()
                PHButton("Reset to Default") {
                    WorkspaceSettingsManager().resetSystemPrompt(kind)
                    drafts[kind] = kind.defaultText
                    saved = Self.load()
                }
                .buttonHoverPointer()
                .nativeHelp("Go back to Playhouse's default \(kind.title.lowercased()) prompt")
                .disabled(!stored.isCustom && draft == kind.defaultText)
                .accessibilityIdentifier("system-prompt-reset-\(kind.rawValue)")
                PHButton("Save") {
                    do {
                        try WorkspaceSettingsManager().setSystemPrompt(kind, text: draft)
                        saved = Self.load()
                        drafts[kind] = saved[kind]?.text
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
                .buttonHoverPointer()
                .nativeHelp("Save the \(kind.title.lowercased()) prompt")
                .disabled(draft == stored.text)
                .accessibilityIdentifier("system-prompt-save-\(kind.rawValue)")
            }
        } header: {
            PHText(kind.title)
        }
    }

    package init() {}
}

/// The folder Playhouse suggests repositories from, asked for in a modal: at launch while none
/// is set, and when a send needs one (a task with no repository runs in that folder). The
/// modal can't be dismissed; it stays until a folder is chosen.
package enum SuggestionsFolderPrompt {
    package static let notification = Notification.Name("playhouseShowSuggestionsFolderPrompt")

    package static func request() {
        NotificationCenter.default.post(name: notification, object: nil)
    }

    /// The folder panel the prompt, Settings and the repository picker open. `completion` gets
    /// the chosen folder, nil when cancelled.
    @discardableResult
    package static func chooseFolder(startingAt directory: URL?, completion: @escaping (URL?) -> Void) -> any FileChooserPanel {
        Platform.services.chooseFiles(FileChooserRequest(
            title: "Suggestions from",
            message: "Choose the folder that holds your Git repositories. Playhouse suggests repositories from it.",
            prompt: "Use This Folder", choosesFiles: false, choosesDirectories: true, allowsMultipleSelection: false,
            startingDirectory: directory ?? FileManager.default.homeDirectoryForCurrentUser
        )) { urls in completion(urls?.first) }
    }
}

/// Presents the Suggestions from modal over the main window. Composed of plugin atoms.
package struct SuggestionsFolderPromptModifier: PHViewModifier {
    /// Whether the window shows the board yet; the launch prompt waits for it.
    package let isReady: Bool
    @PHAppStorage(WorkspaceSettings.defaultParentFolderKey, store: WorkspaceSettings.preferencesStore) private var defaultParentFolderPath = ""
    @PHState private var isPresented = false
    @PHState private var hasPromptedAtLaunch = false
    @PHState private var error: String?

    private var hasFolder: Bool { WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath) != nil }

    package func body(content: Content) -> some PHView {
        content
            // The modal hangs off an empty background rather than the window's content: an atom's
            // base is rebuilt when Debug ▸ Highlight Native Atoms toggles, which would drop the
            // board's state, such as the open task.
            .background {
                PHColor.clear.atomModal(
                    ModalProps(isPresented: isPresented, width: 440, title: "Where do your repositories live?", icon: PHIcon.folderBadgeGearshape.name, dismissible: false),
                    common: AtomCommon(testID: "suggestions-folder-prompt"),
                    onDismiss: { isPresented = false }
                ) {
                    AtomText(
                        props: TextProps(text: "Choose the folder that holds all of your Git repositories, so Playhouse can suggest repositories from there. You can change it later in Settings."),
                        common: AtomCommon(testID: "suggestions-folder-prompt-message", fillWidth: true)
                    )
                    if let error {
                        AtomLabel(props: LabelProps(text: error, icon: PHIcon.exclamationmarkTriangleFill.name, size: 11, weight: "medium", color: "red"))
                    }
                    AtomStack(props: StackProps(axis: "h")) {
                        AtomSpacer()
                        AtomButton(
                            props: ButtonProps(style: "prominent", shortcut: "default"),
                            common: AtomCommon(testID: "suggestions-folder-prompt-choose-button", help: "Choose the folder that holds your repositories"),
                            action: chooseFolder
                        ) {
                            AtomText(props: TextProps(text: "Choose Folder…"))
                        }
                    }
                }
            }
            .onChange(of: isReady, initial: true) { _, ready in
                guard ready, !hasPromptedAtLaunch else { return }
                hasPromptedAtLaunch = true
                if !hasFolder { isPresented = true }
            }
            .onNotification(SuggestionsFolderPrompt.notification) { _ in
                if !hasFolder {
                    error = nil
                    isPresented = true
                }
            }
    }

    /// The modal is a sheet, so it closes before the folder panel opens and comes back if the
    /// panel is cancelled.
    private func chooseFolder() {
        isPresented = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            SuggestionsFolderPrompt.chooseFolder(startingAt: nil) { selected in
                DispatchQueue.main.async {
                    guard let selected else {
                        isPresented = true
                        return
                    }
                    let path = selected.standardizedFileURL.path
                    do {
                        try WorkspaceSettingsManager().setDefaultParentFolder(path)
                        defaultParentFolderPath = path
                        error = nil
                    } catch {
                        self.error = "Couldn't use that folder: \(error.localizedDescription)"
                        isPresented = true
                    }
                }
            }
        }
    }

    package init(isReady: Bool) {
        self.isReady = isReady
    }
}
