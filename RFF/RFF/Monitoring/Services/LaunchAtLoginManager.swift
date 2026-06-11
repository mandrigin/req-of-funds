import Cocoa
import ServiceManagement

// MARK: - Launch at Login Manager

/// Manages the "Launch at Login" functionality using SMAppService (macOS 13+)
///
/// Implementation per spec section 6.3:
/// - Uses SMAppService.mainApp for login item management
/// - Provides UI-friendly status and toggle methods
@available(macOS 13.0, *)
final class LaunchAtLoginManager {

    // MARK: - Singleton

    static let shared = LaunchAtLoginManager()

    // MARK: - Properties

    /// The app service for managing login items
    private let appService = SMAppService.mainApp

    // MARK: - Initialization

    private init() {}

    // MARK: - Public API

    /// Check if the app is currently set to launch at login
    var isEnabled: Bool {
        appService.status == .enabled
    }

    /// Current status of the login item
    var status: SMAppService.Status {
        appService.status
    }

    /// Human-readable status description
    var statusDescription: String {
        switch appService.status {
        case .notRegistered:
            return "Not registered"
        case .enabled:
            return "Enabled"
        case .requiresApproval:
            return "Requires user approval in System Settings"
        case .notFound:
            return "App not found"
        @unknown default:
            return "Unknown status"
        }
    }

    /// Enable launch at login
    /// - Throws: Error if registration fails
    func enable() throws {
        guard appService.status != .enabled else { return }

        do {
            try appService.register()
        } catch {
            throw LaunchAtLoginError.registrationFailed(error)
        }
    }

    /// Disable launch at login
    /// - Throws: Error if unregistration fails
    func disable() throws {
        guard appService.status == .enabled else { return }

        do {
            try appService.unregister()
        } catch {
            throw LaunchAtLoginError.unregistrationFailed(error)
        }
    }

    /// Toggle launch at login state
    /// - Returns: The new enabled state
    /// - Throws: Error if toggle fails
    @discardableResult
    func toggle() throws -> Bool {
        if isEnabled {
            try disable()
            return false
        } else {
            try enable()
            return true
        }
    }

    /// Sync the login item state with the configuration
    /// - Parameter shouldEnable: Whether to enable launch at login
    func sync(with shouldEnable: Bool) {
        do {
            if shouldEnable {
                try enable()
            } else {
                try disable()
            }
        } catch {
            // Log but don't fail - launch at login is not critical
            print("Warning: Failed to sync launch at login state: \(error)")
        }
    }

    /// Open System Settings to the Login Items pane (for user to approve if needed)
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Launch at Login Error

/// Errors that can occur during launch at login management
enum LaunchAtLoginError: LocalizedError {
    case registrationFailed(Error)
    case unregistrationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .registrationFailed(let error):
            return "Failed to enable launch at login: \(error.localizedDescription)"
        case .unregistrationFailed(let error):
            return "Failed to disable launch at login: \(error.localizedDescription)"
        }
    }
}

// MARK: - Fallback for older macOS

/// Fallback manager for macOS < 13.0 using deprecated SMLoginItemSetEnabled
final class LegacyLaunchAtLoginManager {

    static let shared = LegacyLaunchAtLoginManager()

    private let helperBundleIdentifier: CFString

    private init() {
        // This would need to be the bundle identifier of a helper app
        // For simplicity, we use the main app's bundle identifier
        self.helperBundleIdentifier = (Bundle.main.bundleIdentifier ?? "com.example.InvoiceFiler") as CFString
    }

    var isEnabled: Bool {
        // Note: There's no direct way to check this in the deprecated API
        // This is a limitation of the legacy approach
        return false
    }

    func setEnabled(_ enabled: Bool) -> Bool {
        // SMLoginItemSetEnabled is deprecated but still works on older systems
        // In a real app, you'd use a helper tool approach
        return false
    }
}
