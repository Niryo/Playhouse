import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

/// Streamed text a conversation window has received but not yet applied.
/// A reference, so the scheduled apply and the stream share one buffer without
/// every buffered delta invalidating the view.
@MainActor
package final class PendingStreamedTextDeltas {
    package var messageID: String?
    package var taskID: UUID?
    package var text = ""
    package var isApplyScheduled = false
}
/// The schedule chosen in the composer's hint, before Send saves it.
package struct ComposerSchedule: Equatable {
    package var kind: TaskScheduleKind = .once
    package var fireAt: Date = ComposerSchedule.nextFullHour()
    package var title = ""
    package var preset: TaskRecurrence.Preset = .daily
    /// The hour and minute of a daily, weekday or weekly run.
    package var time: Date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now
    /// The minute past the hour of an hourly run.
    package var minute = 0
    package var weekday = 2

    package init() {}

    package init?(task: BoardTask) {
        guard let kind = task.scheduleKind else { return nil }
        self.kind = kind
        if kind == .once {
            fireAt = task.scheduledAt ?? Self.nextFullHour()
        } else if let recurrence = task.scheduleRecurrence {
            title = task.title
            preset = recurrence.preset
            time = Calendar.current.date(bySettingHour: recurrence.hour, minute: recurrence.minute, second: 0, of: .now) ?? .now
            minute = recurrence.minute
            weekday = recurrence.weekday ?? 2
        }
    }

    /// The next full hour at least five minutes away, so the default can't pass while the
    /// hint is still open.
    package static func nextFullHour(after now: Date = .now) -> Date {
        Calendar.current.nextDate(after: now.addingTimeInterval(300), matching: DateComponents(minute: 0, second: 0), matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(3600)
    }

    package var recurrence: TaskRecurrence {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        return TaskRecurrence(
            preset: preset,
            hour: parts.hour ?? 9,
            minute: preset == .hourly ? minute : (parts.minute ?? 0),
            weekday: preset == .weekly ? weekday : nil
        )
    }

    package func validationMessage(now: Date = .now) -> String? {
        switch kind {
        case .once:
            return fireAt > now ? nil : "Choose a time in the future."
        case .recurring:
            return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Give the recurring task a title." : nil
        }
    }

    package func summary(now: Date = .now) -> String {
        switch kind {
        case .once:
            return "Runs \(ScheduleFormatting.relativeTime(fireAt, now: now))"
        case .recurring:
            let next = recurrence.nextOccurrence(after: now)
            return "\(recurrence.summary()) · next \(ScheduleFormatting.relativeTime(next, now: now))"
        }
    }

    package func request(prompt: String, imageDataURLs: [String], mode: ConversationMode, modelID: String?) -> TaskScheduleRequest {
        TaskScheduleRequest(
            kind: kind,
            fireAt: kind == .once ? fireAt : nil,
            recurrence: kind == .recurring ? recurrence : nil,
            title: kind == .recurring ? title : nil,
            prompt: prompt,
            imageDataURLs: imageDataURLs,
            mode: mode,
            modelID: modelID
        )
    }
}

