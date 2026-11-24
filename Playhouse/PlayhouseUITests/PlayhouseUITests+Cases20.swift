import AppKit
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import Network
import XCTest
import SQLite3
import Vision

extension PlayhouseUITests {
    // case-contract: test_codex_legacy_keyed_server_retires_after_restart | A Codex app-server started under the earlier shared-client key, which also held two goal flags, is retired by the next daemon. When its daemon dies and a fresh daemon starts for the data folder, it reconnects to the legacy server only to retire it: with no turn left to follow, the server is stopped and its manifest removed, and the next Codex send, from the CLI or, in the UI, from the window, runs on one new server under the current key (executable, Codex home, data folder), leaving one live Codex server.
    func test_codex_legacy_keyed_server_retires_after_restart() throws {
        let fixtureName = "codex-fixture-single-server-goal-success"
        codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent(fixtureName).path
        let stateDirectory = dataDirectory.appendingPathComponent("legacy-server-fixture-state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        codexFixtureStateDirectory = stateDirectory
        let codexHome = dataDirectory.appendingPathComponent("codex-home").path
        try FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
        var environment = restartServiceEnvironment()
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Legacy Codex server", "--prompt", Self.fixtureTaskPrompt, "--root", fixture.primary.path, "--provider", "codex",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        // The window's private daemon starts the server under the current key.
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        openTask(named: "Legacy Codex server")
        sendFromComposer("Before the upgrade.")
        XCTAssertTrue(transcriptMessage("Before the upgrade.").waitToExist(timeout: 15))
        XCTAssertTrue(waitUntil({ !self.element("pause-response-button").exists }, timeout: 30), "The window's first turn should finish.")
        let (path, manifest) = try XCTUnwrap(agentManifest(kind: "codex", service: environment))
        let parts = try XCTUnwrap(manifest["keyParts"] as? [String])
        XCTAssertEqual(parts.count, 3, "A current server's key is its executable, Codex home and data folder.")
        let legacyServer = try XCTUnwrap(manifest["process"] as? [String: Any])
        XCTAssertTrue(terminateAppAndWait(app))
        try killDaemon(environment: environment)
        XCTAssertTrue(agentIsAlive(legacyServer), "The server outlives its daemon.")

        // Rename the manifest to the key a server started before one app-server served every
        // caller had: it also held the goal-feature and goal-runtime flags.
        let service = try XCTUnwrap(manifest["serviceName"] as? String)
        let oldHash = try XCTUnwrap(manifest["keyHash"] as? String)
        let legacyParts = [parts[0], codexHome, "false", "false", parts[2]]
        let legacyHash = SHA256.hash(data: Data((legacyParts + [service]).joined(separator: "\u{1}").utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        let runs = path.deletingLastPathComponent()
        try FileManager.default.moveItem(at: runs.appendingPathComponent("\(oldHash).log"), to: runs.appendingPathComponent("\(legacyHash).log"))
        try? FileManager.default.removeItem(at: runs.appendingPathComponent("\(oldHash).owner.lock"))
        try FileManager.default.removeItem(at: path)
        var legacy = manifest
        legacy["keyHash"] = legacyHash
        legacy["keyParts"] = legacyParts
        let legacyPath = runs.appendingPathComponent("\(legacyHash).json")
        try JSONSerialization.data(withJSONObject: legacy).write(to: legacyPath)

        // The window's first requests start a fresh daemon, which retires the legacy server. With
        // a 30s idle limit the watch checks every 7.5s: only retiring stops the server in time.
        environment["PLAYHOUSE_E2E_CODEX_SERVER_IDLE_SECONDS"] = "30"
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        XCTAssertTrue(waitUntil({ !self.agentIsAlive(legacyServer) }, timeout: 20), "The legacy-keyed server is retired once idle.")
        XCTAssertTrue(waitUntil({ !FileManager.default.fileExists(atPath: legacyPath.path) }, timeout: 10), "The retired server's manifest is removed.")

        openTask(named: "Legacy Codex server")
        sendFromComposer("After the upgrade.")
        XCTAssertTrue(transcriptMessage("After the upgrade.").waitToExist(timeout: 15))
        XCTAssertTrue(waitUntil({ !self.element("pause-response-button").exists }, timeout: 30), "The window's send should finish on the new server.")
        XCTAssertFalse(element("codex-chat-error").exists, "The send on the new server succeeds.")
        XCTAssertTrue(try historyTexts(taskID: taskID, environment: environment).contains("After the upgrade."), "The new server holds the conversation.")
        let live = agentManifests().filter {
            $0.kind == "codex" && $0.manifest["serviceName"] as? String == service && agentIsAlive($0.manifest["process"] as? [String: Any])
        }
        XCTAssertEqual(live.count, 1, "One live Codex server remains: \(live.map(\.manifest))")
        XCTAssertEqual((live.first?.manifest["keyParts"] as? [String])?.count, 3, "The new server uses the current key.")
        let newPID = try XCTUnwrap(((live.first?.manifest["process"] as? [String: Any])?["pid"] as? NSNumber)?.intValue)
        XCTAssertNotEqual(newPID, (legacyServer["pid"] as? NSNumber)?.intValue)
        let records = jsonLines(stateDirectory.appendingPathComponent("\(fixtureName).app-servers").path).compactMap { $0 as? [String: Any] }
        let socketServers = Set(records.filter { ($0["listen"] as? String)?.hasPrefix("unix://") == true }.compactMap { $0["pid"] as? Int })
        let running = records.filter {
            (($0["listen"] as? String)?.hasPrefix("unix://") == true || !socketServers.contains($0["parentPID"] as? Int ?? -1))
                && ($0["pid"] as? Int).map { $0 > 0 && kill(pid_t($0), 0) == 0 } == true
        }
        XCTAssertEqual(running.compactMap { $0["pid"] as? Int }, [newPID], "One app-server runs on the Codex home.")
        attachScreenshot(named: "legacy-codex-server-retired-window-send-on-new-server")
    }
    // case-contract: test_conversation_models_keep_newest_version_per_family | The model picker removes the Default entry, superseded aliases, older versions, and duplicate snapshots, keeping only the newest concrete version in each family. GPT-6 Luna replaces GPT-5.6 Luna, and Claude Opus 5.5 replaces the Opus alias and older snapshots. Claude Code names its newest release only through an alias entry's resolved model, so that resolved version supersedes the older concrete Opus 5 and keeps Claude Code's own display name. Alias entries with no resolved model are omitted. A remembered selection the filtered list no longer offers moves to its family's newest offered model and is written back, surviving a later refresh whose list no longer offers that family, while a still-offered selection is left alone. A cached intermediate version advances again when live discovery returns a newer version, and the picker and persisted selection converge. A remembered bare alias migrates to its family's offered release, but a dated snapshot pinned through the CLI is left in place because its family's undated release is not a higher version. The shared CLI/XPC list applies the same filtering to Codex and Claude, and the visible picker matches the Codex list. The model popover opens above its composer control.
    func test_conversation_models_keep_newest_version_per_family() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Model versions", roots: [fixture.primary.path])
        openTask(named: "Model versions")

        let taskID = try taskID(named: "Model versions")
        let modelResult = try runCLI(["conversation", "models", taskID])["result"] as? [String: Any]
        let cliModelIDs = try XCTUnwrap(modelResult?["models"] as? [[String: Any]]).compactMap { $0["id"] as? String }
        XCTAssertFalse(cliModelIDs.contains("gpt-5.6-luna"), "The CLI model list should omit the superseded GPT-5.6 Luna model.")
        XCTAssertFalse(cliModelIDs.contains("default"), "The default pseudo-model should not appear in the selectable list.")

        let modelPicker = element("model-picker-menu")
        XCTAssertTrue(modelPicker.waitToExist(timeout: 5), "The composer should expose the model picker.")
        modelPicker.click()
        let optionIDs = { self.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "model-option-")).allElementsBoundByIndex.compactMap(\.identifier) }
        XCTAssertTrue(waitUntil({
            Set(optionIDs()) == Set(cliModelIDs.map { "model-option-\($0)" })
        }, timeout: 5), "The picker should list exactly the CLI model list: \(cliModelIDs).")
        XCTAssertLessThan(app.buttons["model-option-gpt-6-luna"].frame.midY, modelPicker.frame.minY,
            "The model popover should appear above the composer control.")
        XCTAssertTrue(app.buttons["model-option-gpt-6-luna"].exists, "The newer GPT-6 Luna model should remain in the picker.")
        XCTAssertTrue(app.buttons["model-option-gpt-6-sol"].exists, "Other families should remain in the picker.")
        XCTAssertTrue(app.buttons["model-option-gpt-6-mini"].exists, "Other families should remain in the picker.")
        XCTAssertFalse(app.buttons["model-option-gpt-5.6-luna"].exists, "The older GPT-5.6 Luna model should be hidden from the picker.")
        XCTAssertFalse(app.buttons["model-option-default"].exists, "The default pseudo-model should not appear in the picker.")
        modelPicker.click()

        // A remembered model the filtered list no longer offers follows its family
        // forward, so the composer and the next send agree on one model. The Sol family
        // is used deliberately: GPT-6 Luna is the fixture's default model, so a composer
        // that had not yet loaded a selection would display it and hide a regression.
        XCTAssertNotNil(try runCLI(["conversation", "model", taskID, "set", "gpt-5.6-sol"])["result"],
            "Seeding the superseded selection should succeed.")
        let codexFixturePath = try XCTUnwrap(codexFixtureExecutable)
        let liveModelsOverride = URL(fileURLWithPath: codexFixturePath + ".models-override")
        let liveModelsDelay = URL(fileURLWithPath: codexFixturePath + ".models-delay")
        try JSONSerialization.data(withJSONObject: [
            ["id": "gpt-6-luna", "displayName": "GPT-6 Luna", "isDefault": true,
             "supportedReasoningEfforts": ["low", "medium", "high", "xhigh"]],
            ["id": "gpt-7-sol", "displayName": "GPT-7 Sol", "isDefault": false,
             "supportedReasoningEfforts": ["low", "medium", "high", "xhigh"]],
            ["id": "gpt-6-mini", "displayName": "GPT-6 Mini", "isDefault": false,
             "supportedReasoningEfforts": ["low", "medium"]],
        ]).write(to: liveModelsOverride, options: .atomic)
        try Data().write(to: liveModelsDelay, options: .atomic)
        openTask(named: "Model versions")
        XCTAssertTrue(waitUntil({ modelPicker.label.contains("GPT-6 Sol") }, timeout: 5),
            "The cached catalog should first advance the superseded selection to GPT-6 Sol.")
        try FileManager.default.removeItem(at: liveModelsDelay)
        XCTAssertTrue(waitUntil({ modelPicker.label.contains("GPT-7 Sol") }, timeout: 10),
            "The composer should follow the live catalog from cached GPT-6 Sol to newer GPT-7 Sol.")
        attachElementScreenshot(modelPicker, named: "Composer advances from cached GPT-6 Sol to live GPT-7 Sol")
        attachScreenshot(named: "Composer follows the live catalog to GPT-7 Sol")
        XCTAssertEqual(
            (try runCLI(["conversation", "model", taskID])["result"] as? [String: Any])?["modelID"] as? String, "gpt-7-sol",
            "The bridge should report the same forwarded model the composer shows.")
        try FileManager.default.removeItem(at: liveModelsOverride)

        let claudeExecutable = WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui")
        let aliasesExecutable = WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui-aliases-only")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: claudeExecutable.path))
        try? FileManager.default.removeItem(at: aliasesExecutable)
        try copyFixtureFile(at: claudeExecutable, to: aliasesExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: aliasesExecutable.path)
        app.terminate()
        claudeFixtureExecutable = aliasesExecutable.path
        launchApp(defaultParent: fixture.parent.path)
        let claudeTask = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Alias-only Claude models", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude"
        ])["result"] as? [String: Any])
        let claudeTaskID = try XCTUnwrap(claudeTask["id"] as? String)
        openTask(named: "Alias-only Claude models")
        let claudeModels = try XCTUnwrap(try runCLI(
            ["conversation", "models", claudeTaskID],
            extraEnvironment: ["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": aliasesExecutable.path]
        )["result"] as? [String: Any])
        XCTAssertTrue((claudeModels["models"] as? [[String: Any]])?.isEmpty == true,
            "The alias-only Claude fixture should not expose unversioned aliases.")
        let claudePicker = element("model-picker-menu")
        claudePicker.click()
        XCTAssertFalse(app.buttons["model-option-default"].exists)
        XCTAssertFalse(app.buttons["model-option-opus"].exists)
        XCTAssertFalse(app.buttons["model-option-sonnet"].exists)
        XCTAssertFalse(app.buttons["model-option-haiku"].exists)
        claudePicker.click()
    }
    // case-contract: test_conversation_mode_rejects_unknown_mode_without_starting_a_turn | The composer keeps the committed model and effort stable while the picker is open, then updates when it is dismissed. Its popover lists provider models and includes an accessible discrete effort slider with Low, Medium, High, and Extra High choices, constrained by model-reported effort support when available; the visible opaque white knob has no focus border, the 6-point track is visibly thick, and the slider responds to dragging and keyboard arrows. A saved selection belongs to its conversation, persists through fresh CLI/XPC reads and reopening, and stays isolated between providers; legacy per-conversation selections remain available, while a provider-wide preference supplies the default for conversations without a selection. Effort persists per conversation. Malformed model IDs and unsupported efforts are rejected without replacing prior choices. The UI opens a second conversation, changes its model independently, and restores the first conversation's selection; unsupported modes and malformed model IDs are rejected before creating history.
    func test_conversation_mode_rejects_unknown_mode_without_starting_a_turn() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Conversation modes", roots: [fixture.primary.path])
        let conversationModesTaskID = try taskID(named: "Conversation modes")
        let modelResult = try runCLI(["conversation", "models", conversationModesTaskID])["result"] as? [String: Any]
        let availableModels = try XCTUnwrap(modelResult?["models"] as? [[String: Any]])
        XCTAssertFalse(availableModels.isEmpty)
        let migratedModelID = try XCTUnwrap(availableModels.first?["id"] as? String)
        let legacyModelData = try JSONSerialization.data(withJSONObject: ["codex": migratedModelID])
        let legacyModelHex = legacyModelData.map { String(format: "%02x", $0) }.joined()
        let seedLegacyModel = Process()
        seedLegacyModel.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        seedLegacyModel.arguments = [
            dataDirectory.appendingPathComponent("Playhouse-v2.store").path,
            "UPDATE ZBOARDTASK SET ZCONVERSATIONMODELIDSDATA = X'\(legacyModelHex)' WHERE ZTITLE = 'Conversation modes'",
        ]
        let seedOutput = Pipe()
        seedLegacyModel.standardOutput = seedOutput
        seedLegacyModel.standardError = seedOutput
        try seedLegacyModel.run()
        seedLegacyModel.waitUntilExit()
        let seedDetails = String(data: seedOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(seedLegacyModel.terminationStatus, 0, "Seed the real SwiftData task row with its pre-global model: \(seedDetails)")
        let migratedModel = try XCTUnwrap(try runCLI(["conversation", "model", conversationModesTaskID])["result"] as? [String: Any])
        XCTAssertEqual(migratedModel["modelID"] as? String, migratedModelID,
            "The first bridge read should preserve the legacy model for this conversation.")

        openTask(named: "Conversation modes")
        let modelPicker = element("model-picker-menu")
        XCTAssertTrue(modelPicker.waitToExist(timeout: 5), "The composer should expose a model returned by Codex.")
        XCTAssertTrue(modelPicker.label.contains("effort: Medium"), "The selected model effort should default to Medium.")
        func displayedModelValue() -> String {
            let rawValue = modelPicker.value as? String ?? modelPicker.label
            return rawValue.components(separatedBy: ", effort:").first?
                .replacingOccurrences(of: "Model: ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? rawValue
        }
        let selectedModelIsAvailable = waitUntil({
            availableModels.contains { model in
                let displayedModel = displayedModelValue()
                return displayedModel.caseInsensitiveCompare(model["name"] as? String ?? "") == .orderedSame
                    || displayedModel.caseInsensitiveCompare(model["id"] as? String ?? "") == .orderedSame
            }
        }, timeout: 10)
        let selectedModel: [String: Any]
        if let codexModel = availableModels.first(where: { model in
            let displayedModel = displayedModelValue()
            return displayedModel.caseInsensitiveCompare(model["name"] as? String ?? "") == .orderedSame
                || displayedModel.caseInsensitiveCompare(model["id"] as? String ?? "") == .orderedSame
        }) {
            selectedModel = codexModel
        } else {
            XCTAssertTrue(!selectedModelIsAvailable && displayedModelValue() == "GPT-6 Luna",
                "The composer should show a Codex model or its offline fallback; selected='\(displayedModelValue())', available=\(availableModels).")
            selectedModel = ["name": "GPT-6 Luna", "id": "gpt-6-luna"]
        }
        let selectedModelName = try XCTUnwrap(selectedModel["name"] as? String)
        let selectedModelID = try XCTUnwrap(selectedModel["id"] as? String)
        XCTAssertEqual(selectedModelID, migratedModelID, "The visible picker should restore the legacy model saved on this conversation.")
        let modelMenu = modelPicker
        XCTAssertTrue(displayedModelValue().caseInsensitiveCompare(selectedModelName) == .orderedSame
            || displayedModelValue().caseInsensitiveCompare(selectedModelID) == .orderedSame)
        let alternateModel = try XCTUnwrap(availableModels.first { $0["id"] as? String != selectedModelID }, "The Codex fixture should expose multiple models.")
        let alternateID = try XCTUnwrap(alternateModel["id"] as? String)
        modelMenu.click()
        let optionID = "model-option-\(alternateID)"
        let modelOption = app.buttons.matching(identifier: optionID).firstMatch
        XCTAssertTrue(modelOption.waitToExist(timeout: 5), "The model picker should list each model returned by Codex.")
        modelOption.click()
        let alternateName = alternateModel["name"] as? String ?? alternateID
        XCTAssertTrue(displayedModelValue().caseInsensitiveCompare(selectedModelName) == .orderedSame
            || displayedModelValue().caseInsensitiveCompare(selectedModelID) == .orderedSame,
            "The composer model label should stay committed while the picker is open.")
        modelPicker.click()
        XCTAssertTrue(waitUntil({
            let displayedModel = displayedModelValue()
            return displayedModel.caseInsensitiveCompare(alternateName) == .orderedSame
                || displayedModel.caseInsensitiveCompare(alternateID) == .orderedSame
        }, timeout: 5), "Choosing a model should update the composer selection.")
        attachElementScreenshot(modelPicker, named: "The conversation model picker shows its committed selection")
        let limitedModel = try XCTUnwrap(availableModels.first { $0["id"] as? String == "gpt-6-mini" })
        XCTAssertEqual(limitedModel["supportedEfforts"] as? [String], ["low", "medium"])

        modelPicker.click()
        let effortSlider = element("model-effort-slider")
        XCTAssertTrue(effortSlider.waitToExist(timeout: 5), "The model popover should expose an effort slider.")
        XCTAssertEqual(effortSlider.label, "Model effort")
        XCTAssertEqual(effortTitle(of: effortSlider), "Medium", "The slider should expose its selected effort accessibly.")
        assertPixel(effortSlider.screenshot().image, normalizedX: 0.34, normalizedY: 0.5, rgb: (255, 255, 255), accuracy: 30)
        assertTrackThickness(effortSlider.screenshot().image)
        effortSlider.coordinate(withNormalizedOffset: CGVector(dx: 0.34, dy: 0.5)).click()
        assertNoBlueFocusOutline(in: effortSlider.screenshot().image)
        // Inset from the frame's edges, which land outside the control.
        for (position, title) in [(0.05, "Low"), (1.0 / 3.0, "Medium"), (2.0 / 3.0, "High"), (0.95, "Extra High")] {
            // The native slider over the drawn track takes the pointer itself.
            effortSlider.coordinate(withNormalizedOffset: CGVector(dx: position, dy: 0.5)).click()
            XCTAssertTrue(waitUntil({
                accessibleLabelOrValue(of: element("selected-model-effort")) == title
                    && effortTitle(of: effortSlider) == title
                    && modelPicker.label.contains("effort: Medium")
            }, timeout: 5), "Selecting \(title) should update the visible effort and slider value.")
        }
        // A click exactly on the frame's edge lands outside the control.
        effortSlider.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).click()
        XCTAssertTrue(waitUntil({
            accessibleLabelOrValue(of: element("selected-model-effort")) == "Low" && effortTitle(of: effortSlider) == "Low"
        }, timeout: 5), "Clicking the start of the visible effort track should select Low.")
        effortSlider.coordinate(withNormalizedOffset: CGVector(dx: 2.0 / 3.0, dy: 0.5)).click()
        XCTAssertTrue(waitUntil({
            accessibleLabelOrValue(of: element("selected-model-effort")) == "High" && effortTitle(of: effortSlider) == "High"
        }, timeout: 5), "Clicking two-thirds along the visible effort track should select High.")
        let dragStart = effortSlider.coordinate(withNormalizedOffset: CGVector(dx: 0.34, dy: 0.5))
        let dragEnd = effortSlider.coordinate(withNormalizedOffset: CGVector(dx: 0.67, dy: 0.5))
        dragStart.press(forDuration: 0.1, thenDragTo: dragEnd)
        XCTAssertTrue(waitUntil({
            accessibleLabelOrValue(of: element("selected-model-effort")) == "High" && effortTitle(of: effortSlider) == "High"
        }, timeout: 5), "Dragging the visible knob should move the effort selection.")
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil({
            accessibleLabelOrValue(of: element("selected-model-effort")) == "Extra High" && effortTitle(of: effortSlider) == "Extra High"
        }, timeout: 5), "The right arrow key should step the visible effort slider to Extra High.")
        XCTAssertTrue(modelPicker.label.contains("effort: Medium"), "The composer effort should stay committed while the picker is open.")
        let savedEffortBeforeDismissal = try XCTUnwrap(try runCLI(["conversation", "effort", conversationModesTaskID])["result"] as? [String: Any])
        XCTAssertEqual(savedEffortBeforeDismissal["effort"] as? String, "medium", "Effort changes should not persist before the picker is dismissed.")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil({ !effortSlider.isHittable }, timeout: 5), "Escape should dismiss the model popover.")
        XCTAssertTrue(waitUntil({ modelPicker.label.contains("effort: Extra High") }, timeout: 5), "Dismissing the picker should apply the staged effort.")
        XCTAssertTrue(waitUntil({
            guard let result = try? runCLI(["conversation", "effort", conversationModesTaskID])["result"] as? [String: Any] else { return false }
            return result["effort"] as? String == "xhigh"
        }, timeout: 5), "Effort changes should persist after the picker is dismissed.")
        let limitedOption = app.buttons["model-option-gpt-6-mini"]
        modelPicker.click()
        XCTAssertTrue(limitedOption.waitToExist(timeout: 5))
        limitedOption.click()
        XCTAssertTrue(modelPicker.label.contains(alternateName) && modelPicker.label.contains("effort: Extra High"),
            "The composer should retain its committed model and effort while a restricted model is being previewed.")
        XCTAssertEqual(accessibleLabelOrValue(of: element("selected-model-effort")), "Medium", "The staged selection should clamp to the model's supported effort.")
        modelPicker.click()
        XCTAssertTrue(waitUntil({
            modelPicker.label.contains("GPT-6 Mini") && modelPicker.label.contains("effort: Medium")
        }, timeout: 5), "Dismissing after changing to a restricted model should apply its clamped effort.")
        XCTAssertTrue(waitUntil({
            guard let result = try? runCLI(["conversation", "effort", conversationModesTaskID])["result"] as? [String: Any] else { return false }
            return result["effort"] as? String == "medium"
        }, timeout: 5), "The clamped effort should persist after the picker is dismissed.")
        modelPicker.click()
        XCTAssertTrue(effortSlider.waitToExist(timeout: 5))
        effortSlider.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).click()
        XCTAssertTrue(waitUntil({
            effortTitle(of: effortSlider) == "Medium"
                && accessibleLabelOrValue(of: element("selected-model-effort")) == "Medium"
                && modelPicker.label.contains("effort: Medium")
        }, timeout: 5), "The restricted slider must not select an unsupported High effort.")
        let defaultOption = app.buttons["model-option-\(selectedModelID)"]
        XCTAssertTrue(defaultOption.waitToExist(timeout: 5))
        defaultOption.click()
        XCTAssertTrue(modelPicker.label.contains("GPT-6 Mini"), "The model label should remain committed until picker dismissal.")
        modelPicker.click()
        XCTAssertTrue(waitUntil({ modelPicker.label.contains(selectedModelName) }, timeout: 5))
        modelPicker.click()
        XCTAssertTrue(effortSlider.waitToExist(timeout: 5))
        effortSlider.coordinate(withNormalizedOffset: CGVector(dx: 2.0 / 3.0, dy: 0.5)).click()
        XCTAssertTrue(waitUntil({
            accessibleLabelOrValue(of: element("selected-model-effort")) == "High" && modelPicker.label.contains("effort: Medium")
        }, timeout: 5))
        modelPicker.click()
        XCTAssertTrue(waitUntil({ modelPicker.label.contains("effort: High") }, timeout: 5))
        XCTAssertTrue(waitUntil({
            guard let response = try? runCLI(["conversation", "effort", conversationModesTaskID]),
                  let result = response["result"] as? [String: Any] else { return false }
            return result["effort"] as? String == "high"
        }, timeout: 5), "The selected effort should persist through a fresh CLI/XPC request.")
        element("back-to-board-button").click()
        openTask(named: "Conversation modes")
        let reopenedPicker = element("model-picker-menu")
        XCTAssertTrue(reopenedPicker.waitToExist(timeout: 5))
        reopenedPicker.click()
        XCTAssertTrue(waitUntil({ accessibleLabelOrValue(of: element("selected-model-effort")) == "High" }, timeout: 5), "Reopening the task should restore its effort selection.")
        reopenedPicker.click()

        let alternateOptionAfterReopen = app.buttons["model-option-\(alternateID)"]
        reopenedPicker.click()
        XCTAssertTrue(alternateOptionAfterReopen.waitToExist(timeout: 5))
        alternateOptionAfterReopen.click()
        reopenedPicker.click()
        XCTAssertTrue(waitUntil({ modelPicker.label.contains(alternateName) }, timeout: 5))
        XCTAssertTrue(waitUntil({
            guard let result = try? runCLI(["conversation", "model", conversationModesTaskID])["result"] as? [String: Any] else { return false }
            return result["modelID"] as? String == alternateID
        }, timeout: 5), "The committed model should persist through a fresh CLI/XPC request.")
        element("back-to-board-button").click()
        openTask(named: "Conversation modes")
        let restoredModelPicker = element("model-picker-menu")
        XCTAssertTrue(restoredModelPicker.waitToExist(timeout: 5))
        XCTAssertTrue(waitUntil({ restoredModelPicker.label.contains(alternateName) }, timeout: 5), "Reopening the task should restore the last selected model.")

        try createTaskFixture(title: "Global model selection", roots: [fixture.primary.path])
        let globalModelTaskID = try taskID(named: "Global model selection")
        element("back-to-board-button").click()
        openTask(named: "Global model selection")
        let globalModelPicker = element("model-picker-menu")
        XCTAssertTrue(globalModelPicker.waitToExist(timeout: 5))
        XCTAssertTrue(waitUntil({ globalModelPicker.label.contains(alternateName) }, timeout: 5),
            "A conversation without its own choice should start with the provider's remembered default.")
        globalModelPicker.click()
        let secondConversationModel = app.buttons["model-option-\(selectedModelID)"]
        XCTAssertTrue(secondConversationModel.waitToExist(timeout: 5))
        secondConversationModel.click()
        globalModelPicker.click()
        XCTAssertTrue(waitUntil({ globalModelPicker.label.contains(selectedModelName) }, timeout: 5))
        attachElementScreenshot(globalModelPicker, named: "The second conversation shows its own model selection")
        XCTAssertTrue(waitUntil({
            ((try? self.runCLI(["conversation", "model", globalModelTaskID]))?["result"] as? [String: Any])?["modelID"] as? String == selectedModelID
        }, timeout: 10), "The second conversation should persist its own model choice.")
        element("back-to-board-button").click()
        openTask(named: "Conversation modes")
        let originalConversationPicker = element("model-picker-menu")
        XCTAssertTrue(originalConversationPicker.waitToExist(timeout: 5))
        XCTAssertTrue(waitUntil({ originalConversationPicker.label.contains(alternateName) }, timeout: 5),
            "Reopening the first conversation should restore its independent model choice.")
        attachElementScreenshot(originalConversationPicker, named: "Reopening restores the first conversation's model")

        setPlanMode(true)

        let composer = element("message-composer")
        composer.click()
        composer.typeText("/plan")
        XCTAssertTrue(element("slash-command-plan").waitToExist(timeout: 5), "Typing /plan offers the command.")
        composer.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil({ (composer.value as? String) == "" }, timeout: 5), "Choosing /plan removes the typed command.")
        XCTAssertTrue(isModeOn("conversation-plan-button"), "Choosing /plan should switch modes without sending a message.")

        assertCLIError(
            try runCLI(
                ["conversation", "send", conversationModesTaskID, "--message", "Hello", "--mode", "unsupported"],
                expectedStatus: 2
            ),
            code: "invalid_argument"
        )
        let history = try runCLI(["conversation", "history", conversationModesTaskID])["result"] as? [String: Any]
        XCTAssertEqual((history?["messages"] as? [Any])?.count, 0)
        XCTAssertEqual((history?["activities"] as? [Any])?.count, 0)
        attachScreenshot(named: "Plan mode is visible in the conversation composer")


    }
    // case-contract: test_conversation_models_cache_and_refresh | Codex and Claude filtered model lists persist across fresh CLI/XPC requests; an unavailable workspace fails refresh without clearing the previous cache. The visible Claude picker shows the seeded cached option before replacing it with the filtered versioned provider list, and, when the installed provider executable fails to launch, stays on Claude and retains the cached option.
    func test_conversation_models_cache_and_refresh() throws {
        let claudeSource = WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui")
        let claudeExecutable = dataDirectory.appendingPathComponent("claude-fixture-model-cache")
        try copyFixtureFile(at: claudeSource, to: claudeExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claudeExecutable.path)
        let claudeOwnerMarker = dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner")
        let claudeOwnerValue = "Playhouse test owns this Claude Code protocol fixture (v1).\n"
        try Data(claudeOwnerValue.utf8).write(to: claudeOwnerMarker)
        claudeFixtureExecutable = claudeExecutable.path
        launchApp(defaultParent: fixture.parent.path)
        let claudeTask = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Claude cached models", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude"
        ])["result"] as? [String: Any])
        let claudeTaskID = try XCTUnwrap(claudeTask["id"] as? String)
        let seededClaudeModels = try XCTUnwrap((try runCLI(["conversation", "models", claudeTaskID])["result"] as? [String: Any])?["models"] as? [[String: Any]])
        XCTAssertEqual(seededClaudeModels.compactMap { $0["id"] as? String }, ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-6"])
        XCTAssertFalse(seededClaudeModels.contains { $0["id"] as? String == "default" })
        // The sandboxed runner's own preferences are not the daemon's, so seed the real cache
        // through a discovery that reports a stale list.
        let modelsOverride = URL(fileURLWithPath: claudeExecutable.path + ".models-override")
        func seedClaudeModelCache(_ models: [[String: String]]) throws {
            try JSONSerialization.data(withJSONObject: models).write(to: modelsOverride)
            _ = try runCLI(["conversation", "models", claudeTaskID])
            try FileManager.default.removeItem(at: modelsOverride)
        }
        try seedClaudeModelCache([["value": "cached-model", "displayName": "Cached Claude Model"]])
        let modelsDelay = URL(fileURLWithPath: claudeExecutable.path + ".models-delay")
        try Data().write(to: modelsDelay)
        let persistedClaudeModels = try XCTUnwrap((try runCLI(["conversation", "models", claudeTaskID, "--cached"])["result"] as? [String: Any])?["models"] as? [[String: Any]])
        XCTAssertEqual(persistedClaudeModels.first?["name"] as? String, "Cached Claude Model", "A fresh XPC request should read the seeded real preferences cache.")
        openTask(named: "Claude cached models")
        let claudePicker = element("model-picker-menu")
        XCTAssertTrue(claudePicker.waitToExist(timeout: 5))
        claudePicker.click()
        XCTAssertTrue(app.buttons["model-option-cached-model"].waitToExist(timeout: 5), "The distinct cached Claude option should render before server discovery completes.")
        try? FileManager.default.removeItem(at: modelsDelay)
        XCTAssertTrue(waitUntil({
            app.buttons["model-option-claude-opus-5-5"].exists
        }, timeout: 15), "Real Claude discovery should replace the seeded cache with its filtered versioned models.")
        XCTAssertTrue(waitUntil({ !app.buttons["model-option-cached-model"].exists }, timeout: 5),
            "The stale cached option should disappear after provider refresh.")
        XCTAssertFalse(app.buttons["model-option-default"].exists)
        claudePicker.click()
        let refreshedClaudeCache = try XCTUnwrap((try runCLI(["conversation", "models", claudeTaskID, "--cached"])["result"] as? [String: Any])?["models"] as? [[String: Any]])
        XCTAssertEqual(refreshedClaudeCache.compactMap { $0["id"] as? String }, ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-6"], "The real provider refresh should replace the stale persisted cache.")

        try seedClaudeModelCache([["value": "offline-cached-model", "displayName": "Offline Cached Claude"]])
        XCTAssertEqual(try String(contentsOf: claudeOwnerMarker, encoding: .utf8), claudeOwnerValue, "Only replace the test-owned executable after verifying its ownership marker.")
        // Claude stays installed but can't start: a missing executable would instead move the
        // unstarted conversation to an installed provider.
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: claudeExecutable)
        let offlineTask = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Claude cached offline", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude"
        ])["result"] as? [String: Any])
        let offlineTaskID = try XCTUnwrap(offlineTask["id"] as? String)
        openTask(named: "Claude cached offline")
        XCTAssertTrue(waitUntil({ self.element("conversation-provider-menu").label.contains("Claude") }, timeout: 10),
            "A Claude launch failure keeps the conversation on Claude.")
        XCTAssertEqual(try taskRecord(id: offlineTaskID)?["conversationProvider"] as? String, "claude")
        let offlinePicker = element("model-picker-menu")
        XCTAssertTrue(offlinePicker.waitToExist(timeout: 5))
        offlinePicker.click()
        XCTAssertTrue(app.buttons["model-option-offline-cached-model"].waitToExist(timeout: 5),
            "A failed provider launch should leave the cached Claude choice visible.")
        let retainedOfflineCache = try XCTUnwrap((try runCLI(["conversation", "models", offlineTaskID, "--cached"])["result"] as? [String: Any])?["models"] as? [[String: Any]])
        XCTAssertEqual(retainedOfflineCache.first?["name"] as? String, "Offline Cached Claude")
    }
    // case-contract: test_codex_message_timestamps | Playhouse stores each Codex message with the time it recorded it, and fresh CLI/XPC reads and app restarts show that same stored time. A timestamp in the provider's own thread history has no effect, because history is read only from Playhouse's store.
    func test_codex_message_timestamps() throws {
        let executable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-unique-turns-success")
        codexFixtureExecutable = executable.path
        let marker = URL(fileURLWithPath: executable.path + ".provider-timestamp")
        try? FileManager.default.removeItem(at: marker)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: executable.path + ".history"))
        defer { try? FileManager.default.removeItem(at: marker) }
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Codex timestamp UI", roots: [fixture.primary.path])
        let taskID = try taskID(named: "Codex timestamp UI")
        openTask(named: "Codex timestamp UI")
        let composer = element("message-composer")
        composer.click()
        composer.typeText("Check message time.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ self.noTurnIsRunning() }, timeout: 20), "The turn should settle before its stored time is read.")
        func storedReply() throws -> [String: Any] {
            let history = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
            return try XCTUnwrap((history["messages"] as? [[String: Any]])?.last { $0["role"] as? String == "assistant" })
        }
        let reply = try storedReply()
        let replyID = try XCTUnwrap(reply["id"] as? String)
        let recordedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: try XCTUnwrap(reply["createdAt"] as? String)))
        XCTAssertLessThan(abs(recordedAt.timeIntervalSinceNow), 120, "The reply carries the time Playhouse stored it.")
        let recordedLabel = recordedAt.formatted(.dateTime.hour().minute())
        XCTAssertTrue(app.staticTexts["message-time-\(replyID)"].waitForExistence(timeout: 15))
        relaunchApp()
        openTask(named: "Codex timestamp UI")
        let timestamp = app.staticTexts["message-time-\(replyID)"]
        XCTAssertTrue(timestamp.waitForExistence(timeout: 10))
        XCTAssertEqual(accessibleLabelOrValue(of: timestamp), recordedLabel, "A restart shows the stored time.")
        attachScreenshot(named: "Restored Codex timestamp")
        attachElementScreenshot(timestamp, named: "Restored Codex timestamp detail")
        // The provider's own thread history now carries a different time; history never reads it.
        try Data().write(to: marker)
        XCTAssertEqual(try storedReply()["createdAt"] as? String, reply["createdAt"] as? String)
        relaunchApp()
        openTask(named: "Codex timestamp UI")
        let storedTimestamp = app.staticTexts["message-time-\(replyID)"]
        XCTAssertTrue(storedTimestamp.waitForExistence(timeout: 10))
        XCTAssertEqual(accessibleLabelOrValue(of: storedTimestamp), recordedLabel, "A provider-supplied time does not replace the stored one.")
        attachScreenshot(named: "Stored Codex timestamp unaffected by provider history")
    }
    // case-contract: test_conversation_effort_dispatches_to_codex | The selected effort persists through CLI/XPC reads and reaches Codex turn/start collaborationMode.settings.reasoningEffort; a model's advertised effort limit rejects unsupported requests before history is created. The UI selects Extra High and sends a Sol turn, then sends a Luna turn; each stored reply stays attributed to the model its own turn ran on, and both replies show their stored timestamps after an app reload.
    func test_conversation_effort_dispatches_to_codex() throws {
        let executable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-unique-turns-success")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        codexFixtureExecutable = executable.path
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: executable.path + ".history"))
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Codex effort UI", roots: [fixture.primary.path])
        let taskID = try taskID(named: "Codex effort UI")
        openTask(named: "Codex effort UI")
        XCTAssertTrue(app.staticTexts["Send a message to Codex · Luna."].waitToExist(timeout: 10), "The default model's short name labels the empty conversation.")
        let picker = element("model-picker-menu")
        XCTAssertTrue(picker.waitToExist(timeout: 10))
        picker.click()
        let slider = element("model-effort-slider")
        XCTAssertTrue(slider.waitToExist(timeout: 5))
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).click()
        XCTAssertTrue(waitUntil({ accessibleLabelOrValue(of: element("selected-model-effort")) == "Extra High" }, timeout: 5))
        app.buttons["model-option-gpt-6-sol"].click()
        picker.click()
        XCTAssertTrue(app.staticTexts["Send a message to Codex · Sol."].waitToExist(timeout: 10), "Selecting another model updates its short name in the label, instead of staying stuck on the default.")
        XCTAssertEqual((try runCLI(["conversation", "model", taskID])["result"] as? [String: Any])?["modelID"] as? String, "gpt-6-sol")
        let unsupported = try runCLI([
            "conversation", "send", taskID, "--message", "Unsupported effort.", "--model", "gpt-6-mini"
        ], expectedStatus: 2)
        XCTAssertEqual((unsupported["error"] as? [String: Any])?["code"] as? String, "invalid_argument")
        let emptyHistory = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        XCTAssertEqual((emptyHistory["messages"] as? [Any])?.count, 0)
        let composer = element("message-composer")
        composer.click()
        composer.typeText("Check Codex effort dispatch.")
        element("send-message-button").click()
        XCTAssertTrue(transcriptMessage("Answers received: Blue / fixture-secret.").waitToExist(timeout: 15), "The Codex fixture's reply should arrive.")
        XCTAssertTrue(app.staticTexts["Codex · Sol"].waitForExistence(timeout: 10), "The sent reply's label reflects the model actually selected for the turn, not the hardcoded default.")
        picker.click()
        app.buttons["model-option-gpt-6-luna"].click()
        picker.click()
        // With a transcript the empty-state prompt is gone; the picker names the model.
        XCTAssertTrue(waitUntil({ picker.label.contains("GPT-6 Luna") }, timeout: 10))
        composer.click()
        composer.typeText("Check the next model.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({
            app.groups.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@", "assistant-message-", "Answers received: Blue / fixture-secret."
            )).count >= 2
        }, timeout: 15))
        XCTAssertTrue(app.staticTexts["Codex · Sol"].exists, "The earlier reply keeps the model its own turn ran on.")
        XCTAssertTrue(app.staticTexts["Codex · Luna"].exists, "The new turn is attributed to the model selected for that send.")
        // The latest ordinary reply is the one the user's turn got, not a reply to a status nudge.
        let effortHistory = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        let replies = ordinaryMessages(effortHistory["messages"] as? [[String: Any]] ?? []).filter { ($0["role"] as? String) == "assistant" }
        let firstReplyItem = try XCTUnwrap(replies.first?["id"] as? String)
        let latestReplyItem = try XCTUnwrap(replies.last?["id"] as? String)
        XCTAssertNotEqual(latestReplyItem, firstReplyItem)
        XCTAssertEqual(replies.first?["modelID"] as? String, "gpt-6-sol")
        XCTAssertEqual(replies.last?["modelID"] as? String, "gpt-6-luna")
        relaunchApp()
        openTask(named: "Codex effort UI")
        let timestamp = app.staticTexts.matching(identifier: "message-time-\(latestReplyItem)").firstMatch
        XCTAssertTrue(timestamp.waitToExist(timeout: 10), "The stored timestamp survives an app reload.")
        attachScreenshot(named: "Codex message timestamp")
        attachElementScreenshot(timestamp, named: "Codex message timestamp detail")
        let firstReply = app.groups["assistant-message-\(firstReplyItem)"]
        let transcriptScrollView = element("conversation-scroll-view")
        for _ in 0..<10 {
            guard !firstReply.exists else { break }
            transcriptScrollView.scroll(byDeltaX: 0, deltaY: 400)
            _ = waitUntil({ firstReply.exists }, timeout: 1)
        }
        XCTAssertTrue(firstReply.exists, "Scrolling up loads the earlier reply.")
        XCTAssertTrue(app.staticTexts.matching(identifier: "message-time-\(firstReplyItem)").firstMatch.exists,
                      "The earlier reply also shows its stored time after a reload.")
        XCTAssertTrue(app.staticTexts["Codex · Sol"].exists, "The earlier reply's model survives a reload.")
        let historyURL = URL(fileURLWithPath: executable.path + ".history")
        let history = try JSONSerialization.jsonObject(with: Data(contentsOf: historyURL)) as? [String: Any]
        let turns = try XCTUnwrap(history?["turns"] as? [[String: Any]])
        XCTAssertEqual(turns.last?["reasoningEffort"] as? String, "xhigh")
        let effort = try XCTUnwrap(try runCLI(["conversation", "effort", taskID])["result"] as? [String: Any])
        XCTAssertEqual(effort["effort"] as? String, "xhigh")
    }
    // case-contract: test_codex_history_keeps_loaded_thread_model | After a Codex turn on a non-default model (Sol) ends, loading history never resumes the Codex thread, with Sol still selected or after the selection moves to another non-default model (Mini), and the stored reply stays attributed to Sol. A subsequent send on Luna also resumes despite Codex reporting Sol, starts the turn with Luna, shows its reply without an error, and records Luna for that turn. The selected model remains associated with the conversation. A second Codex conversation that never chose a model keeps the model its own turn ran on, in CLI/XPC reads and in the reopened composer’s picker, after the provider-wide remembered selection moves to another model.
    func test_codex_history_keeps_loaded_thread_model() throws {
        let executable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-unique-turns-success")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        codexFixtureExecutable = executable.path
        let historyURL = URL(fileURLWithPath: executable.path + ".history")
        let keptModel = URL(fileURLWithPath: executable.path + ".resume-keeps-model")
        try? FileManager.default.removeItem(at: historyURL)
        try? FileManager.default.removeItem(at: keptModel)
        defer { try? FileManager.default.removeItem(at: keptModel) }
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Codex kept model UI", roots: [fixture.primary.path])
        let taskID = try taskID(named: "Codex kept model UI")
        openTask(named: "Codex kept model UI")
        let picker = element("model-picker-menu")
        XCTAssertTrue(picker.waitToExist(timeout: 10))
        picker.click()
        app.buttons["model-option-gpt-6-sol"].click()
        picker.click()
        XCTAssertTrue(app.staticTexts["Send a message to Codex · Sol."].waitToExist(timeout: 10))
        let composer = element("message-composer")
        composer.click()
        composer.typeText("Run on Sol.")
        element("send-message-button").click()
        let reply = "Answers received: Blue / fixture-secret."
        XCTAssertTrue(transcriptMessage(reply).waitToExist(timeout: 15), "The Sol turn's reply should arrive.")
        XCTAssertTrue(app.staticTexts["Codex · Sol"].waitToExist(timeout: 5), "The reply should be labeled with the model it ran on.")
        // History is read from Playhouse's store, so reopening never resumes the Codex thread,
        // whether or not the selected model matches the one Codex holds the thread on.
        XCTAssertEqual((try runCLI(["conversation", "model", taskID])["result"] as? [String: Any])?["modelID"] as? String, "gpt-6-sol")
        try "gpt-6-sol\n".write(to: keptModel, atomically: true, encoding: .utf8)
        func recordedResumes() -> [[String: String]] {
            ((try? JSONSerialization.jsonObject(with: Data(contentsOf: historyURL))) as? [String: Any])?["threadResumeKeptModels"] as? [[String: String]] ?? []
        }
        let resumesBefore = recordedResumes()
        returnToBoard()
        openTask(named: "Codex kept model UI")
        XCTAssertTrue(transcriptMessage(reply).waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({ picker.label.contains("GPT-6 Sol") }, timeout: 10),
            "Opening the conversation should restore its saved model selection.")
        attachElementScreenshot(picker, named: "Reopening the Codex conversation restores Sol")
        XCTAssertFalse(element("codex-chat-error").exists)
        picker.click()
        app.buttons["model-option-gpt-6-mini"].click()
        picker.click()
        XCTAssertTrue(waitUntil({ picker.label.contains("GPT-6 Mini") }, timeout: 10))
        XCTAssertTrue(waitUntil({
            ((try? self.runCLI(["conversation", "model", taskID]))?["result"] as? [String: Any])?["modelID"] as? String == "gpt-6-mini"
        }, timeout: 10))
        returnToBoard()
        openTask(named: "Codex kept model UI")
        XCTAssertTrue(transcriptMessage(reply).waitToExist(timeout: 10), "History still shows the Sol reply.")
        XCTAssertTrue(app.staticTexts["Codex · Sol"].exists, "The stored reply keeps the model its turn ran on.")
        XCTAssertFalse(waitUntil({ !FileManager.default.fileExists(atPath: keptModel.path) }, timeout: 3),
                       "Reopening must not resume the Codex thread.")
        XCTAssertEqual(recordedResumes(), resumesBefore, "Reopening must not resume the Codex thread.")
        XCTAssertFalse(element("codex-chat-error").exists, "Loading history never depends on the Codex thread's model.")
        attachScreenshot(named: "Stored history loads with Mini selected and no Codex resume")
        // The thread still reports Sol, but a new turn should switch to the
        // model selected in this conversation.
        picker.click()
        app.buttons["model-option-gpt-6-luna"].click()
        picker.click()
        XCTAssertTrue(waitUntil({ picker.label.contains("GPT-6 Luna") }, timeout: 10))
        XCTAssertTrue(waitUntil({
            ((try? self.runCLI(["conversation", "model", taskID]))?["result"] as? [String: Any])?["modelID"] as? String == "gpt-6-luna"
        }, timeout: 10))
        try "gpt-6-sol\n".write(to: keptModel, atomically: true, encoding: .utf8)
        composer.click()
        composer.typeText("Run on Luna.")
        element("send-message-button").click()
        let error = element("codex-chat-error")
        XCTAssertTrue(app.staticTexts["Codex · Luna"].waitToExist(timeout: 15), "The resumed thread should switch to Luna for this turn.")
        XCTAssertFalse(error.exists, "A model change inside an existing thread should not show a mismatch error.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: keptModel.path))
        let turns = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: Data(contentsOf: historyURL)) as? [String: Any])?["turns"] as? [[String: Any]]
        )
        XCTAssertEqual(turns.last { ($0["userMessage"] as? String)?.hasSuffix("Run on Luna.") == true }?["modelID"] as? String, "gpt-6-luna",
                       "The resumed Codex thread should run the newly selected model.")
        XCTAssertTrue(waitUntil({
            ((try? self.runCLI(["conversation", "model", taskID]))?["result"] as? [String: Any])?["modelID"] as? String == "gpt-6-luna"
        }, timeout: 10), "The selected model should remain persisted for this conversation.")
        // A conversation that never chose a model keeps the one its own turns ran on, after the
        // provider-wide remembered selection moves to another model.
        XCTAssertTrue(waitUntil({ self.noTurnIsRunning() }, timeout: 30))
        returnToBoard()
        try createTaskFixture(title: "Codex history model", roots: [fixture.primary.path])
        let unselectedTaskID = try self.taskID(named: "Codex history model")
        _ = try runCLI(["conversation", "send", unselectedTaskID, "--message", "Run on the remembered model."])
        _ = try runCLI(["conversation", "model", taskID, "set", "gpt-6-mini"])
        for _ in 0..<2 {
            XCTAssertEqual((try runCLI(["conversation", "model", unselectedTaskID])["result"] as? [String: Any])?["modelID"] as? String, "gpt-6-luna",
                           "The model comes from the conversation's own latest Codex turn, not the remembered selection.")
        }
        openTask(named: "Codex history model")
        XCTAssertTrue(waitUntil({ picker.label.contains("GPT-6 Luna") }, timeout: 10),
                      "Opening the conversation shows the model its own turns ran on.")
        attachElementScreenshot(picker, named: "Codex model resolved from the conversation's own turns")
        attachElementScreenshot(picker, named: "The Codex conversation model picker shows Luna")
        attachScreenshot(named: "The existing Codex thread switches to Luna")
    }
    // case-contract: test_conversation_effort_dispatches_to_claude | Claude's model picker omits Default and aliases, showing Opus 5.5 resolved from Claude Code's bare alias entry as the concrete latest choice in place of the older Opus 5. Selecting it changes the prompt and reply label to Claude · Opus 5.5, and later model changes preserve the old reply's model attribution. The selected effort persists through CLI/XPC reads and reaches Claude Code as CLAUDE_CODE_EFFORT_LEVEL; the UI selects Extra High and sends a Claude fixture turn whose recorded environment value is xhigh.
    func test_conversation_effort_dispatches_to_claude() throws {
        let executable = WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        claudeFixtureExecutable = executable.path
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: executable.path + ".history"))
        launchApp(defaultParent: fixture.parent.path)
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Claude effort UI", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude"
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        openTask(named: "Claude effort UI")
        let picker = element("model-picker-menu")
        XCTAssertTrue(picker.waitToExist(timeout: 10))
        picker.click()
        XCTAssertTrue(app.buttons["model-option-claude-opus-5-5"].waitToExist(timeout: 5),
            "The model popover should list the latest concrete Opus model.")
        XCTAssertFalse(app.buttons["model-option-default"].exists, "The Claude Default pseudo-model should not appear in the menu.")
        XCTAssertFalse(app.buttons["model-option-opus"].exists, "The versioned Opus model should replace its alias.")
        XCTAssertFalse(app.buttons["model-option-claude-opus-5"].exists,
            "The alias resolving to Opus 5.5 should supersede the older concrete Opus 5 entry.")
        XCTAssertTrue(app.buttons["model-option-claude-opus-5-5"].exists, "The latest concrete Opus model should remain selectable.")
        // The open popover is the state the fix is about: the newest release of each
        // family, which Claude Code names only through its alias entries. Popovers are
        // separate windows, so the whole screen is captured.
        attachScreenshot(named: "Claude model list shows the newest version of each family", fullScreen: true)
        app.buttons["model-option-claude-opus-5-5"].click()
        picker.click()
        XCTAssertTrue(app.staticTexts["Send a message to Claude · Opus 5.5."].waitToExist(timeout: 10))
        attachScreenshot(named: "Composer shows the selected Claude Opus 5.5 model")
        picker.click()
        let slider = element("model-effort-slider")
        XCTAssertTrue(slider.waitToExist(timeout: 5))
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).click()
        XCTAssertTrue(waitUntil({ accessibleLabelOrValue(of: element("selected-model-effort")) == "Extra High" }, timeout: 5))
        picker.click()
        let composer = element("message-composer")
        composer.click()
        composer.typeText("Check Claude effort dispatch.")
        element("send-message-button").click()
        XCTAssertTrue(app.staticTexts["OK."].waitToExist(timeout: 15))
        XCTAssertTrue(app.staticTexts["Claude · Opus 5.5"].waitToExist(timeout: 5))
        picker.click()
        app.buttons["model-option-claude-sonnet-5-5"].click()
        picker.click()
        // With a transcript the empty-state prompt is gone; the picker names the model.
        XCTAssertTrue(waitUntil({ picker.label.contains("Sonnet 5.5") }, timeout: 10))
        XCTAssertTrue(app.staticTexts["Claude · Opus 5.5"].exists, "Changing the selected model must not relabel the earlier reply.")
        let historyURL = URL(fileURLWithPath: executable.path + ".history")
        let history = try JSONSerialization.jsonObject(with: Data(contentsOf: historyURL)) as? [String: Any]
        let turns = try XCTUnwrap(history?["turns"] as? [[String: Any]])
        XCTAssertEqual(turns.last?["effort"] as? String, "xhigh")
        let arguments = try XCTUnwrap(turns.last?["arguments"] as? [String])
        let modelArgumentIndex = try XCTUnwrap(arguments.firstIndex(of: "--model"))
        let modelArgument = try XCTUnwrap(arguments.dropFirst(modelArgumentIndex + 1).first)
        XCTAssertEqual(modelArgument, "claude-opus-5-5", "The selected Claude model should reach Claude Code.")
        let effort = try XCTUnwrap(try runCLI(["conversation", "effort", taskID])["result"] as? [String: Any])
        XCTAssertEqual(effort["effort"] as? String, "xhigh")
    }
    // case-contract: test_claude_empty_question_request_is_rejected | Claude AskUserQuestion requests with no questions are rejected through the control protocol, fail the turn, and mark the task Blocked; the UI shows the blocked task and its intervention indicator.
    func test_claude_empty_question_request_is_rejected() throws {
        try installClaudeFixtureExecutable(named: "claude-fixture-empty-question")
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Empty Claude question", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude"
        ]) ["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Empty Claude question")
        element("message-composer").click()
        element("message-composer").typeText("Ask an empty structured question.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) == "Blocked" }, timeout: 15))
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 15))
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Blocked")
        XCTAssertTrue(element("blocked-waiting-indicator").exists)
        assertTaskVisible("Empty Claude question", inColumn: "Blocked")
    }
}
