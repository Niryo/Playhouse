import Foundation

extension PlayhouseBridgeRuntime {
    func conversationOperation(
        _ request: BridgeRequest,
        taskManager: BoardTaskManager,
        settings: WorkspaceSettingsManager,
        conversationClients: () -> ConversationClients,
        eventHandler: @escaping (BridgeEvent) -> Void
    ) async throws -> BridgeValue {
        switch request.command {
        case "conversation.send":
            let taskID = try request.requiredUUID("taskID")
            let modeValue = request.arguments["mode"]?.string ?? ConversationMode.code.rawValue
            guard let mode = ConversationMode(rawValue: modeValue) else {
                throw BridgeCommandError(code: "invalid_argument", message: "Unknown conversation mode '\(modeValue)'. Valid modes: default, plan.")
            }
            let conversations = ConversationManager(
                tasks: taskManager, clients: conversationClients(), settingsManager: settings, defersHistoryImages: request.defersHistoryImages
            )
            let reportsTurnStarting = request.arguments["reportTurnStarting"]?.bool == true
            // Page bookkeeping stays in ConversationManager.send, shared with GUI sends.
            let history = try await conversations.send(
                taskID: taskID,
                text: request.arguments["message"]?.string ?? "",
                imageDataURLs: request.arguments["images"]?.strings ?? [],
                mode: mode,
                modelID: request.arguments["model"]?.string,
                userInputAnswers: try request.optionalStringArrays("answers"),
                statusBeforeSubmission: request.arguments["statusBeforeSubmission"]?.string.flatMap(TaskStatus.init(rawValue:)),
                contextPageIDs: request.arguments["contextPages"]?.strings ?? [],
                startsNewChatPage: request.arguments["newPage"]?.bool == true,
                onTurnStarting: reportsTurnStarting ? {
                    eventHandler(BridgeEvent(requestID: request.id, type: "turn_starting", payload: .object([:])))
                } : nil,
                onUpdate: { update in
                    if let payload = try? Self.value(update) {
                        eventHandler(BridgeEvent(requestID: request.id, type: update.type, payload: payload))
                    }
                },
                historyMessageLimit: try request.optionalHistoryLimit()
            )
            return try Self.value(history)
        case "chat.bubble.send":
            let conversations = ConversationManager(
                tasks: taskManager, clients: conversationClients(), settingsManager: settings, defersHistoryImages: request.defersHistoryImages
            )
            var created: ParallelChatBubbleRecord?
            let history = try await conversations.sendInParallel(
                text: request.arguments["message"]?.string ?? "",
                imageDataURLs: request.arguments["images"]?.strings ?? [],
                onBubbleCreated: { bubble in
                    created = bubble
                    if let payload = try? Self.value(bubble) {
                        eventHandler(BridgeEvent(requestID: request.id, type: "bubble_created", payload: payload))
                    }
                },
                onUpdate: { update in
                    if let payload = try? Self.value(update) {
                        eventHandler(BridgeEvent(requestID: request.id, type: update.type, payload: payload))
                    }
                }
            )
            return .object([
                "bubble": try created.map { try Self.value($0) } ?? .null,
                "history": try Self.value(history),
            ])
        case "chat.bubble.list":
            let chat = try await taskManager.getOrCreateStandaloneChat(provider: settings.defaultConversationProvider)
            let bubbles = try taskManager.parallelChatBubbles(of: chat.id).map(taskManager.parallelChatBubbleRecord)
            return try Self.value(["bubbles": bubbles])
        case "chat.bubble.close":
            let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
            return try Self.value(await conversations.closeParallelChatBubble(id: request.requiredUUID("bubbleID")))
        case "conversation.side_chat":
            let taskID = try request.requiredUUID("taskID")
            let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
            let reply = try await conversations.sideChat(
                taskID: taskID,
                sideChatID: request.arguments["sideChatID"]?.string,
                selectedText: request.arguments["selection"]?.string,
                source: try request.arguments["source"]?.string.map { json in
                    guard let data = json.data(using: .utf8),
                          let source = try? JSONDecoder().decode(ConversationTextSource.self, from: data) else {
                        throw BridgeCommandError(code: "invalid_argument", message: "Pass the source as a JSON object with messageID, blockID, startOffset, endBlockID and endOffset.")
                    }
                    return source
                },
                message: request.arguments["message"]?.string ?? "",
                modelID: request.arguments["model"]?.string,
                effort: try request.arguments["effort"]?.string.map { value in
                    guard let effort = ConversationEffort(rawValue: value) else {
                        throw BridgeCommandError(code: "invalid_argument", message: "Unknown effort '\(value)'. Valid efforts: low, medium, high, xhigh.")
                    }
                    return effort
                },
                onDelta: { text in
                    eventHandler(BridgeEvent(requestID: request.id, type: "text_delta", payload: .object(["text": .string(text)])))
                }
            )
            return try Self.value(reply)
        case "conversation.side_chats.list":
            let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
            return try Self.value(try conversations.savedSideChats(taskID: request.requiredUUID("taskID")))
        case "conversation.side_chat.close":
            let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
            let taskID = try request.requiredUUID("taskID")
            let closed = conversations.closeSideChat(taskID: taskID, sideChatID: try request.requiredString("sideChatID"))
            return .object(["closed": .boolean(closed)])
        case "conversation.events.subscribe":
            let taskID = try request.requiredUUID("taskID")
            // A plugin editor is watched like a board task. The standalone chat files each turn
            // under the page its close-turn picks, so it is followed through its history instead.
            if try taskManager.conversationSubject(taskID).isStandaloneChat {
                throw BridgeCommandError(code: "invalid_argument", message: "The standalone chat is followed through its history, not watched.")
            }
            guard let updates = ConversationTurnEvents.watch(taskID) else {
                return .object(["watched": .boolean(false)])
            }
            eventHandler(BridgeEvent(requestID: request.id, type: "watching", payload: .object([:])))
            for await update in updates {
                if Task.isCancelled { break }
                if let payload = try? Self.value(update) {
                    eventHandler(BridgeEvent(requestID: request.id, type: update.type, payload: payload))
                }
            }
            return .object(["watched": .boolean(true)])
        default:
            throw BridgeCommandError(code: "unsupported_command", message: "Unsupported conversation command: \(request.command).")
        }
    }

    func conversationRuntimeResponse(_ request: BridgeRequest, eventHandler: @escaping (BridgeEvent) -> Void) async -> BridgeResponse {
        let runtimeScope: String?
        #if DEBUG
        runtimeScope = request.dataDirectory
        #else
        runtimeScope = nil
        #endif
        do {
            let result: BridgeValue
            if request.command == "conversation.runtime" {
                result = try Self.value(ConversationRuntimeSnapshot.current(dataDirectory: runtimeScope))
            } else {
                // Streams the daemon's turn state to a window until it disconnects.
                for await snapshot in ConversationRuntimeSnapshot.changes(dataDirectory: runtimeScope) {
                    if Task.isCancelled { break }
                    eventHandler(BridgeEvent(requestID: request.id, type: "runtime_state", payload: try Self.value(snapshot)))
                }
                result = .object(["subscribed": .boolean(false)])
            }
            await PlayhouseDiagnostics.endBatch()
            return .success(request, result: result)
        } catch {
            await PlayhouseDiagnostics.endBatch()
            return .failure(request, code: "operation_failed", message: error.localizedDescription)
        }
    }

    func conversationCPUUsageResponse(_ request: BridgeRequest, eventHandler: @escaping (BridgeEvent) -> Void) async -> BridgeResponse {
        let runtimeScope: String?
        #if DEBUG
        runtimeScope = request.dataDirectory
        #else
        runtimeScope = nil
        #endif
        do {
            let result: BridgeValue
            if request.command == "conversation.cpuUsage" {
                result = try Self.value(await TaskCPUUsageSnapshot.current(dataDirectory: runtimeScope))
            } else {
                for await snapshot in TaskCPUUsageSnapshot.changes(dataDirectory: runtimeScope) {
                    if Task.isCancelled { break }
                    eventHandler(BridgeEvent(requestID: request.id, type: "cpu_usage_state", payload: try Self.value(snapshot)))
                }
                result = .object(["subscribed": .boolean(false)])
            }
            await PlayhouseDiagnostics.endBatch()
            return .success(request, result: result)
        } catch {
            await PlayhouseDiagnostics.endBatch()
            return .failure(request, code: "operation_failed", message: error.localizedDescription)
        }
    }
}
