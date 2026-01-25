import Foundation
import Security

/// Errors that can occur during Keychain operations
enum KeychainError: Error, LocalizedError {
    case itemNotFound
    case duplicateItem
    case unexpectedData
    case authenticationFailed
    case accessDenied
    case unhandledError(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "The requested item was not found in the Keychain."
        case .duplicateItem:
            return "An item with this key already exists in the Keychain."
        case .unexpectedData:
            return "The Keychain returned data in an unexpected format."
        case .authenticationFailed:
            return "Biometric authentication failed."
        case .accessDenied:
            return "Access to the Keychain item was denied."
        case .unhandledError(let status):
            return "Keychain error: \(status)"
        }
    }
}

/// Configuration options for Keychain storage
struct KeychainConfiguration {
    /// Whether to require biometric authentication (Touch ID/Face ID) for access
    let requireBiometrics: Bool

    /// Service identifier for the Keychain items
    let service: String

    /// Default configuration with biometrics disabled
    static let `default` = KeychainConfiguration(
        requireBiometrics: false,
        service: Bundle.main.bundleIdentifier ?? "com.rff.app"
    )

    /// Configuration with biometric protection enabled
    static let biometric = KeychainConfiguration(
        requireBiometrics: true,
        service: Bundle.main.bundleIdentifier ?? "com.rff.app"
    )
}

/// Manages secure storage of sensitive data in the macOS Keychain
/// with optional Touch ID protection
final class KeychainManager {

    private let configuration: KeychainConfiguration

    init(configuration: KeychainConfiguration = .default) {
        self.configuration = configuration
    }

    // MARK: - Public API

    /// Stores an API token securely in the Keychain
    /// - Parameters:
    ///   - token: The token string to store
    ///   - key: A unique identifier for this token
    /// - Throws: KeychainError if the operation fails
    func storeToken(_ token: String, forKey key: String) throws {
        guard let tokenData = token.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }

        try storeData(tokenData, forKey: key)
    }

    /// Retrieves an API token from the Keychain
    /// - Parameter key: The unique identifier for the token
    /// - Returns: The stored token string
    /// - Throws: KeychainError if the operation fails
    func retrieveToken(forKey key: String) throws -> String {
        let data = try retrieveData(forKey: key)

        guard let token = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }

        return token
    }

    /// Deletes a token from the Keychain
    /// - Parameter key: The unique identifier for the token
    /// - Throws: KeychainError if the operation fails
    func deleteToken(forKey key: String) throws {
        let query = baseQuery(forKey: key)

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw mapError(status)
        }
    }

    /// Checks if a token exists in the Keychain
    /// - Parameter key: The unique identifier for the token
    /// - Returns: True if the token exists
    func tokenExists(forKey key: String) -> Bool {
        var query = baseQuery(forKey: key)
        query[kSecReturnData as String] = false

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Updates an existing token in the Keychain
    /// - Parameters:
    ///   - token: The new token value
    ///   - key: The unique identifier for the token
    /// - Throws: KeychainError if the operation fails
    func updateToken(_ token: String, forKey key: String) throws {
        guard let tokenData = token.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }

        let query = baseQuery(forKey: key)
        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: tokenData
        ]

        let status = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)

        guard status == errSecSuccess else {
            throw mapError(status)
        }
    }

    /// Stores or updates a token (upsert operation)
    /// - Parameters:
    ///   - token: The token to store
    ///   - key: The unique identifier for the token
    /// - Throws: KeychainError if the operation fails
    func saveToken(_ token: String, forKey key: String) throws {
        if tokenExists(forKey: key) {
            try updateToken(token, forKey: key)
        } else {
            try storeToken(token, forKey: key)
        }
    }

    // MARK: - Private Implementation

    private func storeData(_ data: Data, forKey key: String) throws {
        var query = baseQuery(forKey: key)
        query[kSecValueData as String] = data

        // Use data protection keychain
        query[kSecUseDataProtectionKeychain as String] = true

        // Add access control if biometrics are required
        if configuration.requireBiometrics {
            if let accessControl = createAccessControl() {
                query[kSecAttrAccessControl as String] = accessControl
            }
        } else {
            // Use accessible when unlocked for non-biometric items
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        }

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw mapError(status)
        }
    }

    private func retrieveData(forKey key: String) throws -> Data {
        var query = baseQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        // Use data protection keychain
        query[kSecUseDataProtectionKeychain as String] = true

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            throw mapError(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.unexpectedData
        }

        return data
    }

    private func baseQuery(forKey key: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: configuration.service,
            kSecAttrAccount as String: key
        ]
    }

    private func createAccessControl() -> SecAccessControl? {
        var error: Unmanaged<CFError>?

        let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlocked,
            .userPresence,  // Requires Touch ID, Face ID, or passcode
            &error
        )

        if let error = error {
            print("Failed to create access control: \(error.takeRetainedValue())")
            return nil
        }

        return accessControl
    }

    private func mapError(_ status: OSStatus) -> KeychainError {
        switch status {
        case errSecItemNotFound:
            return .itemNotFound
        case errSecDuplicateItem:
            return .duplicateItem
        case errSecAuthFailed:
            return .authenticationFailed
        case errSecInteractionNotAllowed, errSecMissingEntitlement:
            return .accessDenied
        default:
            return .unhandledError(status: status)
        }
    }
}

// MARK: - Async API for SwiftUI

extension KeychainManager {

    /// Asynchronously retrieves a token, handling biometric authentication
    /// - Parameter key: The unique identifier for the token
    /// - Returns: The stored token string
    func retrieveTokenAsync(forKey key: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let token = try self.retrieveToken(forKey: key)
                    continuation.resume(returning: token)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Asynchronously stores a token
    /// - Parameters:
    ///   - token: The token to store
    ///   - key: The unique identifier for the token
    func saveTokenAsync(_ token: String, forKey key: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.saveToken(token, forKey: key)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
