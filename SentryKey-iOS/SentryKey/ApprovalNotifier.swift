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
    /// Asks for permission to show notifications. Called once pairing is
    /// done, when the user has just learnt why the app would notify them.
    func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func post(for request: PendingRequest) {
        let content = UNMutableNotificationContent()
        content.title = "Sign-in request"
        // No server and no user name here: the notification shows on the
        // lock screen, to whoever holds the phone. The details are in the
        // app, behind the unlock.
        content.body = "Open SentryKey to review it. It expires in \(Int(AppModel.answerTime)) seconds."
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
