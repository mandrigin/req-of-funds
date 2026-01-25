import Foundation
import EventKit

/// Errors that can occur during calendar operations
enum CalendarError: Error, LocalizedError {
    case accessDenied
    case noCalendarAccess
    case eventCreationFailed
    case eventNotFound

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Calendar access was denied. Please enable in System Settings."
        case .noCalendarAccess:
            return "Calendar access has not been granted."
        case .eventCreationFailed:
            return "Failed to create calendar event."
        case .eventNotFound:
            return "Calendar event not found."
        }
    }
}

/// Service for managing RFF deadlines in the system calendar using EventKit
actor CalendarService {
    /// Shared instance
    static let shared = CalendarService()

    /// The event store for calendar access
    private let eventStore = EKEventStore()

    /// Prefix for identifying RFF-created events
    private let eventNotePrefix = "[RFF Deadline]"

    private init() {}

    // MARK: - Authorization

    /// Request calendar access from the user
    /// - Returns: True if access was granted
    @discardableResult
    func requestAccess() async throws -> Bool {
        if #available(macOS 14.0, *) {
            return try await eventStore.requestFullAccessToEvents()
        } else {
            return try await withCheckedThrowingContinuation { continuation in
                eventStore.requestAccess(to: .event) { granted, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
    }

    /// Check current authorization status
    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// Check if we have calendar access
    var hasAccess: Bool {
        let status = authorizationStatus
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        } else {
            return status == .authorized
        }
    }

    // MARK: - Event Management

    /// Create a calendar event for an RFF deadline
    /// - Parameters:
    ///   - documentId: The unique identifier of the RFF document
    ///   - title: The document title
    ///   - organization: The requesting organization
    ///   - dueDate: The deadline date
    ///   - hoursBeforeAlarm: Hours before deadline to trigger alarm (default 24)
    /// - Returns: The created event identifier
    @discardableResult
    func createDeadlineEvent(
        documentId: UUID,
        title: String,
        organization: String,
        dueDate: Date,
        hoursBeforeAlarm: Int = 24
    ) async throws -> String {
        guard hasAccess else {
            throw CalendarError.noCalendarAccess
        }

        guard let calendar = eventStore.defaultCalendarForNewEvents else {
            throw CalendarError.eventCreationFailed
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = "RFF Deadline: \(title)"
        event.notes = "\(eventNotePrefix)\nDocument ID: \(documentId.uuidString)\nOrganization: \(organization)"
        event.startDate = dueDate
        event.endDate = dueDate.addingTimeInterval(3600) // 1 hour duration
        event.calendar = calendar
        event.isAllDay = false

        // Add alarm for 24 hours before
        let alarmOffset = -Double(hoursBeforeAlarm * 3600)
        let alarm = EKAlarm(relativeOffset: alarmOffset)
        event.addAlarm(alarm)

        // Add a second alarm for 1 hour before as a final reminder
        let finalAlarm = EKAlarm(relativeOffset: -3600)
        event.addAlarm(finalAlarm)

        do {
            try eventStore.save(event, span: .thisEvent)
            return event.eventIdentifier
        } catch {
            throw CalendarError.eventCreationFailed
        }
    }

    /// Remove a calendar event by document ID
    /// - Parameter documentId: The RFF document's unique identifier
    func removeDeadlineEvent(for documentId: UUID) async throws {
        guard hasAccess else {
            return
        }

        // Search for events containing this document ID in notes
        let startDate = Date().addingTimeInterval(-86400) // Yesterday
        let endDate = Date().addingTimeInterval(365 * 86400) // 1 year from now

        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: nil
        )

        let events = eventStore.events(matching: predicate)
        let documentIdString = documentId.uuidString

        for event in events {
            if let notes = event.notes,
               notes.contains(eventNotePrefix),
               notes.contains(documentIdString) {
                try eventStore.remove(event, span: .thisEvent)
            }
        }
    }

    /// Update an existing calendar event's date
    /// - Parameters:
    ///   - documentId: The RFF document's unique identifier
    ///   - newDueDate: The new deadline date
    func updateDeadlineEvent(for documentId: UUID, newDueDate: Date) async throws {
        guard hasAccess else {
            return
        }

        // Search for events containing this document ID
        let startDate = Date().addingTimeInterval(-86400)
        let endDate = Date().addingTimeInterval(365 * 86400)

        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: nil
        )

        let events = eventStore.events(matching: predicate)
        let documentIdString = documentId.uuidString

        for event in events {
            if let notes = event.notes,
               notes.contains(eventNotePrefix),
               notes.contains(documentIdString) {
                event.startDate = newDueDate
                event.endDate = newDueDate.addingTimeInterval(3600)
                try eventStore.save(event, span: .thisEvent)
                return
            }
        }
    }

    /// Get all RFF-related calendar events
    func getAllRFFEvents() async -> [EKEvent] {
        guard hasAccess else {
            return []
        }

        let startDate = Date().addingTimeInterval(-86400)
        let endDate = Date().addingTimeInterval(365 * 86400)

        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: nil
        )

        let events = eventStore.events(matching: predicate)

        return events.filter { event in
            event.notes?.contains(eventNotePrefix) == true
        }
    }
}
