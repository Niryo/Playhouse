import AppKit
import Darwin
import Foundation
import OSLog
import SwiftUI

struct WorkspaceSettingsView: View {
    @AppStorage(WorkspaceSettings.defaultParentFolderKey, store: WorkspaceSettings.preferencesStore) private var defaultParentFolderPath = ""
    @State private var appearance = WorkspaceSettings.preferencesStore.string(forKey: WorkspaceSettings.appearanceKey) ?? "dark"
    @State private var tokenUsageColorMax = WorkspaceSettingsManager().tokenUsageColorMax
    @State private var cpuUsageColorMax = WorkspaceSettingsManager().cpuUsageColorMax
    @State private var statusSoundsEnabled = WorkspaceSettingsManager().statusSoundsEnabled
    @State private var autoCompaction = WorkspaceSettingsManager().contextCompaction
    @FocusState private var focusedCompactionField: String?
    @State private var compactionFieldDrafts: [String: String] = [:]
    @State private var pickerError: String?
    @State private var tokenUsageError: String?
    @State private var cpuUsageError: String?

    private var parentFolderURL: URL? {
        WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath)
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: Binding(
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
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                }
                .accessibilityIdentifier("appearance-picker")
                .accessibilityValue(appearance)
                // The Form's first row carries its scroller reveal.
                .hoverRevealScrollers()
            }
            Section("Sounds") {
                Toggle("Play a sound when a task needs attention", isOn: Binding(
                    get: { statusSoundsEnabled },
                    set: { value in
                        WorkspaceSettingsManager().setStatusSoundsEnabled(value)
                        statusSoundsEnabled = value
                    }
                ))
                .accessibilityIdentifier("status-sounds-toggle")
                Text("Plays Glass when a task moves to Review and Ping when it moves to Waiting Response.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Token usage") {
                Text("A task card's dot warms from green to red as the task's token use approaches this total.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text("Red at")
                    TextField("Tokens", value: Binding(
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
                    Text("tokens")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            Section("CPU usage") {
                Text("A running task's left-edge bar warms from green to red as its CPU use approaches this percentage. For Codex tasks, which share one app-server, that's the CPU of commands running in the task's worktree.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text("Red at")
                    TextField("Percent", value: Binding(
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
                    Text("%")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            Section("Context compaction") {
                Toggle("Playhouse compaction triggers", isOn: Binding(
                    get: { autoCompaction.enabled },
                    set: { value in saveCompaction(enabled: value) }
                ))
                .accessibilityIdentifier("auto-compaction-enabled-toggle")
                Text("Claude and Codex always auto-compact a full context themselves, at their own defaults. These triggers add Playhouse's compactions: Claude sessions compact near prompt-cache expiry, on a cold resume and before model switches; Codex sessions compact before model switches, as Codex does not expose the same cache-expiry signal.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                compactionField("Idle wait", value: Binding(
                    get: { autoCompaction.idleMinutes }, set: { saveCompaction(idleMinutes: $0) }
                ), suffix: "minutes", id: "auto-compaction-idle-minutes-field")
                compactionField("Minimum context", value: Binding(
                    get: { autoCompaction.minimumTokens }, set: { saveCompaction(minimumTokens: $0) }
                ), suffix: "tokens", id: "auto-compaction-minimum-field")
            }
            Section("Suggestions from") {
                Text("Choose the folder that holds all of your Git repositories. Playhouse suggests repositories from it, and a task without a repository runs there.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(parentFolderURL?.path ?? "No folder selected")
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .accessibilityLabel(parentFolderURL?.path ?? "No folder selected")
                        .accessibilityIdentifier("default-parent-folder-path")
                    Spacer()
                    Button(parentFolderURL == nil ? "Choose…" : "Change…", action: chooseParentFolder)
                    .buttonHoverPointer()
                        .nativeHelp("Choose the folder Playhouse suggests repositories from")
                        .accessibilityIdentifier("choose-default-parent-folder-button")
                    if parentFolderURL != nil {
                        Button("Clear") {
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
                    Label("This folder is unavailable. Choose another folder.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                    Text("Changing this setting affects suggestions for new tasks. It does not change the working folders saved on existing tasks.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            UpdateSettingsSection()
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
        .preferredColorScheme(appearance == "light" ? .light : .dark)
        .alert("Couldn't choose folder", isPresented: Binding(
            get: { pickerError != nil },
            set: { if !$0 { pickerError = nil } }
        )) {
            Button("OK", role: .cancel) { pickerError = nil }
            .buttonHoverPointer()
            .nativeHelp("Dismiss folder error")
        } message: {
            Text(pickerError ?? "Please try again.")
        }
        .alert("Couldn't save token usage setting", isPresented: Binding(
            get: { tokenUsageError != nil },
            set: { if !$0 { tokenUsageError = nil } }
        )) {
            Button("OK", role: .cancel) { tokenUsageError = nil }
            .buttonHoverPointer()
            .nativeHelp("Dismiss token usage setting error")
        } message: {
            Text(tokenUsageError ?? "Please try again.")
        }
        .alert("Couldn't save CPU usage setting", isPresented: Binding(
            get: { cpuUsageError != nil },
            set: { if !$0 { cpuUsageError = nil } }
        )) {
            Button("OK", role: .cancel) { cpuUsageError = nil }
            .buttonHoverPointer()
            .nativeHelp("Dismiss CPU usage setting error")
        } message: {
            Text(cpuUsageError ?? "Please try again.")
        }
        .alert("Couldn't save context compaction setting", isPresented: Binding(
            get: { compactionError != nil }, set: { if !$0 { compactionError = nil } }
        )) {
            Button("OK", role: .cancel) { compactionError = nil }
            .buttonHoverPointer()
            .nativeHelp("Dismiss context compaction setting error")
        } message: { Text(compactionError ?? "Please try again.") }
    }

    @State private var compactionError: String?

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

    private func compactionField(_ label: String, value: Binding<Int>, suffix: String, id: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
            TextField(label, text: Binding(
                get: { compactionFieldDrafts[id] ?? value.wrappedValue.formatted(.number) },
                set: { compactionFieldDrafts[id] = $0 }
            ))
                .textFieldStyle(.roundedBorder).frame(width: 120)
                .focused($focusedCompactionField, equals: id)
                .onSubmit { commitCompactionField(id) }
                .accessibilityIdentifier(id)
            Text(suffix).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func chooseParentFolder() {
        let panel = SuggestionsFolderPrompt.makePanel(startingAt: parentFolderURL)
        panel.begin { response in
            guard response == .OK, let selected = panel.url else { return }
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
}

/// The folder Playhouse suggests repositories from, asked for in a modal: at launch while none
/// is set, and when a send needs one (a task with no repository runs in that folder).
enum SuggestionsFolderPrompt {
    static let notification = Notification.Name("playhouseShowSuggestionsFolderPrompt")

    static func request() {
        NotificationCenter.default.post(name: notification, object: nil)
    }

    /// The folder panel the prompt, Settings and the repository picker open.
    static func makePanel(startingAt directory: URL?) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Suggestions from"
        panel.message = "Choose the folder that holds your Git repositories. Playhouse suggests repositories from it."
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory ?? FileManager.default.homeDirectoryForCurrentUser
        return panel
    }
}

/// Presents the Suggestions from modal over the main window. Composed of plugin atoms.
struct SuggestionsFolderPromptModifier: ViewModifier {
    /// Whether the window shows the board yet; the launch prompt waits for it.
    let isReady: Bool
    @AppStorage(WorkspaceSettings.defaultParentFolderKey, store: WorkspaceSettings.preferencesStore) private var defaultParentFolderPath = ""
    @State private var isPresented = false
    @State private var hasPromptedAtLaunch = false
    @State private var error: String?

    private var hasFolder: Bool { WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath) != nil }

    func body(content: Content) -> some View {
        content
            .atomModal(
                ModalProps(isPresented: isPresented, width: 440, title: "Where do your repositories live?", icon: "folder.badge.gearshape"),
                common: AtomCommon(testID: "suggestions-folder-prompt"),
                onDismiss: { isPresented = false }
            ) {
                AtomText(
                    props: TextProps(text: "Choose the folder that holds all of your Git repositories, so Playhouse can suggest repositories from there. You can change it later in Settings."),
                    common: AtomCommon(testID: "suggestions-folder-prompt-message", fillWidth: true)
                )
                if let error {
                    AtomLabel(props: LabelProps(text: error, icon: "exclamationmark.triangle.fill", size: 11, weight: "medium", color: "red"))
                }
                AtomStack(props: StackProps(axis: "h")) {
                    AtomSpacer()
                    AtomButton(
                        props: ButtonProps(style: "automatic", shortcut: "cancel"),
                        common: AtomCommon(testID: "suggestions-folder-prompt-later-button", help: "Choose a folder later"),
                        action: { isPresented = false }
                    ) {
                        AtomText(props: TextProps(text: "Not Now"))
                    }
                    AtomButton(
                        props: ButtonProps(style: "prominent", shortcut: "default"),
                        common: AtomCommon(testID: "suggestions-folder-prompt-choose-button", help: "Choose the folder that holds your repositories"),
                        action: chooseFolder
                    ) {
                        AtomText(props: TextProps(text: "Choose Folder…"))
                    }
                }
            }
            .onChange(of: isReady, initial: true) { _, ready in
                guard ready, !hasPromptedAtLaunch else { return }
                hasPromptedAtLaunch = true
                if !hasFolder { isPresented = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: SuggestionsFolderPrompt.notification)) { _ in
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
            let panel = SuggestionsFolderPrompt.makePanel(startingAt: nil)
            panel.begin { response in
                DispatchQueue.main.async {
                    guard response == .OK, let selected = panel.url else {
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
}
