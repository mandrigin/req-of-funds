import Foundation

// MARK: - Date Extraction Result

/// Result of date extraction from invoice content
struct DateExtractionResult {
    /// The extracted date
    let date: Date

    /// Source of the date
    let source: DateExtractionSource

    /// Pattern that matched (if extracted from content)
    let pattern: String?

    /// The raw matched string (for debugging)
    let matchedText: String?
}

// MARK: - Date Extractor Error

/// Errors that can occur during date extraction
enum DateExtractorError: LocalizedError {
    /// No date could be found in the content
    case noDateFound

    /// Date was found but failed sanity checks
    case dateOutOfRange(Date)

    /// File attributes could not be read
    case fileAttributesUnavailable(URL)

    var errorDescription: String? {
        switch self {
        case .noDateFound:
            return "No valid date could be extracted from content"
        case .dateOutOfRange(let date):
            return "Extracted date \(date) is outside acceptable range"
        case .fileAttributesUnavailable(let url):
            return "Could not read file attributes for \(url.path)"
        }
    }
}

// MARK: - Date Extractor

/// Extracts invoice dates from document content
///
/// Extraction strategy per spec section 3.5:
/// 1. Look for dates near "Invoice Date" or "Date" labels
/// 2. Try various date formats (ISO, US, EU, written)
/// 3. Apply sanity checks (not future, not > 2 years old)
/// 4. Fallback to file attributes or current date
final class DateExtractor {

    // MARK: - Date Patterns

    /// Patterns to search for dates, in priority order
    private struct DatePattern {
        let regex: NSRegularExpression
        let formats: [String]
        let name: String

        init?(pattern: String, formats: [String], name: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return nil
            }
            self.regex = regex
            self.formats = formats
            self.name = name
        }
    }

    private let patterns: [DatePattern]

    // MARK: - Sanity Check Configuration

    /// Maximum age of an invoice date (2 years)
    private let maxAgeYears = 2

    // MARK: - Initialization

    init() {
        var patterns: [DatePattern] = []

        // 1. Near "Invoice Date" label (highest priority)
        if let p = DatePattern(
            pattern: #"invoice\s*date[:\s]*(\d{1,2}[\/\-\.]\d{1,2}[\/\-\.]\d{2,4})"#,
            formats: ["MM/dd/yyyy", "M/d/yyyy", "dd/MM/yyyy", "d/M/yyyy", "MM-dd-yyyy", "dd-MM-yyyy", "MM.dd.yyyy", "dd.MM.yyyy", "M/d/yy", "d/M/yy"],
            name: "invoice_date_label"
        ) {
            patterns.append(p)
        }

        // 2. Near "Date" label
        if let p = DatePattern(
            pattern: #"(?:^|[^\w])date[:\s]*(\d{1,2}[\/\-\.]\d{1,2}[\/\-\.]\d{2,4})"#,
            formats: ["MM/dd/yyyy", "M/d/yyyy", "dd/MM/yyyy", "d/M/yyyy", "MM-dd-yyyy", "dd-MM-yyyy", "MM.dd.yyyy", "dd.MM.yyyy", "M/d/yy", "d/M/yy"],
            name: "date_label"
        ) {
            patterns.append(p)
        }

        // 3. ISO format (most unambiguous)
        if let p = DatePattern(
            pattern: #"(\d{4}-\d{2}-\d{2})"#,
            formats: ["yyyy-MM-dd"],
            name: "ISO"
        ) {
            patterns.append(p)
        }

        // 4. Written format: "January 15, 2024" or "Jan 15, 2024"
        if let p = DatePattern(
            pattern: #"((?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+\d{1,2},?\s+\d{4})"#,
            formats: ["MMMM d, yyyy", "MMMM d yyyy", "MMM d, yyyy", "MMM d yyyy"],
            name: "written_month_first"
        ) {
            patterns.append(p)
        }

        // 5. Written format: "15 January 2024" or "15 Jan 2024"
        if let p = DatePattern(
            pattern: #"(\d{1,2}\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+\d{4})"#,
            formats: ["d MMMM yyyy", "d MMM yyyy"],
            name: "written_day_first"
        ) {
            patterns.append(p)
        }

        // 6. Generic date patterns (lower priority, more ambiguous)
        if let p = DatePattern(
            pattern: #"(\d{1,2}[\/\-\.]\d{1,2}[\/\-\.]\d{4})"#,
            formats: ["MM/dd/yyyy", "dd/MM/yyyy", "M/d/yyyy", "d/M/yyyy", "MM-dd-yyyy", "dd-MM-yyyy", "MM.dd.yyyy", "dd.MM.yyyy"],
            name: "numeric_4digit_year"
        ) {
            patterns.append(p)
        }

        // 7. Short year format (lowest priority due to ambiguity)
        if let p = DatePattern(
            pattern: #"(\d{1,2}[\/\-\.]\d{1,2}[\/\-\.]\d{2})(?!\d)"#,
            formats: ["MM/dd/yy", "dd/MM/yy", "M/d/yy", "d/M/yy"],
            name: "numeric_2digit_year"
        ) {
            patterns.append(p)
        }

        self.patterns = patterns
    }

    // MARK: - Public API

    /// Extract date from invoice content with fallback cascade
    /// - Parameters:
    ///   - text: Extracted text content from the invoice
    ///   - fileURL: URL to the file for fallback attributes
    ///   - dateSource: Configured date source preference
    /// - Returns: Extraction result with date and metadata
    func extract(
        from text: String,
        fileURL: URL,
        dateSource: DateSource
    ) -> DateExtractionResult {
        // 1. Try extracted invoice date if that's the preference
        if dateSource == .extractedInvoiceDate {
            if let result = extractFromContent(text) {
                return result
            }
            // Fall through to file creation date
            if let result = extractFromFileAttribute(fileURL, attribute: .creationDate) {
                return result
            }
        }

        // 2. Try specific file attribute based on config
        switch dateSource {
        case .fileCreationDate:
            if let result = extractFromFileAttribute(fileURL, attribute: .creationDate) {
                return result
            }
        case .fileModificationDate:
            if let result = extractFromFileAttribute(fileURL, attribute: .modificationDate) {
                return result
            }
        case .currentDate:
            break // Fall through to current date
        case .extractedInvoiceDate:
            break // Already handled above
        }

        // 3. Final fallback: current date
        return DateExtractionResult(
            date: Date(),
            source: .currentDate,
            pattern: nil,
            matchedText: nil
        )
    }

    /// Extract date only from content (no fallbacks)
    /// - Parameter text: Extracted text content
    /// - Returns: Extraction result if a valid date was found, nil otherwise
    func extractFromContent(_ text: String) -> DateExtractionResult? {
        let normalizedText = text.lowercased()

        for pattern in patterns {
            if let match = findMatch(in: normalizedText, originalText: text, pattern: pattern) {
                return match
            }
        }

        return nil
    }

    // MARK: - Private Methods

    private func findMatch(
        in normalizedText: String,
        originalText: String,
        pattern: DatePattern
    ) -> DateExtractionResult? {
        let range = NSRange(normalizedText.startIndex..., in: normalizedText)

        guard let match = pattern.regex.firstMatch(in: normalizedText, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: normalizedText) else {
            return nil
        }

        let matchedText = String(normalizedText[captureRange])

        // Try each format until one works
        for format in pattern.formats {
            if let date = parseDate(matchedText, format: format) {
                // Apply sanity checks
                if isDateValid(date) {
                    return DateExtractionResult(
                        date: date,
                        source: .invoiceContent,
                        pattern: format,
                        matchedText: matchedText
                    )
                }
            }
        }

        return nil
    }

    private func parseDate(_ string: String, format: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")

        // Handle 2-digit years
        if format.contains("yy") && !format.contains("yyyy") {
            formatter.twoDigitStartDate = Calendar.current.date(byAdding: .year, value: -80, to: Date())
        }

        return formatter.date(from: string)
    }

    /// Validate that a date passes sanity checks
    /// - Parameter date: Date to validate
    /// - Returns: true if date is not in the future and not too old
    private func isDateValid(_ date: Date) -> Bool {
        let now = Date()

        // Not in the future (allow 1 day grace for timezone issues)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        if date > tomorrow {
            return false
        }

        // Not more than 2 years old
        let twoYearsAgo = Calendar.current.date(byAdding: .year, value: -maxAgeYears, to: now)!
        if date < twoYearsAgo {
            return false
        }

        return true
    }

    private enum FileAttribute {
        case creationDate
        case modificationDate
    }

    private func extractFromFileAttribute(_ url: URL, attribute: FileAttribute) -> DateExtractionResult? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)

            let date: Date?
            let source: DateExtractionSource

            switch attribute {
            case .creationDate:
                date = attributes[.creationDate] as? Date
                source = .fileCreationDate
            case .modificationDate:
                date = attributes[.modificationDate] as? Date
                source = .fileModificationDate
            }

            if let date = date {
                return DateExtractionResult(
                    date: date,
                    source: source,
                    pattern: nil,
                    matchedText: nil
                )
            }
        } catch {
            // File attributes unavailable
        }

        return nil
    }
}

// MARK: - DateExtractionResult Extensions

extension DateExtractionResult {
    /// Convert to DateExtractionDetails for logging
    func asExtractionDetails() -> DateExtractionDetails {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]

        return DateExtractionDetails(
            extractedDate: formatter.string(from: date),
            source: source,
            pattern: pattern
        )
    }
}
