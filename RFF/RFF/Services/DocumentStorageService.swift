import Foundation

/// Manages a local copy of invoice files inside the app's Application Support directory.
/// Files are copied on import so the app never depends on the original location.
enum DocumentStorageService {

    /// ~/Library/Application Support/RFF/Documents/
    static let documentsDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("RFF/Documents", isDirectory: true)
    }()

    /// Ensure the storage directory exists.
    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
    }

    /// Copy a file into local storage, keyed by document UUID.
    /// Returns the path to the local copy.
    static func copyFile(from sourceURL: URL, documentId: UUID) throws -> String {
        try ensureDirectory()

        let ext = sourceURL.pathExtension
        let destName = ext.isEmpty ? documentId.uuidString : "\(documentId.uuidString).\(ext)"
        let destURL = documentsDirectory.appendingPathComponent(destName)

        // If a previous copy exists (re-import), replace it
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }

        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        return destURL.path
    }

    /// Write raw data (e.g. a pasted clipboard image) into local storage, keyed by document UUID.
    /// Returns the path to the stored file.
    static func saveData(_ data: Data, documentId: UUID, fileExtension ext: String) throws -> String {
        try ensureDirectory()

        let destName = ext.isEmpty ? documentId.uuidString : "\(documentId.uuidString).\(ext)"
        let destURL = documentsDirectory.appendingPathComponent(destName)

        try data.write(to: destURL, options: .atomic)
        return destURL.path
    }

    /// Delete the local copy for a document.
    static func deleteFile(for documentId: UUID, extension ext: String? = nil) {
        let name: String
        if let ext = ext, !ext.isEmpty {
            name = "\(documentId.uuidString).\(ext)"
        } else {
            name = documentId.uuidString
        }
        let url = documentsDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
    }

    /// Check whether a path points inside our managed storage.
    static func isManagedPath(_ path: String) -> Bool {
        return path.hasPrefix(documentsDirectory.path)
    }
}
