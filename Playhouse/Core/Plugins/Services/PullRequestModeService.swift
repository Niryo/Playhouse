import Foundation

/// The pull request mode a task card's mode pill chooses. It is the built-in
/// `pull-request-mode` plugin's own state (keyed by task id), not a property
/// of the task: the plugin's service decides what each mode does when the
/// task moves or the app comes to the front.
package enum PullRequestMode: String, CaseIterable, Codable, Sendable {
    case manual
    case pullRequest = "pr"
    case autopilot
    case merge

    /// A task the user never set a mode for leaves its pull request to the
    /// user. Tasks saved while PR was the default keep it as their own saved
    /// mode (`BoardTaskManager.pinPullRequestModeOfExistingTasks`).
    package static let defaultMode = PullRequestMode.manual

    package var label: String {
        switch self {
        case .manual: "Manual"
        case .pullRequest: "PR"
        case .autopilot: "Green"
        case .merge: "Merge"
        }
    }

    package var helpText: String {
        switch self {
        case .manual: "Manual: you open the pull request yourself"
        case .pullRequest: "PR: open the pull request when the task reaches Review"
        case .autopilot: "Green: open the PR, then fix failing checks and review comments until it's green"
        case .merge: "Merge: like Green, then merge the PR once it's green"
        }
    }

    /// Autopilot and merge keep following the task's pull requests in Review.
    package var followsPullRequests: Bool { self == .autopilot || self == .merge }

    /// A task's mode in the plugin's state: its own, else the one its
    /// recurring schedule was given (each run inherits it), else the default.
    package static func resolve(state: [String: PluginValue], taskID: String, scheduleSourceTaskID: String?) -> PullRequestMode {
        for key in [taskID, scheduleSourceTaskID].compactMap({ $0 }) {
            if let mode = state[key]?.string.flatMap(PullRequestMode.init(rawValue:)) { return mode }
        }
        return defaultMode
    }
}

/// The `pull-request-mode` plugin's daemon half. On each change it hears it
/// decides, from the mode it keeps for the task, what to do:
/// - the task reached Review: create its pull requests unless the mode is
///   manual, then (Green and Merge) follow them;
/// - the app came to the front: follow every Green or Merge task in Review;
/// - the user chose a mode for a task in Review: as on reaching Review, create
///   its pull requests unless the mode is manual, then (Green and Merge) follow
///   them with a fresh set of fix attempts.
/// Following is one `task.pr.autopilot` pass (fix a red PR, merge a green one
/// in Merge mode); a pass that finds checks still running looks again later,
/// and one that finds no linked pull request stops.
@MainActor
package final class PullRequestModeService: PluginService {
    package let pluginID = BuiltInPlugins.pullRequestModeID

    /// Throttles focus-driven follows per task, so returning to the app over
    /// and over doesn't probe GitHub every time.
    private let throttle = PluginThrottle(interval: PluginThrottle.defaultInterval)
    private var pollScheduled: Set<String> = []

    package init() {}

    /// The daemon serves many callers, so a test's shorter cooldown comes with its request.
    package static var focusInterval: TimeInterval {
        PlayhouseProcessEnvironment.current["PLAYHOUSE_E2E_PR_CHECK_COOLDOWN_SECONDS"].flatMap(TimeInterval.init) ?? 20
    }

    package static var pollInterval: TimeInterval {
        PlayhouseProcessEnvironment.current["PLAYHOUSE_E2E_PR_AUTOPILOT_POLL_SECONDS"].flatMap(TimeInterval.init) ?? 180
    }

    /// How soon a pass skipped on reaching Review looks again.
    package static let retryInterval: TimeInterval = 5

    package func handle(_ event: PluginEvent, context: PluginServiceContext) async {
        switch event.name {
        case PluginEvent.taskStatusChanged:
            guard event.payload["to"]?.string == TaskStatus.review.rawValue, let taskID = event.payload["taskID"]?.string else { return }
            await taskReachedReview(taskID, context: context)
        case PluginEvent.appFocus:
            await followReviewTasks(context: context)
        case PluginEvent.pluginStateChanged:
            guard event.payload["pluginID"]?.string == pluginID, let taskID = event.payload["key"]?.string else { return }
            guard let task = try? await context.call("task.get", ["taskID": .string(taskID)]).object,
                  task["status"]?.string == TaskStatus.review.rawValue else { return }
            // A task that reached Review in Manual mode has no pull request yet:
            // choosing another mode there does what reaching Review in it would.
            let mode = await mode(of: task, context: context)
            PlayhouseDiagnostics.record("plugin.pull_request_mode.chosen", fields: ["taskID": taskID, "mode": mode.rawValue])
            await open(taskID, mode: mode, trigger: "mode", context: context, resetAttempts: true)
        default:
            return
        }
    }

    private func taskReachedReview(_ taskID: String, context: PluginServiceContext) async {
        guard let task = try? await context.call("task.get", ["taskID": .string(taskID)]).object else { return }
        let mode = await mode(of: task, context: context)
        PlayhouseDiagnostics.record("plugin.pull_request_mode.review", fields: ["taskID": taskID, "mode": mode.rawValue])
        await open(taskID, mode: mode, trigger: "review", context: context, resetAttempts: false)
    }

    /// Opens the pull requests a Review task still waits for unless the mode
    /// is manual, then (Green and Merge) follows them.
    private func open(_ taskID: String, mode: PullRequestMode, trigger: String, context: PluginServiceContext, resetAttempts: Bool) async {
        guard mode != .manual else { return }
        do {
            _ = try await context.call("task.pr.create", ["taskID": .string(taskID), "ifNeeded": .bool(true)])
        } catch {
            PlayhouseDiagnostics.record("task.review.auto_pr.failed", fields: ["taskID": taskID, "trigger": trigger, "error": "\(error)"])
            return
        }
        if mode.followsPullRequests { follow(taskID, trigger: trigger, context: context, resetAttempts: resetAttempts) }
    }

    private func followReviewTasks(context: PluginServiceContext) async {
        guard let tasks = try? await context.call("task.list").object?["tasks"]?.array else { return }
        for case .object(let task) in tasks where task["status"]?.string == TaskStatus.review.rawValue {
            guard let taskID = task["id"]?.string, await mode(of: task, context: context).followsPullRequests else { continue }
            throttle.run(key(taskID, context), interval: Self.focusInterval) { [weak self] in
                await self?.followNow(taskID, trigger: "focus", context: context, resetAttempts: false)
            }
        }
    }

    /// A pass asks right before it merges or sends a fix turn: the mode may
    /// have changed while it probed GitHub.
    package func confirms(_ action: String, taskID: String, context: PluginServiceContext) async -> Bool {
        guard let task = try? await context.call("task.get", ["taskID": .string(taskID)]).object,
              task["status"]?.string == TaskStatus.review.rawValue else { return false }
        let mode = await mode(of: task, context: context)
        let confirmed = action == "merge" ? mode == .merge : mode.followsPullRequests
        if !confirmed {
            PlayhouseDiagnostics.record("plugin.pull_request_mode.declined", fields: ["taskID": taskID, "action": action, "mode": mode.rawValue])
        }
        return confirmed
    }

    private func mode(of task: [String: PluginValue], context: PluginServiceContext) async -> PullRequestMode {
        let state = await context.enabledState(of: pluginID) ?? [:]
        return PullRequestMode.resolve(state: state, taskID: task["id"]?.string ?? "", scheduleSourceTaskID: task["scheduleSourceTaskID"]?.string)
    }

    private func key(_ taskID: String, _ context: PluginServiceContext) -> String {
        "\(context.origin.dataDirectory ?? "default"):\(taskID)"
    }

    /// Runs in the background: a pass can send a fix turn that takes minutes,
    /// and the move that started it shouldn't wait for that.
    private func follow(_ taskID: String, trigger: String, context: PluginServiceContext, resetAttempts: Bool = false) {
        BridgeBackgroundWork.start { [weak self] in
            await self?.followNow(taskID, trigger: trigger, context: context, resetAttempts: resetAttempts)
        }
    }

    private func followNow(_ taskID: String, trigger: String, context: PluginServiceContext, resetAttempts: Bool) async {
        // The mode may have changed since the follow was queued.
        guard let task = try? await context.call("task.get", ["taskID": .string(taskID)]).object,
              task["status"]?.string == TaskStatus.review.rawValue else { return }
        let mode = await mode(of: task, context: context)
        guard mode.followsPullRequests else { return }
        PlayhouseDiagnostics.record("plugin.pull_request_mode.follow", fields: ["taskID": taskID, "trigger": trigger, "mode": mode.rawValue])
        let outcome: [String: PluginValue]
        do {
            outcome = try await context.call("task.pr.autopilot", [
                "taskID": .string(taskID), "merge": .bool(mode == .merge), "resetAttempts": .bool(resetAttempts),
                "confirmWith": .string(pluginID)
            ]).object ?? [:]
        } catch {
            PlayhouseDiagnostics.record("task.pr.autopilot.failed", fields: ["taskID": taskID, "error": "\(error)"])
            return
        }
        PlayhouseDiagnostics.record("plugin.pull_request_mode.followed", fields: [
            "taskID": taskID, "trigger": trigger, "action": outcome["action"]?.string ?? ""
        ])
        switch outcome["action"]?.string {
        case "pending":
            // Checks still running: look again in a few minutes.
            schedulePoll(taskID, context: context)
        case "fixed":
            // The fix turn ended; its push usually leaves the checks running,
            // which the next pass finds and polls.
            await followNow(taskID, trigger: "fixed", context: context, resetAttempts: false)
        case "inactive" where outcome["noPullRequest"]?.bool == true:
            // No later pass links a pull request by itself: reaching Review, or
            // choosing a mode in Review, opens it and follows it then.
            PlayhouseDiagnostics.record("plugin.pull_request_mode.no_pull_request", fields: ["taskID": taskID, "trigger": trigger])
        case "inactive" where outcome["taskStatus"]?.string == TaskStatus.review.rawValue:
            // Still in Review but skipped: the turn that moved it there lets go
            // of the task just after, so that pass looks again soon; others wait
            // for the poll.
            schedulePoll(taskID, context: context, after: trigger == "review" ? min(Self.retryInterval, Self.pollInterval) : Self.pollInterval)
        default:
            return
        }
    }

    private func schedulePoll(_ taskID: String, context: PluginServiceContext, after delay: TimeInterval? = nil) {
        let key = key(taskID, context)
        guard pollScheduled.insert(key).inserted else { return }
        let interval = delay ?? Self.pollInterval
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard let self else { return }
            pollScheduled.remove(key)
            await followNow(taskID, trigger: "poll", context: context, resetAttempts: false)
        }
    }
}
