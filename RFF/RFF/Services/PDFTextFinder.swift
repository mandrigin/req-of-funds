import Foundation
import PDFKit

/// A found text match in a PDF document
struct PDFTextMatch {
    /// The page index (0-based)
    let pageIndex: Int
    /// The selection containing the matched text
    let selection: PDFSelection
    /// The matched text
    let text: String
    /// The bounds of the matched text on the page
    var bounds: CGRect {
        guard let page = selection.pages.first else {
            return .zero
        }
        return selection.bounds(for: page)
    }
}

/// Service for finding text in PDF documents
final class PDFTextFinder {

    /// Find all occurrences of a string in a PDF document
    /// - Parameters:
    ///   - searchString: The string to search for
    ///   - document: The PDF document to search in
    ///   - caseSensitive: Whether the search should be case-sensitive
    /// - Returns: Array of PDFTextMatch for each occurrence found
    func findText(_ searchString: String, in document: PDFDocument, caseSensitive: Bool = false) -> [PDFTextMatch] {
        var matches: [PDFTextMatch] = []

        let options: NSString.CompareOptions = caseSensitive ? [] : .caseInsensitive

        for pageIndex in 0..<document.pageCount {
            autoreleasepool {
                guard let page = document.page(at: pageIndex) else { return }

                var searchRange = NSRange(location: 0, length: (page.string ?? "").count)

                while searchRange.location < (page.string ?? "").count {
                    guard let selection = page.selection(for: searchRange) else { break }
                    guard let selectionString = selection.string else { break }

                    if let range = selectionString.range(of: searchString, options: options) {
                        let nsRange = NSRange(range, in: selectionString)

                        if let match = document.findString(searchString, fromSelection: selection, withOptions: caseSensitive ? [] : .caseInsensitive) {
                            matches.append(PDFTextMatch(
                                pageIndex: pageIndex,
                                selection: match,
                                text: match.string ?? searchString
                            ))
                        }

                        searchRange.location += nsRange.upperBound
                        searchRange.length = (page.string ?? "").count - searchRange.location
                    } else {
                        break
                    }
                }
            }
        }

        return matches
    }

    /// Find all occurrences matching a regular expression in a PDF document
    /// - Parameters:
    ///   - pattern: The regex pattern to match
    ///   - document: The PDF document to search in
    /// - Returns: Array of PDFTextMatch for each occurrence found
    func findPattern(_ pattern: String, in document: PDFDocument) -> [PDFTextMatch] {
        var matches: [PDFTextMatch] = []

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return matches
        }

        for pageIndex in 0..<document.pageCount {
            autoreleasepool {
                guard let page = document.page(at: pageIndex),
                      let pageText = page.string else { return }

                let nsString = pageText as NSString
                let range = NSRange(location: 0, length: nsString.length)

                regex.enumerateMatches(in: pageText, options: [], range: range) { result, _, _ in
                    guard let result = result else { return }

                    let matchedText = nsString.substring(with: result.range)

                    // Get selection at the exact character range where the regex matched
                    if let selection = page.selection(for: result.range) {
                        matches.append(PDFTextMatch(
                            pageIndex: pageIndex,
                            selection: selection,
                            text: matchedText
                        ))
                    }
                }
            }
        }

        return matches
    }

    /// Find currency amounts in a PDF document
    /// Matches common formats like $1,234.56, 1234.56, etc.
    /// - Parameter document: The PDF document to search in
    /// - Returns: Array of PDFTextMatch for each amount found
    func findAmounts(in document: PDFDocument) -> [PDFTextMatch] {
        // Pattern matches: $1,234.56 or 1234.56 or $1234 etc.
        let amountPattern = #"\$?\d{1,3}(?:,\d{3})*(?:\.\d{2})?"#
        return findPattern(amountPattern, in: document)
    }

    /// Find dates in a PDF document
    /// Matches common formats like MM/DD/YYYY, YYYY-MM-DD, Month DD, YYYY, etc.
    /// - Parameter document: The PDF document to search in
    /// - Returns: Array of PDFTextMatch for each date found
    func findDates(in document: PDFDocument) -> [PDFTextMatch] {
        // Use centralized date patterns from DateParsingUtility
        var allMatches: [PDFTextMatch] = []
        for pattern in DateParsingUtility.datePatterns {
            allMatches.append(contentsOf: findPattern(pattern, in: document))
        }

        return allMatches
    }
}
