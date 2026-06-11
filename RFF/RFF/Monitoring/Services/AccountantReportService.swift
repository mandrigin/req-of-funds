import Foundation
import UserNotifications

/// Stats for one accountant month folder (invoices-MM-YYYY)
struct MonthFolderStats {
    let folderName: String
    let folderURL: URL?
    let fileCount: Int
}

/// Everything around the every-12th accountant report:
/// folder stats for the dashboard and a non-intrusive reminder notification.
enum AccountantReportService {

    /// The accountant-critical folder name for a given month: invoices-MM-YYYY
    static func folderName(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "invoices-%02d-%04d", components.month ?? 1, components.year ?? 2000)
    }

    /// Roots where invoice folders may live: destinationRoot if set, else every monitored path
    static func candidateRoots() -> [URL] {
        let config = ConfigManager.shared.config
        if let root = config.destinationRoot {
            return [root]
        }
        return config.monitoredPaths.map { $0.path }
    }

    /// Count files in the month folder across all candidate roots
    static func stats(for date: Date) -> MonthFolderStats {
        let name = folderName(for: date)
        let fileManager = FileManager.default
        var total = 0
        var foundURL: URL?

        for root in candidateRoots() {
            let folder = root.appendingPathComponent(name)
            guard let contents = try? fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            total += contents.count
            if foundURL == nil { foundURL = folder }
        }

        return MonthFolderStats(folderName: name, folderURL: foundURL, fileCount: total)
    }

    /// Next upcoming report date (the 12th, 09:00)
    static func nextReportDate(after date: Date = Date()) -> Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month], from: date)
        components.day = 12
        components.hour = 9
        if let thisMonth = calendar.date(from: components), thisMonth > date {
            return thisMonth
        }
        components.month = (components.month ?? 1) + 1
        return calendar.date(from: components) ?? date
    }

    /// Whole days until the next report
    static func daysUntilReport(from date: Date = Date()) -> Int {
        let target = Calendar.current.startOfDay(for: nextReportDate(after: date))
        let today = Calendar.current.startOfDay(for: date)
        return Calendar.current.dateComponents([.day], from: today, to: target).day ?? 0
    }

    /// The month the report on the next 12th covers (the previous calendar month)
    static func reportMonth(for reportDate: Date) -> Date {
        Calendar.current.date(byAdding: .month, value: -1, to: reportDate) ?? reportDate
    }

    /// (Re)schedule the non-intrusive reminder for the next 12th at 09:00.
    /// Counts come from the app database (Reporting tab is the source of truth).
    static func scheduleReminder(inbound: Int, outbound: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["accountant-report"])

        let reportDate = nextReportDate()
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMMM"
        let monthName = monthFormatter.string(from: reportMonth(for: reportDate))

        let content = UNMutableNotificationContent()
        content.title = "Accountant report day"
        content.body = "\(monthName): \(inbound) paid bill\(inbound == 1 ? "" : "s"), \(outbound) outgoing invoice\(outbound == 1 ? "" : "s"). Open RFF → Reporting to export."
        content.sound = nil  // non-intrusive

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: reportDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: "accountant-report", content: content, trigger: trigger)
        center.add(request)
    }
}
