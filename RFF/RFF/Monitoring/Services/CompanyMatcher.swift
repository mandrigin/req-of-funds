import Foundation

// MARK: - Company Match Result

/// Result of matching a company in text
struct CompanyMatchResult {
    /// The matched company configuration
    let company: CompanyConfig

    /// Overall match confidence (0.0-1.0)
    let confidence: Float

    /// Signals that contributed to the match
    let signals: [MatchSignal]

    /// Convert to logging details format
    var asCompanyMatchDetails: CompanyMatchDetails {
        CompanyMatchDetails(
            company: company.name,
            confidence: confidence,
            signals: signals
        )
    }
}

// MARK: - Company Matcher

/// Matches company names in extracted text using multiple signals
///
/// Matching strategy per spec section 3.4:
/// - Exact name match (confidence 1.0)
/// - Alias match (confidence 0.95)
/// - Fuzzy name match via Levenshtein (confidence 0.7-0.9)
/// - Tax ID match (confidence 1.0)
/// - Domain/email match (confidence 0.85)
/// - Optional filename hint boost (+0.1 if filename and content match)
final class CompanyMatcher {

    // MARK: - Constants

    /// Confidence values for different match types (per spec)
    private enum MatchConfidence {
        static let exactName: Float = 1.0
        static let alias: Float = 0.95
        static let taxId: Float = 1.0
        static let domain: Float = 0.85
        static let fuzzyMin: Float = 0.7
        static let fuzzyMax: Float = 0.9
        static let filenameBoost: Float = 0.1
        static let multiSignalBoostPerSignal: Float = 0.02
        static let maxMultiSignalBoost: Float = 0.1
    }

    /// Minimum similarity for fuzzy matching to be considered
    private static let fuzzyMatchMinSimilarity: Float = 0.85

    /// Common company suffixes to remove for matching
    private static let companySuffixes: Set<String> = [
        "inc", "incorporated", "llc", "ltd", "limited", "corp", "corporation",
        "co", "company", "gmbh", "ag", "sa", "srl", "bv", "nv", "plc", "pty"
    ]

    // MARK: - Properties

    private let companies: [CompanyConfig]
    private let threshold: Float
    private let enableFilenameHint: Bool

    // MARK: - Initialization

    /// Create a company matcher with the given configuration
    /// - Parameters:
    ///   - companies: List of companies to match against
    ///   - threshold: Minimum confidence to accept a match (default 0.8)
    ///   - enableFilenameHint: Use filename as supplementary signal (default true)
    init(companies: [CompanyConfig], threshold: Float = 0.8, enableFilenameHint: Bool = true) {
        self.companies = companies
        self.threshold = threshold
        self.enableFilenameHint = enableFilenameHint
    }

    /// Create a company matcher from the current app configuration
    static func fromConfig() -> CompanyMatcher {
        let config = ConfigManager.shared.config
        return CompanyMatcher(
            companies: config.companies,
            threshold: config.companyMatchThreshold,
            enableFilenameHint: config.enableFilenameHint
        )
    }

    // MARK: - Public API

    /// Match company in extracted text
    /// - Parameters:
    ///   - text: Extracted document text
    ///   - filename: Optional filename for hint boost
    /// - Returns: Best matching company result, or nil if no match above threshold
    func match(text: String, filename: String? = nil) -> CompanyMatchResult? {
        guard !companies.isEmpty else { return nil }

        let normalizedText = normalizeForMatching(text)
        var bestMatch: CompanyMatchResult?
        var bestConfidence: Float = 0.0

        for company in companies {
            let result = evaluateCompanyMatch(
                normalizedText: normalizedText,
                originalText: text,
                company: company,
                filename: filename
            )

            if result.confidence > bestConfidence {
                bestConfidence = result.confidence
                bestMatch = result
            }
        }

        // Return match only if above threshold
        if let match = bestMatch, match.confidence >= threshold {
            return match
        }

        return nil
    }

    /// Match company in filename only (for borderline cases)
    /// - Parameters:
    ///   - filename: Filename to check
    /// - Returns: Best matching company result from filename, or nil
    func matchInFilename(_ filename: String) -> CompanyMatchResult? {
        guard !companies.isEmpty else { return nil }

        let normalizedFilename = normalizeForMatching(filename)
        var bestMatch: CompanyMatchResult?
        var bestConfidence: Float = 0.0

        for company in companies {
            // Check exact name
            let normalizedName = normalizeForMatching(company.name)
            if normalizedFilename.contains(normalizedName) {
                let confidence = MatchConfidence.exactName * 0.9 // Reduce slightly for filename-only
                if confidence > bestConfidence {
                    bestConfidence = confidence
                    bestMatch = CompanyMatchResult(
                        company: company,
                        confidence: confidence,
                        signals: [MatchSignal(type: .exactName, confidence: confidence, matched: company.name)]
                    )
                }
                continue
            }

            // Check aliases
            for alias in company.aliases {
                let normalizedAlias = normalizeForMatching(alias)
                if normalizedFilename.contains(normalizedAlias) {
                    let confidence = MatchConfidence.alias * 0.9
                    if confidence > bestConfidence {
                        bestConfidence = confidence
                        bestMatch = CompanyMatchResult(
                            company: company,
                            confidence: confidence,
                            signals: [MatchSignal(type: .alias, confidence: confidence, matched: alias)]
                        )
                    }
                    break
                }
            }
        }

        return bestMatch
    }

    // MARK: - Matching Logic

    /// Evaluate all match signals for a single company
    private func evaluateCompanyMatch(
        normalizedText: String,
        originalText: String,
        company: CompanyConfig,
        filename: String?
    ) -> CompanyMatchResult {
        var signals: [MatchSignal] = []

        // 1. Exact name match
        let normalizedName = normalizeForMatching(company.name)
        if normalizedText.contains(normalizedName) {
            signals.append(MatchSignal(
                type: .exactName,
                confidence: MatchConfidence.exactName,
                matched: company.name
            ))
        }

        // 2. Alias matches (only if no exact name match)
        if signals.isEmpty || signals.allSatisfy({ $0.type != .exactName }) {
            for alias in company.aliases {
                let normalizedAlias = normalizeForMatching(alias)
                if normalizedText.contains(normalizedAlias) {
                    signals.append(MatchSignal(
                        type: .alias,
                        confidence: MatchConfidence.alias,
                        matched: alias
                    ))
                    break // Only count one alias match
                }
            }
        }

        // 3. Tax ID matches
        for taxId in company.taxIds {
            // Tax IDs may have formatting variations, normalize
            let normalizedTaxId = taxId.replacingOccurrences(of: " ", with: "")
            let textNoSpaces = originalText.replacingOccurrences(of: " ", with: "")
            if textNoSpaces.contains(normalizedTaxId) || originalText.contains(taxId) {
                signals.append(MatchSignal(
                    type: .taxId,
                    confidence: MatchConfidence.taxId,
                    matched: taxId
                ))
                break // Only count one tax ID match
            }
        }

        // 4. Domain/email matches
        for domain in company.domains {
            let lowercaseDomain = domain.lowercased()
            let lowercaseText = originalText.lowercased()
            // Check for @domain or just domain in text
            if lowercaseText.contains("@\(lowercaseDomain)") ||
               lowercaseText.contains(lowercaseDomain) {
                signals.append(MatchSignal(
                    type: .domain,
                    confidence: MatchConfidence.domain,
                    matched: domain
                ))
                break // Only count one domain match
            }
        }

        // 5. Fuzzy match (only if no exact or alias matches)
        let hasStrongMatch = signals.contains { $0.type == .exactName || $0.type == .alias }
        if !hasStrongMatch {
            if let fuzzyScore = fuzzyMatch(in: normalizedText, target: normalizedName),
               fuzzyScore >= Self.fuzzyMatchMinSimilarity {
                // Map similarity [0.85, 1.0] to confidence [0.7, 0.9]
                let confidence = MatchConfidence.fuzzyMin +
                    (fuzzyScore - Self.fuzzyMatchMinSimilarity) /
                    (1.0 - Self.fuzzyMatchMinSimilarity) *
                    (MatchConfidence.fuzzyMax - MatchConfidence.fuzzyMin)

                signals.append(MatchSignal(
                    type: .fuzzy,
                    confidence: confidence,
                    matched: company.name
                ))
            }
        }

        // Calculate final confidence
        guard !signals.isEmpty else {
            return CompanyMatchResult(company: company, confidence: 0.0, signals: [])
        }

        // Base confidence is highest signal
        let baseConfidence = signals.map(\.confidence).max() ?? 0.0

        // Multi-signal boost (per spec)
        let multiSignalBoost = min(
            MatchConfidence.maxMultiSignalBoost,
            Float(signals.count) * MatchConfidence.multiSignalBoostPerSignal
        )

        var finalConfidence = min(1.0, baseConfidence + multiSignalBoost)

        // Filename hint boost (per spec section 3.4)
        if enableFilenameHint, let filename = filename {
            if let filenameMatch = matchInFilename(filename),
               filenameMatch.company.name == company.name {
                finalConfidence = min(1.0, finalConfidence + MatchConfidence.filenameBoost)
            }
        }

        return CompanyMatchResult(
            company: company,
            confidence: finalConfidence,
            signals: signals
        )
    }

    // MARK: - Text Normalization

    /// Normalize text for matching per spec section 3.4
    /// 1. Lowercase
    /// 2. Remove punctuation except hyphens in company names
    /// 3. Normalize whitespace (collapse multiple spaces)
    /// 4. Remove common suffixes: inc, llc, ltd, corp, gmbh, ag
    /// 5. Unicode normalization (NFD → NFC)
    func normalizeForMatching(_ text: String) -> String {
        // Unicode normalize
        var result = text.precomposedStringWithCanonicalMapping

        // Lowercase
        result = result.lowercased()

        // Remove punctuation except hyphens (keep letters, numbers, spaces, hyphens)
        result = result.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) ||
            scalar == " " ||
            scalar == "-"
        }.map { String($0) }.joined()

        // Normalize whitespace
        result = result.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // Remove common company suffixes
        result = removeCompanySuffixes(from: result)

        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Remove common company suffixes from text
    private func removeCompanySuffixes(from text: String) -> String {
        var words = text.split(separator: " ").map(String.init)

        // Remove trailing suffix words
        while let lastWord = words.last,
              Self.companySuffixes.contains(lastWord.lowercased()) {
            words.removeLast()
        }

        return words.joined(separator: " ")
    }

    // MARK: - Fuzzy Matching

    /// Perform fuzzy matching using Levenshtein distance with sliding window
    /// - Parameters:
    ///   - text: Text to search in
    ///   - target: Target company name to find
    /// - Returns: Best similarity score (0.0-1.0), or nil if below minimum
    func fuzzyMatch(in text: String, target: String) -> Float? {
        let words = text.split(separator: " ").map(String.init)
        let targetWords = target.split(separator: " ")
        let targetWordCount = targetWords.count

        guard targetWordCount > 0, words.count >= targetWordCount else {
            return nil
        }

        var bestSimilarity: Float = 0.0

        // Sliding window over text words
        for i in 0...(words.count - targetWordCount) {
            let window = words[i..<(i + targetWordCount)].joined(separator: " ")
            let similarity = calculateSimilarity(window, target)

            if similarity > bestSimilarity {
                bestSimilarity = similarity
            }
        }

        return bestSimilarity >= Self.fuzzyMatchMinSimilarity ? bestSimilarity : nil
    }

    /// Calculate similarity between two strings using Levenshtein distance
    private func calculateSimilarity(_ s1: String, _ s2: String) -> Float {
        let distance = levenshteinDistance(s1, s2)
        let maxLen = max(s1.count, s2.count)
        guard maxLen > 0 else { return 1.0 }
        return 1.0 - (Float(distance) / Float(maxLen))
    }

    /// Calculate Levenshtein distance between two strings
    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let s1Array = Array(s1)
        let s2Array = Array(s2)
        let m = s1Array.count
        let n = s2Array.count

        // Handle empty strings
        if m == 0 { return n }
        if n == 0 { return m }

        // Create distance matrix
        var matrix = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)

        // Initialize first row and column
        for i in 0...m {
            matrix[i][0] = i
        }
        for j in 0...n {
            matrix[0][j] = j
        }

        // Fill in the rest of the matrix
        for i in 1...m {
            for j in 1...n {
                if s1Array[i - 1] == s2Array[j - 1] {
                    matrix[i][j] = matrix[i - 1][j - 1]
                } else {
                    matrix[i][j] = min(
                        matrix[i - 1][j] + 1,     // deletion
                        matrix[i][j - 1] + 1,     // insertion
                        matrix[i - 1][j - 1] + 1  // substitution
                    )
                }
            }
        }

        return matrix[m][n]
    }
}
