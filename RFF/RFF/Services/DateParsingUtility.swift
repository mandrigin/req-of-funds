import Foundation

/// Utility for parsing dates with smart handling of European DD.MM.YYYY format
/// vs American MM/DD/YYYY format.
///
/// Key insight: When the first number is > 12, it MUST be DD.MM format since
/// months only go 1-12. For ambiguous cases (both numbers <= 12), dot-separated
/// dates are assumed to be European format (DD.MM.YYYY).
enum DateParsingUtility {

    // MARK: - Public API

    /// Parse a date string with smart format detection.
    /// Handles both European (DD.MM.YYYY) and American (MM/DD/YYYY) formats.
    /// - Parameter text: The date string to parse
    /// - Returns: Parsed Date or nil if unparseable
    static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try dot-separated format first (European DD.MM.YYYY)
        if let date = parseDotSeparatedDate(trimmed) {
            return date
        }

        // Try standard formatters for other formats
        for formatter in standardFormatters {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        return nil
    }

    /// Parse a dot-separated date (e.g., "06.02.2026") with smart DD.MM vs MM.DD detection.
    /// - If first number > 12: definitely DD.MM.YYYY format
    /// - If second number > 12: definitely MM.DD.YYYY format
    /// - If both numbers <= 12: assume DD.MM.YYYY (European standard for dots)
    /// - Parameter text: The date string to parse
    /// - Returns: Parsed Date or nil if not a dot-separated date
    static func parseDotSeparatedDate(_ text: String) -> Date? {
        // Match DD.MM.YYYY or D.M.YYYY patterns
        let pattern = #"^(\d{1,2})\.(\d{1,2})\.(\d{2,4})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let firstRange = Range(match.range(at: 1), in: text),
              let secondRange = Range(match.range(at: 2), in: text),
              let yearRange = Range(match.range(at: 3), in: text),
              let first = Int(text[firstRange]),
              let second = Int(text[secondRange]),
              var year = Int(text[yearRange]) else {
            return nil
        }

        // Handle 2-digit years
        if year < 100 {
            year += (year > 50) ? 1900 : 2000
        }

        let day: Int
        let month: Int

        if first > 12 {
            // First number > 12: definitely DD.MM format (can't be a month)
            day = first
            month = second
        } else if second > 12 {
            // Second number > 12: definitely MM.DD format (second can't be a month)
            month = first
            day = second
        } else {
            // Both <= 12: ambiguous. Use European format (DD.MM) for dot-separated dates
            // This is the standard in Germany, Switzerland, and most of Europe
            day = first
            month = second
        }

        // Validate ranges
        guard month >= 1 && month <= 12 && day >= 1 && day <= 31 else {
            return nil
        }

        // Create date components
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day

        return Calendar.current.date(from: components)
    }

    // MARK: - Standard Formatters

    /// Standard date formatters for non-dot-separated formats
    private static let standardFormatters: [DateFormatter] = {
        let formats = [
            "MM/dd/yyyy",   // American: 02/06/2026
            "M/d/yyyy",     // American short: 2/6/2026
            "dd/MM/yyyy",   // European with slashes: 06/02/2026
            "d/M/yyyy",     // European short: 6/2/2026
            "yyyy-MM-dd",   // ISO: 2026-02-06
            "MMMM d, yyyy", // Full month: February 6, 2026
            "MMM d, yyyy",  // Short month: Feb 6, 2026
            "d MMMM yyyy",  // European text: 6 February 2026
            "d MMM yyyy",   // European text short: 6 Feb 2026
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter
        }
    }()

    // MARK: - Regex Patterns

    /// Regex patterns for detecting date-like strings (for use in search/classification)
    static let datePatterns: [String] = [
        #"\d{1,2}\.\d{1,2}\.\d{2,4}"#,            // DD.MM.YYYY (European dot-separated)
        #"\d{1,2}[/-]\d{1,2}[/-]\d{2,4}"#,        // DD/MM/YYYY or MM/DD/YYYY
        #"\d{4}[/-]\d{1,2}[/-]\d{1,2}"#,          // YYYY-MM-DD (ISO)
        #"(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2},?\s+\d{4}"#  // Month DD, YYYY
    ]
}
