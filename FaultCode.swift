import Foundation

/// A fault code recovered from a user's query.
///
/// The canonical form strips leading zeros, so `F0007`, `F007` and `F7` are the
/// same code. That single fact is what lets a messy query find an exact token in
/// the manual: we canonicalise once, then expand back out to every surface form
/// the manual might have printed.
public struct FaultCode: Hashable, Sendable {

    /// The letter prefix, uppercased. Empty for a bare numeric code.
    public let prefix: String

    /// The numeric part with leading zeros discarded. `F0007` gives `7`.
    public let number: Int

    /// How many digits the user actually typed or spoke, so a wider code than
    /// the usual four still generates a variant at its own width.
    public let typedDigitCount: Int

    public init(prefix: String, number: Int, typedDigitCount: Int) {
        self.prefix = prefix
        self.number = number
        self.typedDigitCount = typedDigitCount
    }

    /// The comparison key. Two queries mean the same code when these match.
    public var canonical: String {
        "\(prefix)\(number)"
    }

    /// Every surface form worth searching the manual text for, most specific
    /// first. `F0007` yields `F7`, `F 7`, `F-7`, `F07`, … `F-0007`.
    ///
    /// These are the strings to feed an FTS5 `MATCH` as an OR group. A bare
    /// numeric code gets no separator variants, since there is nothing to
    /// separate.
    public var searchVariants: [String] {
        let minimalWidth = String(number).count
        let maximumWidth = max(4, max(typedDigitCount, minimalWidth))

        var variants: [String] = []
        var seen: Set<String> = []

        for width in minimalWidth...maximumWidth {
            let padding = String(repeating: "0", count: width - minimalWidth)
            let digits = padding + String(number)

            for separator in ["", " ", "-"] {
                if prefix.isEmpty && !separator.isEmpty { continue }
                let variant = prefix + separator + digits
                if seen.insert(variant).inserted {
                    variants.append(variant)
                }
            }
        }

        return variants
    }
}

/// The result of normalising a user's query: the fault code if one was found,
/// and whatever text remains once the code is removed.
///
/// The residual is what gets matched against `Component` synonyms. For
/// "knife controller fault F0007" the code is `F7` and the residual is
/// "knife controller fault".
public struct NormalizedQuery: Equatable, Sendable {

    public let faultCode: FaultCode?
    public let residualText: String

    public init(faultCode: FaultCode?, residualText: String) {
        self.faultCode = faultCode
        self.residualText = residualText
    }
}
