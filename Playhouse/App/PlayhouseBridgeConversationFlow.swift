import Foundation

extension PlayhouseBridgeRuntime {
    func conversationFlowOperation(
        _ request: BridgeRequest,
        taskManager: BoardTaskManager,
        settings: WorkspaceSettingsManager,
        conversationClients: () -> ConversationClients,
        eventHandler: @escaping (BridgeEvent) -> Void
    ) async throws -> BridgeValue {
        let conversations = ConversationManager(
            tasks: taskManager, clients: conversationClients(), settingsManager: settings, defersHistoryImages: request.defersHistoryImages
        )
        switch request.command {
        case "conversation.queue":
            return try Self.value(conversations.queueMessage(
                taskID: request.requiredUUID("taskID"), text: request.arguments["message"]?.string ?? "",
                imageDataURLs: request.arguments["images"]?.strings ?? []
            ))
        case "conversation.queue.list":
            return .array(try conversations.queuedMessages(taskID: request.requiredUUID("taskID")).map { try Self.value($0) })
        case "conversation.queue.retry":
            let retried = try await conversations.retryQueuedMessage(
                taskID: request.requiredUUID("taskID"), messageID: request.requiredUUID("messageID"),
                onUpdate: { update in
                    if let payload = try? Self.value(update) {
                        eventHandler(BridgeEvent(requestID: request.id, type: update.type, payload: payload))
                    }
                }
            )
            return .object(["retried": .boolean(retried)])
        case "conversation.queue.remove":
            try conversations.removeQueuedMessage(taskID: request.requiredUUID("taskID"), messageID: request.requiredUUID("messageID"))
            return .object(["removed": .boolean(true)])
        case "conversation.queue.steer":
            let steered = try await conversations.steerQueuedMessage(taskID: request.requiredUUID("taskID"), messageID: request.requiredUUID("messageID"))
            return .object([
                "text": .string(steered.message), "images": .array(steered.imageDataURLs.map(BridgeValue.string)),
                "accepted": .boolean(true), "queued": .boolean(!steered.accepted)
            ])
        case "conversation.steer":
            let taskID = try request.requiredUUID("taskID")
            let accepted = try await conversations.steer(
                taskID: taskID, text: request.arguments["message"]?.string ?? "",
                imageDataURLs: request.arguments["images"]?.strings ?? []
            )
            if request.arguments["queueIfMissed"]?.bool == false || accepted {
                return .object(["accepted": .boolean(accepted), "queued": .boolean(false)])
            }
            _ = try await conversations.queueMissedSteer(
                taskID: taskID, text: request.arguments["message"]?.string ?? "",
                imageDataURLs: request.arguments["images"]?.strings ?? []
            )
            return .object(["accepted": .boolean(true), "queued": .boolean(true)])
        case "conversation.answer_async":
            let taskID = try request.requiredUUID("taskID")
            let itemID = try request.requiredString("itemID")
            let history = try await conversations.history(taskID: taskID)
            guard let question = history.messages.first(where: { $0.id == itemID && $0.asyncQuestions != nil }) else {
                throw BridgeCommandError(code: "not_found", message: "That question is not in this conversation.")
            }
            let answer = try await conversations.answerAsyncQuestion(
                taskID: taskID, question: question, answers: request.arguments["answers"]?.strings ?? [],
                historyMessageLimit: try request.optionalHistoryLimit()
            )
            var answered: [String: BridgeValue] = ["text": .string(answer.text), "queued": .boolean(answer.queued)]
            if let history = answer.history { answered["history"] = try Self.value(history) }
            return .object(answered)
        case "conversation.repair_user_input":
            return try await Self.value(conversations.repairPendingUserInput(
                taskID: request.requiredUUID("taskID"), sourceTaskID: request.requiredUUID("sourceTaskID")
            ))
        case "conversation.answer_user_input":
            let accepted = try await conversations.answerUserInput(
                taskID: request.requiredUUID("taskID"), requestID: request.requiredString("requestID"),
                answers: try request.optionalStringArrays("answers"), modelID: request.arguments["model"]?.string,
                onUpdate: { update in
                    if let payload = try? Self.value(update) {
                        eventHandler(BridgeEvent(requestID: request.id, type: update.type, payload: payload))
                    }
                }
            )
            return .object(["accepted": .boolean(accepted)])
        case "conversation.subagent_history":
            let activity: ConversationActivity = try Self.decode(request.arguments["activity"])
            return try Self.value(await conversations.subagentHistory(taskID: request.requiredUUID("taskID"), activity: activity))
        case "conversation.answered_async":
            return .object(["itemIDs": .array(try conversations.answeredAsyncQuestionIDs(taskID: request.requiredUUID("taskID")).map(BridgeValue.string))])
        case "conversation.queue.missed_steer":
            return try Self.value(try await conversations.queueMissedSteer(
                taskID: request.requiredUUID("taskID"), text: request.arguments["message"]?.string ?? "",
                imageDataURLs: request.arguments["images"]?.strings ?? [],
                onUpdate: { update in
                    if let payload = try? Self.value(update) {
                        eventHandler(BridgeEvent(requestID: request.id, type: update.type, payload: payload))
                    }
                }
            ))
        default:
            throw BridgeCommandError(code: "unsupported_command", message: "Unsupported conversation flow command: \(request.command).")
        }
    }
}
