import Foundation

package enum ScheduleFormatting {
    /// "Today 15:00", "Tomorrow 09:00", or "Mon 9 Nov, 09:00".
    package static func relativeTime(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow \(time)"
        }
        return "\(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))), \(time)"
    }
}

/// The background agent that runs `playhouse-cli schedule tick` each minute, so schedules fire
/// while the app is closed. It's registered only while a schedule is active, so Playhouse
/// leaves nothing running in the background otherwise. `PlatformServices` registers it: a
/// launch agent on macOS.
@MainActor
package enum SchedulerAgent {
    package static var requiresApproval: Bool {
        Platform.services.schedulerAgentStatus == .requiresApproval
    }

    package static func sync(hasActiveSchedules: Bool) {
        let services = Platform.services
        let status = services.schedulerAgentStatus
        guard status != .unavailable else { return }
        do {
            if hasActiveSchedules {
                guard status != .enabled else { return }
                try services.registerSchedulerAgent()
                PlayhouseDiagnostics.record("scheduler.agent.registered", fields: ["status": String(describing: services.schedulerAgentStatus)])
            } else {
                guard status == .enabled || status == .requiresApproval else { return }
                try services.unregisterSchedulerAgent()
                PlayhouseDiagnostics.record("scheduler.agent.unregistered", fields: [:])
            }
        } catch {
            PlayhouseDiagnostics.record("scheduler.agent.failed", fields: PlayhouseDiagnostics.errorFields(error))
        }
    }
}
