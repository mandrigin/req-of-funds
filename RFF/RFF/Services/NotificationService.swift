import Foundation
import UserNotifications

/// Notification category identifier for deadline reminders
let kRFFDeadlineCategory = "RFF_DEADLINE"

/// Action identifiers for deadline notification buttons
enum NotificationAction: String {
    case snoozeOneHour = "SNOOZE_ONE_HOUR"
    case markComplete = "MARK_COMPLETE"
}

/// Service for managing deadline notifications using UserNotifications framework
actor NotificationService {
    /// Shared instance
    static let shared = NotificationService()

    /// The notification center
    private let center = UNUserNotificationCenter.current()

    private init() {}

    // MARK: - Authorization

    /// Request notification authorization from the user
    /// - Returns: True if authorization was granted
    @discardableResult
    func requestAuthorization() async throws -> Bool {
        let options: UNAuthorizationOptions = [.alert, .sound, .badge]
        let granted = try await center.requestAuthorization(options: options)

        if granted {
            await registerNotificationCategory()
        }

        return granted
    }

    /// Check current authorization status
    func authorizationStatus() async -> UNAuthorizationStatus {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus
    }

    // MARK: - Category Registration

    /// Register the RFF_DEADLINE notification category with action buttons
    private func registerNotificationCategory() async {
        let snoozeAction = UNNotificationAction(
            identifier: NotificationAction.snoozeOneHour.rawValue,
            title: "Snooze 1 Hour",
            options: []
        )

        let markCompleteAction = UNNotificationAction(
            identifier: NotificationAction.markComplete.rawValue,
            title: "Mark Complete",
            options: [.authenticationRequired]
        )

        let category = UNNotificationCategory(
            identifier: kRFFDeadlineCategory,
            actions: [snoozeAction, markCompleteAction],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "RFF Deadline Reminder",
            options: [.customDismissAction]
        )

        center.setNotificationCategories([category])
    }

    // MARK: - Scheduling Notifications

    /// Schedule a deadline notification for an RFF document
    /// - Parameters:
    ///   - documentId: The unique identifier of the RFF document
    ///   - title: The document title
    ///   - organization: The requesting organization
    ///   - dueDate: The deadline date
    ///   - hoursBeforeDeadline: Hours before deadline to send notification (default 24)
    func scheduleDeadlineNotification(
        documentId: UUID,
        title: String,
        organization: String,
        dueDate: Date,
        hoursBeforeDeadline: Int = 24
    ) async throws {
        // Check authorization first
        let status = await authorizationStatus()
        guard status == .authorized else {
            return
        }

        // Calculate notification date (24 hours before deadline)
        let notificationDate = dueDate.addingTimeInterval(-Double(hoursBeforeDeadline * 3600))

        // Don't schedule if the notification time has already passed
        guard notificationDate > Date() else {
            return
        }

        // Create notification content
        let content = UNMutableNotificationContent()
        content.title = "RFF Deadline Reminder"
        content.body = "\(title) from \(organization) is due in \(hoursBeforeDeadline) hours"
        content.sound = .default
        content.categoryIdentifier = kRFFDeadlineCategory
        content.threadIdentifier = "rff-deadlines"
        content.userInfo = [
            "documentId": documentId.uuidString,
            "title": title,
            "dueDate": dueDate.timeIntervalSince1970
        ]

        // Create calendar-based trigger
        let calendar = Calendar.current
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: notificationDate
        )

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: components,
            repeats: false
        )

        // Create and add the request
        let identifier = notificationIdentifier(for: documentId)
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )

        try await center.add(request)
    }

    /// Cancel a scheduled notification for a document
    /// - Parameter documentId: The document's unique identifier
    func cancelNotification(for documentId: UUID) {
        let identifier = notificationIdentifier(for: documentId)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// Cancel all scheduled RFF notifications
    func cancelAllNotifications() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    /// Reschedule notification for snooze (1 hour from now)
    /// - Parameters:
    ///   - documentId: The document's unique identifier
    ///   - originalTitle: The original document title
    ///   - organization: The requesting organization
    func snoozeNotification(
        documentId: UUID,
        title: String,
        organization: String
    ) async throws {
        // Cancel existing notification
        cancelNotification(for: documentId)

        // Schedule new notification for 1 hour from now
        let snoozeDate = Date().addingTimeInterval(3600) // 1 hour

        let content = UNMutableNotificationContent()
        content.title = "RFF Deadline Reminder (Snoozed)"
        content.body = "\(title) from \(organization) - reminder snoozed"
        content.sound = .default
        content.categoryIdentifier = kRFFDeadlineCategory
        content.threadIdentifier = "rff-deadlines"
        content.userInfo = [
            "documentId": documentId.uuidString,
            "title": title,
            "snoozed": true
        ]

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: 3600,
            repeats: false
        )

        let identifier = notificationIdentifier(for: documentId, snoozed: true)
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )

        try await center.add(request)
    }

    /// Get all pending notification requests
    func pendingNotifications() async -> [UNNotificationRequest] {
        await center.pendingNotificationRequests()
    }

    // MARK: - Private Helpers

    /// Generate a consistent notification identifier for a document
    private func notificationIdentifier(for documentId: UUID, snoozed: Bool = false) -> String {
        let suffix = snoozed ? "-snoozed" : ""
        return "rff-deadline-\(documentId.uuidString)\(suffix)"
    }
}
