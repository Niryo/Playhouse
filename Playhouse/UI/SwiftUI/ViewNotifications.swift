#if canImport(SwiftUI)
import SwiftUI
import PlayhouseCore

extension View {
    /// Runs `action` on the main actor for each `name` notification posted while the view is
    /// shown, without Combine: the view follows the notification center's async sequence.
    package func onNotification(_ name: Notification.Name, perform action: @escaping @MainActor (Notification) -> Void) -> some View {
        task(id: name) {
            for await notification in NotificationCenter.default.notifications(named: name) {
                action(notification)
            }
        }
    }
}
#endif
