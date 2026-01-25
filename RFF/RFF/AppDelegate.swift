import AppKit
import UserNotifications
import SwiftData

/// App delegate for handling notification actions and app lifecycle
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Reference to the model container, set by the app
    var modelContainer: ModelContainer?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set ourselves as the notification center delegate
        UNUserNotificationCenter.current().delegate = self

        // Request notification authorization on first launch
        Task {
            try? await NotificationService.shared.requestAuthorization()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup if needed
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Handle notification actions (snooze, mark complete)
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        guard let documentIdString = userInfo["documentId"] as? String,
              let documentId = UUID(uuidString: documentIdString) else {
            completionHandler()
            return
        }

        let title = userInfo["title"] as? String ?? "RFF Document"

        switch response.actionIdentifier {
        case NotificationAction.snoozeOneHour.rawValue:
            handleSnoozeAction(documentId: documentId, title: title)

        case NotificationAction.markComplete.rawValue:
            handleMarkCompleteAction(documentId: documentId)

        case UNNotificationDismissActionIdentifier:
            // User dismissed the notification
            break

        case UNNotificationDefaultActionIdentifier:
            // User tapped the notification - could open the document
            NotificationCenter.default.post(
                name: .openDocument,
                object: nil,
                userInfo: ["documentId": documentId]
            )

        default:
            break
        }

        completionHandler()
    }

    /// Handle notification when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notification even when app is in foreground
        completionHandler([.banner, .sound, .badge])
    }

    // MARK: - Action Handlers

    private func handleSnoozeAction(documentId: UUID, title: String) {
        Task {
            // Get organization from document if available
            let organization = await fetchOrganization(for: documentId) ?? "Unknown"

            try? await NotificationService.shared.snoozeNotification(
                documentId: documentId,
                title: title,
                organization: organization
            )
        }
    }

    private func handleMarkCompleteAction(documentId: UUID) {
        Task { @MainActor in
            guard let container = modelContainer else { return }

            let context = container.mainContext
            let predicate = #Predicate<RFFDocument> { $0.id == documentId }
            var descriptor = FetchDescriptor<RFFDocument>(predicate: predicate)
            descriptor.fetchLimit = 1

            guard let document = try? context.fetch(descriptor).first else {
                return
            }

            document.status = .completed
            document.updatedAt = Date()

            try? context.save()

            // Cancel the notification since document is complete
            await NotificationService.shared.cancelNotification(for: documentId)

            // Post notification for UI update
            NotificationCenter.default.post(
                name: .documentStatusChanged,
                object: nil,
                userInfo: ["documentId": documentId, "status": RFFStatus.completed]
            )
        }
    }

    private func fetchOrganization(for documentId: UUID) async -> String? {
        await MainActor.run {
            guard let container = modelContainer else { return nil }

            let context = container.mainContext
            let predicate = #Predicate<RFFDocument> { $0.id == documentId }
            var descriptor = FetchDescriptor<RFFDocument>(predicate: predicate)
            descriptor.fetchLimit = 1

            return try? context.fetch(descriptor).first?.requestingOrganization
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when a document should be opened from a notification
    static let openDocument = Notification.Name("RFF.openDocument")

    /// Posted when a document's status changes from a notification action
    static let documentStatusChanged = Notification.Name("RFF.documentStatusChanged")
}
