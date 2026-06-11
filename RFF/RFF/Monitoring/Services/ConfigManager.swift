import Foundation
import Combine

/// Manages loading, saving, and observing application configuration
final class ConfigManager: ObservableObject {
    // MARK: - Singleton

    static let shared = ConfigManager()

    // MARK: - Published Properties

    /// Current configuration
    @Published private(set) var config: AppConfig

    /// Last error encountered during load/save
    @Published private(set) var lastError: Error?

    // MARK: - Constants

    private static let configFileName = "monitoring.json"
    private static let appSupportFolderName = "RFF"

    /// Legacy InvoiceFiler app support directory (configs are inherited from here once)
    static var legacyInvoiceFilerDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("InvoiceFiler")
    }

    // MARK: - UserDefaults Keys

    private enum UserDefaultsKey {
        static let launchAtLogin = "launchAtLogin"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let lastProcessedFile = "lastProcessedFile"
        static let totalFilesProcessed = "totalFilesProcessed"
    }

    // MARK: - Paths

    /// Application Support directory for InvoiceFiler
    var appSupportDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(Self.appSupportFolderName)
    }

    /// Path to config.json file
    var configFileURL: URL {
        appSupportDirectory.appendingPathComponent(Self.configFileName)
    }

    // MARK: - Initialization

    private init() {
        self.config = AppConfig.default
        migrateFromInvoiceFilerIfNeeded()
        loadConfig()
    }

    // MARK: - InvoiceFiler Inheritance

    /// One-time migration: inherit config, invoice templates/drafts, holiday cache and
    /// move log from a previous InvoiceFiler installation. Originals are left untouched.
    private func migrateFromInvoiceFilerIfNeeded() {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: configFileURL.path) else { return }

        let legacyDir = Self.legacyInvoiceFilerDirectory
        let legacyConfig = legacyDir.appendingPathComponent("config.json")
        guard fileManager.fileExists(atPath: legacyConfig.path) else { return }

        try? ensureAppSupportDirectoryExists()

        // Config: copy, but point the log at RFF's own log directory
        if let data = try? Data(contentsOf: legacyConfig),
           var inherited = try? JSONDecoder().decode(AppConfig.self, from: data) {
            let newLogDir = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Logs").appendingPathComponent("RFF")
            let oldLog = inherited.logLocation
            inherited.logLocation = newLogDir.appendingPathComponent("moves.jsonl")

            // Preserve filing history so 24h stats and the dashboard stay continuous
            try? fileManager.createDirectory(at: newLogDir, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: oldLog.path),
               !fileManager.fileExists(atPath: inherited.logLocation.path) {
                try? fileManager.copyItem(at: oldLog, to: inherited.logLocation)
            }

            if let encoded = try? {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                return try encoder.encode(inherited)
            }() {
                try? encoded.write(to: configFileURL, options: .atomic)
            }
        }

        // Invoice templates, drafts, number sequence
        let legacyInvoices = legacyDir.appendingPathComponent("Invoices")
        let newInvoices = appSupportDirectory.appendingPathComponent("Invoices")
        if fileManager.fileExists(atPath: legacyInvoices.path),
           !fileManager.fileExists(atPath: newInvoices.path) {
            try? fileManager.copyItem(at: legacyInvoices, to: newInvoices)
        }

        // Bank holiday cache
        let legacyCache = legacyDir.appendingPathComponent("Cache")
        let newCache = appSupportDirectory.appendingPathComponent("Cache")
        if fileManager.fileExists(atPath: legacyCache.path),
           !fileManager.fileExists(atPath: newCache.path) {
            try? fileManager.copyItem(at: legacyCache, to: newCache)
        }
    }

    // For testing
    internal init(config: AppConfig) {
        self.config = config
    }

    // MARK: - Loading

    /// Load configuration from disk
    func loadConfig() {
        do {
            config = try loadConfigFromDisk()
            lastError = nil
        } catch {
            // If file doesn't exist, use defaults
            if (error as NSError).domain == NSCocoaErrorDomain &&
               (error as NSError).code == NSFileReadNoSuchFileError {
                config = AppConfig.default
                lastError = nil
            } else {
                lastError = error
                config = AppConfig.default
            }
        }

        // Sync UserDefaults values
        syncFromUserDefaults()
    }

    private func loadConfigFromDisk() throws -> AppConfig {
        let data = try Data(contentsOf: configFileURL)
        let decoder = JSONDecoder()
        var loadedConfig = try decoder.decode(AppConfig.self, from: data)

        // Handle version migration if needed
        if loadedConfig.version < AppConfig.currentVersion {
            loadedConfig = migrate(config: loadedConfig)
        }

        return loadedConfig
    }

    // MARK: - Saving

    /// Save current configuration to disk
    func saveConfig() throws {
        try ensureAppSupportDirectoryExists()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)

        try data.write(to: configFileURL, options: .atomic)

        // Sync to UserDefaults
        syncToUserDefaults()

        lastError = nil
    }

    /// Update configuration with a transform closure and save
    func updateConfig(_ transform: (inout AppConfig) -> Void) throws {
        var newConfig = config
        transform(&newConfig)
        config = newConfig
        try saveConfig()
    }

    // MARK: - Directory Management

    private func ensureAppSupportDirectoryExists() throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: appSupportDirectory.path) {
            try fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        }
    }

    /// Ensure log directory exists
    func ensureLogDirectoryExists() throws {
        let logDir = config.logLocation.deletingLastPathComponent()
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: logDir.path) {
            try fileManager.createDirectory(at: logDir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Migration

    private func migrate(config: AppConfig) -> AppConfig {
        var migrated = config
        migrated.version = AppConfig.currentVersion

        // Add migration logic here as versions evolve
        // Example:
        // if config.version < 2 {
        //     migrated.newField = defaultValue
        // }

        return migrated
    }

    // MARK: - UserDefaults Integration

    /// Simple settings stored in UserDefaults for quick access
    private func syncToUserDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(config.launchAtLogin, forKey: UserDefaultsKey.launchAtLogin)
    }

    private func syncFromUserDefaults() {
        // UserDefaults can override certain quick-access settings
        // For now, config.json is the source of truth
    }

    /// Whether the user has completed initial onboarding
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: UserDefaultsKey.hasCompletedOnboarding) }
        set { UserDefaults.standard.set(newValue, forKey: UserDefaultsKey.hasCompletedOnboarding) }
    }

    /// Path of the last processed file (for status display)
    var lastProcessedFile: String? {
        get { UserDefaults.standard.string(forKey: UserDefaultsKey.lastProcessedFile) }
        set { UserDefaults.standard.set(newValue, forKey: UserDefaultsKey.lastProcessedFile) }
    }

    /// Total number of files processed in this session
    var totalFilesProcessed: Int {
        get { UserDefaults.standard.integer(forKey: UserDefaultsKey.totalFilesProcessed) }
        set { UserDefaults.standard.set(newValue, forKey: UserDefaultsKey.totalFilesProcessed) }
    }

    // MARK: - Convenience Accessors

    /// Returns companies as an array (convenience for matching)
    var companies: [CompanyConfig] {
        config.companies
    }

    /// Returns monitored paths
    var monitoredPaths: [MonitoredPath] {
        config.monitoredPaths
    }

    /// Check if a file extension is supported
    func isExtensionSupported(_ ext: String) -> Bool {
        config.supportedExtensions.contains(ext.lowercased())
    }

    /// Check if a filename matches any exclusion pattern
    func matchesExclusionPattern(_ filename: String) -> Bool {
        for pattern in config.exclusionPatterns {
            if matchesGlob(filename: filename, pattern: pattern) {
                return true
            }
        }
        return false
    }

    private func matchesGlob(filename: String, pattern: String) -> Bool {
        // Simple glob matching for common patterns
        // Supports: *, ?, and character literals

        if pattern == "*" {
            return true
        }

        // Handle prefix patterns like ".*" (hidden files)
        if pattern.hasPrefix(".") && pattern.dropFirst() == "*" {
            return filename.hasPrefix(".")
        }

        // Handle suffix patterns like "*.tmp"
        if pattern.hasPrefix("*") {
            let suffix = String(pattern.dropFirst())
            return filename.hasSuffix(suffix)
        }

        // Handle prefix patterns like "temp*"
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return filename.hasPrefix(prefix)
        }

        // Exact match
        return filename == pattern
    }

    // MARK: - Company Management

    /// Add a new company to the configuration
    func addCompany(_ company: CompanyConfig) throws {
        try updateConfig { config in
            config.companies.append(company)
        }
    }

    /// Remove a company by name
    func removeCompany(named name: String) throws {
        try updateConfig { config in
            config.companies.removeAll { $0.name == name }
        }
    }

    /// Update an existing company
    func updateCompany(_ company: CompanyConfig) throws {
        try updateConfig { config in
            if let index = config.companies.firstIndex(where: { $0.name == company.name }) {
                config.companies[index] = company
            }
        }
    }

    // MARK: - Monitored Path Management

    /// Add a monitored path
    func addMonitoredPath(_ path: MonitoredPath) throws {
        try updateConfig { config in
            if !config.monitoredPaths.contains(where: { $0.path == path.path }) {
                config.monitoredPaths.append(path)
            }
        }
    }

    /// Remove a monitored path
    func removeMonitoredPath(at url: URL) throws {
        try updateConfig { config in
            config.monitoredPaths.removeAll { $0.path == url }
        }
    }

    /// Create default config file if it doesn't exist
    func createDefaultConfigIfNeeded() {
        let fileManager = FileManager.default

        // Create app support directory
        if !fileManager.fileExists(atPath: appSupportDirectory.path) {
            try? fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        }

        // Create config file with defaults and example
        if !fileManager.fileExists(atPath: configFileURL.path) {
            // Create a default config with helpful example
            var exampleConfig = AppConfig.default

            // Add example monitored path (Downloads)
            if let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                exampleConfig.monitoredPaths = [MonitoredPath(path: downloadsURL, recursive: false)]
            }

            // Add example company
            exampleConfig.companies = [
                CompanyConfig(
                    name: "Example Company",
                    aliases: ["Example Corp", "Example Inc"],
                    taxIds: ["12-3456789"],
                    domains: ["example.com"]
                )
            ]

            config = exampleConfig
            try? saveConfig()
        }
    }
}

// MARK: - Error Types

extension ConfigManager {
    enum ConfigError: LocalizedError {
        case saveFailed(Error)
        case loadFailed(Error)
        case validationFailed([AppConfig.ValidationError])
        case directoryCreationFailed(Error)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let error):
                return "Failed to save configuration: \(error.localizedDescription)"
            case .loadFailed(let error):
                return "Failed to load configuration: \(error.localizedDescription)"
            case .validationFailed(let errors):
                return "Configuration validation failed:\n" + errors.map { "• \($0.localizedDescription)" }.joined(separator: "\n")
            case .directoryCreationFailed(let error):
                return "Failed to create directory: \(error.localizedDescription)"
            }
        }
    }
}
