import Foundation
import UserNotifications

/// The local notification that brings the user to the app when a sign
/// request arrives while the app is not on screen (ARCHITECTURE.md,
/// ApprovalFlow). Face ID needs the app in the foreground, so tapping the
/// notification is the first step of an approval.
///
/// Local only: a free Apple developer account has no push notifications.
@MainActor
struct ApprovalNotifier {
    /// Asks for permission to show notifications. iOS shows its question
    /// only the first time; afterwards this just returns. Returns whether
    /// notifications are allowed.
    func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    func post(for request: PendingRequest) {
        let content = UNMutableNotificationContent()
        content.title = "Sign-in request"
        // No server and no user name here: the notification shows on the
        // lock screen, to whoever holds the phone. The details are in the
        // app, behind the unlock.
        // An absolute time: a suspended app cannot remove the notification
        // when the request expires, so it may stay on the lock screen
        // longer, and must not keep saying "30 seconds".
        let expiry = request.expiresAt.formatted(date: .omitted, time: .shortened)
        content.body = "Open SentryKey to review it. It expires at \(expiry)."
        content.sound = .default
        // A nil trigger delivers at once.
        let notification = UNNotificationRequest(
            identifier: Self.identifier(for: request), content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(notification)
    }

    /// Removes the notification of a request that is answered, expired or
    /// cancelled, so a stale one never invites a tap.
    func remove(for request: PendingRequest) {
        let identifiers = [Self.identifier(for: request)]
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private static func identifier(for request: PendingRequest) -> String {
        "sign-request-\(request.id.uuidString)"
    }
}
