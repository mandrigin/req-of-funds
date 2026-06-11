import Cocoa

// MARK: - Permission Status

/// Status of Full Disk Access permission
enum FullDiskAccessStatus {
    /// Permission has been granted
    case granted

    /// Permission has not been granted or is unknown
    case notGranted

    /// Permission status cannot be determined
    case unknown
}

// MARK: - Permission Manager

/// Manages Full Disk Access permission checking and user prompting
///
/// Implementation per spec section 6.3:
/// - Prompt user with instructions on first launch if access is denied
/// - Non-sandboxed app requires Full Disk Access for monitoring protected directories
final class PermissionManager {

    // MARK: - Singleton

    static let shared = PermissionManager()

    // MARK: - Constants

    /// UserDefaults key for tracking if we've shown the permission prompt
    private static let hasShownPermissionPromptKey = "hasShownFullDiskAccessPrompt"

    /// A protected directory we can test access against
    /// Desktop is a good test - requires Full Disk Access if denied
    private static let testDirectories: [String] = [
        NSHomeDirectory() + "/Library/Safari",  // Safari data is protected
        NSHomeDirectory() + "/Library/Mail",     // Mail data is protected
    ]

    // MARK: - Properties

    private let fileManager = FileManager.default

    // MARK: - Initialization

    private init() {}

    // MARK: - Public API

    /// Check if Full Disk Access has been granted
    /// Note: This is a heuristic - macOS doesn't provide a direct API to check FDA
    var fullDiskAccessStatus: FullDiskAccessStatus {
        // Try to access a protected location
        for testPath in Self.testDirectories {
            if canAccessDirectory(testPath) {
                return .granted
            }
        }

        // If we couldn't access any protected location, FDA is likely not granted
        // However, it's possible those directories just don't exist
        return .notGranted
    }

    /// Check if we have access to a specific directory
    func hasAccessTo(_ url: URL) -> Bool {
        return canAccessDirectory(url.path)
    }

    /// Check if we've already shown the permission prompt
    var hasShownPermissionPrompt: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasShownPermissionPromptKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasShownPermissionPromptKey) }
    }

    /// Show the Full Disk Access permission prompt if needed
    /// - Parameter force: Show even if we've shown before
    /// - Returns: true if the user was prompted
    @discardableResult
    func promptForFullDiskAccessIfNeeded(force: Bool = false) -> Bool {
        // Skip if we already have access
        if fullDiskAccessStatus == .granted {
            return false
        }

        // Skip if we've already shown and not forcing
        if !force && hasShownPermissionPrompt {
            return false
        }

        showFullDiskAccessPrompt()
        hasShownPermissionPrompt = true
        return true
    }

    /// Open System Settings to Security & Privacy > Full Disk Access
    func openFullDiskAccessSettings() {
        // On macOS 13+, use the new URL scheme
        if #available(macOS 13.0, *) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
                return
            }
        }

        // Fallback for older macOS
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Private Methods

    /// Check if we can access a directory
    private func canAccessDirectory(_ path: String) -> Bool {
        // Check if directory exists
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            // Directory doesn't exist - can't determine
            return false
        }

        // Try to read contents
        do {
            _ = try fileManager.contentsOfDirectory(atPath: path)
            return true
        } catch {
            // If we get a permission error, we don't have access
            return false
        }
    }

    /// Show the Full Disk Access prompt dialog
    private func showFullDiskAccessPrompt() {
        let alert = NSAlert()
        alert.messageText = "Full Disk Access Required"
        alert.informativeText = """
        Invoice Filer needs Full Disk Access to monitor your Downloads folder and other directories for invoice files.

        Please grant Full Disk Access in System Settings:
        1. Click "Open System Settings" below
        2. Find "Invoice Filer" in the list
        3. Enable the toggle next to it
        4. Restart Invoice Filer if needed

        Without this permission, the app cannot automatically detect and file your invoices.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        // Add an icon to help identify the app
        if let appIcon = NSImage(named: NSImage.applicationIconName) {
            alert.icon = appIcon
        }

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            openFullDiskAccessSettings()
        }
    }
}

// MARK: - Monitored Path Validation

extension PermissionManager {

    /// Validate that we have access to all monitored paths
    /// - Parameter paths: URLs to check
    /// - Returns: List of paths we cannot access
    func validateMonitoredPaths(_ paths: [URL]) -> [URL] {
        return paths.filter { !hasAccessTo($0) }
    }

    /// Check if a URL is accessible for monitoring
    /// - Parameter url: URL to check
    /// - Returns: Detailed access result
    func checkAccessForMonitoring(_ url: URL) -> (canRead: Bool, canExecute: Bool, exists: Bool) {
        let path = url.path

        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)

        guard exists && isDirectory.boolValue else {
            return (false, false, false)
        }

        let canRead = fileManager.isReadableFile(atPath: path)
        let canExecute = fileManager.isExecutableFile(atPath: path) // For directories, this means we can access contents

        return (canRead, canExecute, exists)
    }
}
