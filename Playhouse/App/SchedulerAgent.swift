import ServiceManagement
import SwiftUI

enum ScheduleFormatting {
    /// "Today 15:00", "Tomorrow 09:00", or "Mon 9 Nov, 09:00".
    static func relativeTime(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow \(time)"
        }
        return "\(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))), \(time)"
    }
}

/// The LaunchAgent that runs `playhouse-cli schedule tick` each minute, so schedules fire
/// while the app is closed. It's registered only while a schedule is active, so Playhouse
/// leaves nothing running in the background otherwise.
@MainActor
enum SchedulerAgent {
    private static var service: SMAppService? {
        guard let identifier = Bundle.main.bundleIdentifier,
              !BridgeContract.isTestBundle(PlayhouseAppIdentity.applicationIdentifier) else { return nil }
        let plistName = "\(identifier).scheduler.plist"
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(plistName)").path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return SMAppService.agent(plistName: plistName)
    }

    static var requiresApproval: Bool {
        service?.status == .requiresApproval
    }

    static func sync(hasActiveSchedules: Bool) {
        guard let service else { return }
        do {
            if hasActiveSchedules {
                guard service.status != .enabled else { return }
                try service.register()
                PlayhouseDiagnostics.record("scheduler.agent.registered", fields: ["status": String(describing: service.status.rawValue)])
            } else {
                guard service.status == .enabled || service.status == .requiresApproval else { return }
                try service.unregister()
                PlayhouseDiagnostics.record("scheduler.agent.unregistered", fields: [:])
            }
        } catch {
            PlayhouseDiagnostics.record("scheduler.agent.failed", fields: PlayhouseDiagnostics.errorFields(error))
        }
    }
}
