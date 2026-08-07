import Foundation

/// Turns a messy query into a fault code plus a component phrase.
///
/// A fault code is an exact token, so exact matching beats semantic search — but
/// the input is messy, especially from voice. This resolves every spelling of a
/// code to one canonical value before any search happens.
///
/// Pure and synchronous. No I/O, no state, no model. It must work with every AI
/// on the device disabled.
public enum FaultCodeNormalizer {

    // MARK: - Vocabulary

    private static let digitWords: [String: String] = [
        "zero": "0", "oh": "0", "o": "0", "naught": "0", "nought": "0",
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9",
    ]

    private static let multiplierWords: [String: Int] = [
        "double": 2,
        "triple": 3,
    ]

    /// Spoken renderings of a letter prefix. Dictation writes "F" several ways.
    ///
    /// Deliberately tiny: every entry is a chance for a false positive, and this
    /// wants tuning against real dictation before it grows.
    private static let letterWords: [String: String] = [
        "eff": "f",
    ]

    /// Words that license reading a bare number as a fault code. Without one of
    /// these, "line 3 slitter" must not resolve to code 3.
    private static let faultKeywords: Set<String> = [
        "fault", "code", "error", "alarm", "err", "trip",
    ]

    /// Longest letter prefix treated as a code prefix. Keeps "powerflex" from
    /// being read as one.
    private static let maximumPrefixLength = 3

    /// Longest digit run treated as a code. Rockwell codes sit well inside this.
    private static let maximumDigitCount = 5

    // MARK: - Entry point

    /// Extracts the fault code and the remaining component phrase.
    ///
    /// Returns a `nil` code rather than guessing when the input contains no
    /// plausible one — "how do I set the tuning gains" is a real query, not a
    /// failed code lookup.
    public static func normalize(_ input: String?) -> NormalizedQuery {
        let rawTokens = tokenize(input ?? "")
        guard !rawTokens.isEmpty else {
            return NormalizedQuery(faultCode: nil, residualText: "")
        }

        let hasFaultKeyword = rawTokens.contains { faultKeywords.contains($0.lowercased()) }
        let folded = mergeAdjacentDigits(foldSpokenWords(rawTokens))

        var code: FaultCode?
        var consumed: Set<Int> = []

        // Pass 1 — a compact code written as one token: F0007, f-0007, F_0007.
        for token in folded {
            let lowered = token.text.lowercased()
            if isCatalogNumber(lowered) { continue }
            if let (prefix, digits) = compactCodeParts(lowered), let value = Int(digits) {
                code = FaultCode(
                    prefix: prefix.uppercased(),
                    number: value,
                    typedDigitCount: digits.count
                )
                consumed = token.sourceIndices
                break
            }
        }

        // Pass 2 — a lone letter followed by a digit run: "F 0007", "f seven".
        // Spoken input almost always lands here, since the folding above turns
        // "zero zero zero seven" into a single "0007" token.
        if code == nil {
            for (index, token) in folded.enumerated() where index + 1 < folded.count {
                let lowered = token.text.lowercased()
                guard lowered.count == 1,
                      let character = lowered.first,
                      character.isASCII, character.isLetter
                else { continue }

                let next = folded[index + 1]
                guard isAllDigits(next.text),
                      next.text.count <= maximumDigitCount,
                      let value = Int(next.text)
                else { continue }

                code = FaultCode(
                    prefix: lowered.uppercased(),
                    number: value,
                    typedDigitCount: next.text.count
                )
                consumed = token.sourceIndices.union(next.sourceIndices)
                break
            }
        }

        // Pass 3 — a bare number, but only when the query says it is a fault.
        if code == nil, hasFaultKeyword {
            for token in folded {
                guard isAllDigits(token.text),
                      token.text.count <= maximumDigitCount,
                      let value = Int(token.text)
                else { continue }

                code = FaultCode(prefix: "", number: value, typedDigitCount: token.text.count)
                consumed = token.sourceIndices
                break
            }
        }

        let residual = rawTokens.enumerated()
            .filter { !consumed.contains($0.offset) }
            .map(\.element)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        return NormalizedQuery(faultCode: code, residualText: residual)
    }

    // MARK: - Tokenising

    /// A token plus the indices of the original words it came from, so the
    /// residual phrase can be rebuilt without whatever the code consumed.
    private struct Token {
        var text: String
        var sourceIndices: Set<Int>
    }

    /// Splits on anything that is not a letter, digit, hyphen or underscore.
    /// Hyphens survive so `F-0007` and `2198-D032-ERS3` stay whole and can be
    /// told apart later.
    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""

        for character in text {
            let isWordCharacter =
                (character.isASCII && (character.isLetter || character.isNumber))
                || character == "-"
                || character == "_"

            if isWordCharacter {
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }

        return tokens
    }

    /// Rewrites spoken number words as digits. "triple oh" becomes "000".
    private static func foldSpokenWords(_ tokens: [String]) -> [Token] {
        var result: [Token] = []
        var index = 0

        while index < tokens.count {
            let lowered = tokens[index].lowercased()

            if let multiplier = multiplierWords[lowered], index + 1 < tokens.count,
               let digit = digitWords[tokens[index + 1].lowercased()] {
                result.append(Token(
                    text: String(repeating: digit, count: multiplier),
                    sourceIndices: [index, index + 1]
                ))
                index += 2
                continue
            }

            if let digit = digitWords[lowered] {
                result.append(Token(text: digit, sourceIndices: [index]))
                index += 1
                continue
            }

            if let letter = letterWords[lowered] {
                result.append(Token(text: letter, sourceIndices: [index]))
                index += 1
                continue
            }

            result.append(Token(text: tokens[index], sourceIndices: [index]))
            index += 1
        }

        return result
    }

    /// Joins runs of digit tokens, so `f 0 0 0 7` becomes `f 0007`.
    private static func mergeAdjacentDigits(_ tokens: [Token]) -> [Token] {
        var result: [Token] = []
        var index = 0

        while index < tokens.count {
            guard isAllDigits(tokens[index].text) else {
                result.append(tokens[index])
                index += 1
                continue
            }

            var text = tokens[index].text
            var sources = tokens[index].sourceIndices
            var next = index + 1

            while next < tokens.count, isAllDigits(tokens[next].text) {
                text += tokens[next].text
                sources.formUnion(tokens[next].sourceIndices)
                next += 1
            }

            result.append(Token(text: text, sourceIndices: sources))
            index = next
        }

        return result
    }

    // MARK: - Recognisers

    /// Splits a token into a letter prefix and a digit run, if it is shaped like
    /// a code. One optional separator is allowed between them.
    private static func compactCodeParts(_ token: String) -> (prefix: String, digits: String)? {
        var letters = ""
        var digits = ""
        var index = token.startIndex

        while index < token.endIndex,
              token[index].isASCII, token[index].isLetter {
            letters.append(token[index])
            index = token.index(after: index)
        }
        guard !letters.isEmpty, letters.count <= maximumPrefixLength else { return nil }

        if index < token.endIndex,
           token[index] == "-" || token[index] == "_" || token[index] == " " {
            index = token.index(after: index)
        }

        while index < token.endIndex,
              token[index].isASCII, token[index].isNumber {
            digits.append(token[index])
            index = token.index(after: index)
        }

        // Anything left over means this was not a clean code token.
        guard index == token.endIndex else { return nil }
        guard !digits.isEmpty, digits.count <= maximumDigitCount else { return nil }

        return (letters, digits)
    }

    /// True for catalog numbers such as `2198-D032-ERS3`.
    ///
    /// Three or more hyphen-joined alphanumeric segments. Without this, the
    /// `D032` inside a catalog number reads as fault code D32 and sends the
    /// search somewhere absurd.
    private static func isCatalogNumber(_ token: String) -> Bool {
        let parts = token.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return false }

        for part in parts {
            if part.isEmpty { return false }
            let hasOnlyWordCharacters = part.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber)
            }
            if !hasOnlyWordCharacters { return false }
        }

        return true
    }

    private static func isAllDigits(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
