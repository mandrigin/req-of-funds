import Foundation

/// Test CHF extraction patterns
/// Tests the regex patterns and number parsing for Swiss documents

print("Testing CHF Extraction Patterns")
print("================================\n")

// CHF patterns from AmountDateExtractionService (updated)
let chfPatterns = [
    #"CHF\s*[\d'\s.,]+\.\d{2}"#,           // CHF 1'234.56 or CHF 2 605.25
    #"[\d'\s.,]+\.\d{2}\s*CHF"#,           // 1'234.56 CHF or 2 605.25 CHF
    #"Fr\.\s*[\d'\s.,]+\.\d{2}"#,          // Fr. 1'234.56
    #"SFr\.\s*[\d'\s.,]+\.\d{2}"#,         // SFr. 1'234.56
    #"[\d'.,]+\.?\d*\s*(?:francs?|Franken)"# // 1'234.56 francs/Franken
]

// Test strings from actual Swiss documents
let testStrings = [
    // From QST document
    "Total Quellensteuer 2'658.40",
    "Rechnungsbetrag CHF 2'605.25",
    "CHF 2 605.25",
    "abzüglich 2.00 % Bezugsprovision -53.15",

    // From AHV document
    "Saldo zu unseren Gunsten 2'403.00",
    "CHF 2 403.00",
    "2'678.00",
    "-275.00",

    // From KTG document
    "CHF 212.60",
    "Insurance premium 1'867.50",
    "-1'654.90",

    // From UVG document
    "CHF 795.60",
    "Insurance premium 1'989.80",
    "1'086.90",

    // Edge cases
    "CHF 1'234'567.89",
    "Fr. 100.00",
    "SFr. 50.50",
    "1000 Franken",
]

var passed = 0
var failed = 0

for testString in testStrings {
    var found = false
    var matchedPattern = ""
    var matchedValue = ""

    for pattern in chfPatterns {
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let range = NSRange(testString.startIndex..<testString.endIndex, in: testString)
            let matches = regex.matches(in: testString, options: [], range: range)

            if !matches.isEmpty {
                for match in matches {
                    if let matchRange = Range(match.range, in: testString) {
                        matchedValue = String(testString[matchRange])
                        matchedPattern = pattern
                        found = true
                        break
                    }
                }
            }
        }
        if found { break }
    }

    if found {
        // Parse the amount
        var cleaned = matchedValue
            .replacingOccurrences(of: "CHF", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "SFr.", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Fr.", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "francs", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "franc", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Franken", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "'", with: "")  // Swiss thousands separator
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespaces)

        if let decimal = Decimal(string: cleaned) {
            print("✅ PASS: \"\(testString)\"")
            print("   Matched: \"\(matchedValue)\" → \(decimal) CHF")
            passed += 1
        } else {
            print("❌ FAIL: \"\(testString)\"")
            print("   Matched but couldn't parse: \"\(matchedValue)\" → cleaned: \"\(cleaned)\"")
            failed += 1
        }
    } else {
        // Some strings don't have CHF indicator, that's expected
        if testString.contains("CHF") || testString.contains("Fr.") || testString.contains("Franken") {
            print("❌ FAIL: \"\(testString)\"")
            print("   No pattern matched (but contains currency indicator)")
            failed += 1
        } else {
            print("⚪ SKIP: \"\(testString)\" (no CHF indicator)")
        }
    }
}

print("\n================================")
print("Results: \(passed) passed, \(failed) failed")

if failed > 0 {
    exit(1)
}
