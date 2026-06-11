import Foundation
import CommonCrypto

// MARK: - Move Result

/// Result of a successful move operation
struct MoveResult {
    /// Final destination path (may differ from requested due to collision handling)
    let destinationPath: URL

    /// Whether collision handling was used
    let hadCollision: Bool

    /// The collision suffix used, if any (e.g., 1, 2, 3)
    let collisionSuffix: Int?

    /// Whether cross-volume copy was used
    let wasCrossVolume: Bool
}

// MARK: - Mover Error

/// Errors that can occur during file moving
enum MoverError: LocalizedError {
    /// Source file not found
    case sourceNotFound(URL)

    /// Maximum collision limit reached (999)
    case collisionLimitExceeded(URL)

    /// File is locked and all retries exhausted
    case fileLocked(URL, Int)

    /// File is currently locked (temporary, will retry)
    case fileLockedTemporary(URL)

    /// Cross-volume copy verification failed (checksum mismatch)
    case checksumMismatch(URL, URL)

    /// General move operation failed
    case moveFailed(URL, URL, Error)

    /// Copy operation failed (for cross-volume)
    case copyFailed(URL, URL, Error)

    /// Delete operation failed after successful copy
    case deleteAfterCopyFailed(URL, Error)

    var errorDescription: String? {
        switch self {
        case .sourceNotFound(let url):
            return "Source file not found: \(url.path)"
        case .collisionLimitExceeded(let url):
            return "Maximum collision limit (999) exceeded for: \(url.lastPathComponent)"
        case .fileLocked(let url, let retries):
            return "File locked after \(retries) retries: \(url.path)"
        case .fileLockedTemporary(let url):
            return "File temporarily locked: \(url.path)"
        case .checksumMismatch(let source, let dest):
            return "Checksum mismatch after copy: \(source.path) -> \(dest.path)"
        case .moveFailed(let source, let dest, let error):
            return "Move failed \(source.path) -> \(dest.path): \(error.localizedDescription)"
        case .copyFailed(let source, let dest, let error):
            return "Copy failed \(source.path) -> \(dest.path): \(error.localizedDescription)"
        case .deleteAfterCopyFailed(let url, let error):
            return "Failed to delete source after copy: \(url.path): \(error.localizedDescription)"
        }
    }

    /// Error code for logging
    var errorCode: String {
        switch self {
        case .sourceNotFound: return "source_not_found"
        case .collisionLimitExceeded: return "collision_limit"
        case .fileLocked: return "file_locked"
        case .fileLockedTemporary: return "file_locked_temp"
        case .checksumMismatch: return "checksum_mismatch"
        case .moveFailed: return "move_failed"
        case .copyFailed: return "copy_failed"
        case .deleteAfterCopyFailed: return "delete_failed"
        }
    }
}

// MARK: - Mover

/// Handles atomic file moves with collision handling and cross-volume support
///
/// Responsibilities (per spec section 3.7):
/// - Atomic move using FileManager.moveItem
/// - Collision handling with -1, -2 suffix (max 999)
/// - Cross-volume support: copy + verify checksum + remove
/// - Locked file retry (3 retries, 30s apart)
final class Mover {

    // MARK: - Constants

    /// Maximum collision suffix number
    private static let maxCollisionSuffix = 999

    /// Maximum retries for locked files
    private static let maxLockedRetries = 3

    /// Delay between locked file retries (in seconds)
    private static let lockedRetryDelay: TimeInterval = 30.0

    // MARK: - Properties

    private let fileManager: FileManager

    // MARK: - Initialization

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Public API

    /// Move a file to the destination, handling collisions
    /// - Parameters:
    ///   - source: Source file URL
    ///   - destination: Destination file URL (collision handling will modify if needed)
    /// - Returns: Move result with final destination path
    func move(from source: URL, to destination: URL) throws -> MoveResult {
        // Verify source exists
        guard fileManager.fileExists(atPath: source.path) else {
            throw MoverError.sourceNotFound(source)
        }

        // Resolve collision to get actual destination
        let (finalDestination, hadCollision, suffix) = try resolveCollision(
            destinationFolder: destination.deletingLastPathComponent(),
            filename: destination.lastPathComponent
        )

        // Check if cross-volume move is needed
        let isCrossVolume = !areOnSameVolume(source, finalDestination)

        if isCrossVolume {
            try crossVolumeMove(from: source, to: finalDestination)
        } else {
            try atomicMove(from: source, to: finalDestination)
        }

        return MoveResult(
            destinationPath: finalDestination,
            hadCollision: hadCollision,
            collisionSuffix: suffix,
            wasCrossVolume: isCrossVolume
        )
    }

    /// Move a file with automatic retry for locked files
    /// - Parameters:
    ///   - source: Source file URL
    ///   - destination: Destination file URL
    ///   - retryCount: Current retry count (internal use)
    /// - Returns: Move result with final destination path
    func moveWithRetry(
        from source: URL,
        to destination: URL,
        retryCount: Int = 0
    ) async throws -> MoveResult {
        do {
            return try move(from: source, to: destination)
        } catch let error as MoverError {
            // Check if it's a locked file error that we can retry
            if case .fileLockedTemporary = error, retryCount < Self.maxLockedRetries {
                // Wait before retry
                try await Task.sleep(nanoseconds: UInt64(Self.lockedRetryDelay * 1_000_000_000))

                // Retry
                return try await moveWithRetry(
                    from: source,
                    to: destination,
                    retryCount: retryCount + 1
                )
            }

            // Convert temporary lock to permanent lock error after max retries
            if case .fileLockedTemporary(let url) = error {
                throw MoverError.fileLocked(url, Self.maxLockedRetries)
            }

            throw error
        } catch let error as NSError {
            // Check for file-in-use errors from the system
            if isLockedFileError(error) {
                if retryCount < Self.maxLockedRetries {
                    try await Task.sleep(nanoseconds: UInt64(Self.lockedRetryDelay * 1_000_000_000))
                    return try await moveWithRetry(
                        from: source,
                        to: destination,
                        retryCount: retryCount + 1
                    )
                }
                throw MoverError.fileLocked(source, Self.maxLockedRetries)
            }
            throw error
        }
    }

    // MARK: - Collision Handling

    /// Resolve filename collision by finding an available name
    /// - Parameters:
    ///   - destinationFolder: Folder to check for collisions
    ///   - filename: Original filename
    /// - Returns: Tuple of (final path, had collision, suffix used)
    private func resolveCollision(
        destinationFolder: URL,
        filename: String
    ) throws -> (URL, Bool, Int?) {
        let basePath = destinationFolder.appendingPathComponent(filename)

        // No collision - use original name
        if !fileManager.fileExists(atPath: basePath.path) {
            return (basePath, false, nil)
        }

        // Extract stem and extension
        let stem = filename.stem
        let ext = filename.pathExtension

        // Try suffix from 1 to max
        for suffix in 1...Self.maxCollisionSuffix {
            let newFilename: String
            if ext.isEmpty {
                newFilename = "\(stem)-\(suffix)"
            } else {
                newFilename = "\(stem)-\(suffix).\(ext)"
            }

            let candidatePath = destinationFolder.appendingPathComponent(newFilename)
            if !fileManager.fileExists(atPath: candidatePath.path) {
                return (candidatePath, true, suffix)
            }
        }

        throw MoverError.collisionLimitExceeded(basePath)
    }

    // MARK: - Move Operations

    /// Perform atomic move on same volume
    private func atomicMove(from source: URL, to destination: URL) throws {
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch let error as NSError {
            if isLockedFileError(error) {
                throw MoverError.fileLockedTemporary(source)
            }
            throw MoverError.moveFailed(source, destination, error)
        }
    }

    /// Perform cross-volume move: copy + verify + remove
    private func crossVolumeMove(from source: URL, to destination: URL) throws {
        // 1. Copy file
        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch let error as NSError {
            if isLockedFileError(error) {
                throw MoverError.fileLockedTemporary(source)
            }
            throw MoverError.copyFailed(source, destination, error)
        }

        // 2. Verify checksum
        guard verifyChecksum(source: source, destination: destination) else {
            // Remove failed copy
            try? fileManager.removeItem(at: destination)
            throw MoverError.checksumMismatch(source, destination)
        }

        // 3. Remove source
        do {
            try fileManager.removeItem(at: source)
        } catch {
            // File was copied successfully but source deletion failed
            // This is not critical - the file is now in the destination
            // Log but don't fail the operation
            throw MoverError.deleteAfterCopyFailed(source, error)
        }
    }

    // MARK: - Volume Detection

    /// Check if two URLs are on the same volume
    private func areOnSameVolume(_ url1: URL, _ url2: URL) -> Bool {
        do {
            let values1 = try url1.resourceValues(forKeys: [.volumeIdentifierKey])
            let values2 = try url2.deletingLastPathComponent().resourceValues(forKeys: [.volumeIdentifierKey])

            guard let id1 = values1.volumeIdentifier as? NSObject,
                  let id2 = values2.volumeIdentifier as? NSObject else {
                // Can't determine - assume same volume
                return true
            }

            return id1.isEqual(id2)
        } catch {
            // Error getting volume info - assume same volume and let move fail if not
            return true
        }
    }

    // MARK: - Checksum Verification

    /// Verify that source and destination have matching checksums
    private func verifyChecksum(source: URL, destination: URL) -> Bool {
        guard let sourceHash = sha256(of: source),
              let destHash = sha256(of: destination) else {
            return false
        }
        return sourceHash == destHash
    }

    /// Calculate SHA-256 hash of a file
    private func sha256(of url: URL) -> Data? {
        guard let inputStream = InputStream(url: url) else {
            return nil
        }

        inputStream.open()
        defer { inputStream.close() }

        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)

        let bufferSize = 64 * 1024 // 64KB buffer
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while inputStream.hasBytesAvailable {
            let bytesRead = inputStream.read(&buffer, maxLength: bufferSize)
            if bytesRead < 0 {
                return nil
            }
            if bytesRead > 0 {
                CC_SHA256_Update(&context, buffer, CC_LONG(bytesRead))
            }
        }

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)

        return Data(digest)
    }

    // MARK: - Error Detection

    /// Check if an error indicates the file is locked/in-use
    private func isLockedFileError(_ error: NSError) -> Bool {
        // POSIX errors
        if error.domain == NSPOSIXErrorDomain {
            // EBUSY (16), ETXTBSY (26), EAGAIN (35)
            return [16, 26, 35].contains(error.code)
        }

        // Cocoa errors
        if error.domain == NSCocoaErrorDomain {
            // NSFileLockingError, NSFileWriteUnknownError with underlying locked error
            return [255, 512].contains(error.code)
        }

        // Check underlying error
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isLockedFileError(underlying)
        }

        return false
    }
}

// MARK: - String Extension for Filename Parts

private extension String {
    /// Get the filename without extension
    var stem: String {
        let name = (self as NSString).deletingPathExtension
        return name
    }

    /// Get the file extension
    var pathExtension: String {
        return (self as NSString).pathExtension
    }
}
