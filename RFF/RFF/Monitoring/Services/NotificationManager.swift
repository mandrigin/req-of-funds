import Foundation
import UserNotifications

/// Manages macOS user notifications for invoice filing events
///
/// Uses UNUserNotificationCenter (requires macOS 10.14+)
@available(macOS 10.14, *)
final class MonitorNotificationManager: NSObject {

    // MARK: - Singleton

    static let shared = MonitorNotificationManager()

    // MARK: - Properties

    private let center = UNUserNotificationCenter.current()
    private var isAuthorized = false

    // MARK: - Initialization

    private override init() {
        super.init()
        center.delegate = self
    }

    // MARK: - Authorization

    /// Request notification authorization
    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            self?.isAuthorized = granted
            if let error = error {
                print("Notification authorization error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Public API

    /// Show notification when an invoice is successfully filed
    /// - Parameters:
    ///   - filename: Name of the filed invoice
    ///   - destinationFolder: Folder where the invoice was moved
    ///   - companyName: Optional company name that was matched
    func showInvoiceFiled(filename: String, destinationFolder: String, companyName: String? = nil) {
        guard isAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Invoice Filed"

        if let company = companyName {
            content.body = "\(filename)\n\(company) \u{2192} \(destinationFolder)"
        } else {
            content.body = "\(filename) \u{2192} \(destinationFolder)"
        }

        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // Deliver immediately
        )

        center.add(request) { error in
            if let error = error {
                print("Failed to deliver notification: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

@available(macOS 10.14, *)
extension MonitorNotificationManager: UNUserNotificationCenterDelegate {

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notification even when app is in foreground
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }
}
