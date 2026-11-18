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
            Section("Repository root") {
                Text("Choose the root folder that contains your repositories. Playhouse searches below it for repository suggestions, and a valid root is required before sending a conversation.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(parentFolderURL?.path ?? "No default parent folder selected")
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .accessibilityLabel(parentFolderURL?.path ?? "No default parent folder selected")
                        .accessibilityIdentifier("default-parent-folder-path")
                    Spacer()
                    Button(parentFolderURL == nil ? "Choose…" : "Change…", action: chooseParentFolder)
                    .buttonHoverPointer()
                        .nativeHelp("Choose repository root folder")
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
                        .nativeHelp("Clear repository root folder")
                        .accessibilityIdentifier("clear-default-parent-folder-button")
                    }
                }
                if !defaultParentFolderPath.isEmpty && parentFolderURL == nil {
                    Label("This folder is unavailable. Choose another parent folder.", systemImage: "exclamationmark.triangle.fill")
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
        let panel = NSOpenPanel()
        panel.title = "Choose repository root folder"
        panel.message = "Playhouse will search below this folder for repositories. A root folder is required before sending conversations."
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = parentFolderURL ?? FileManager.default.homeDirectoryForCurrentUser
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
