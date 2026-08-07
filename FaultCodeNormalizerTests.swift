import XCTest
@testable import FaultCodeNormalizer

/// XCTest rather than swift-testing, deliberately: it works on every toolchain
/// with no macro support needed, and this suite has to be runnable the moment
/// the package is opened.
final class FaultCodeNormalizerTests: XCTestCase {

    /// Convenience: the canonical code for a query, or nil.
    private func canonical(_ input: String?) -> String? {
        FaultCodeNormalizer.normalize(input).faultCode?.canonical
    }

    // MARK: - plan.md §6, the milestone M2 definition of done
    //
    // "every variant listed in §6 resolves to the same hit"

    private static let sectionSixVariants = [
        "F0007",                    // as typed
        "F 0007",                   // separator variant, space
        "F-0007",                   // separator variant, hyphen
        "F7",                       // leading-zero variant
        "F007",                     // leading-zero variant
        "f0007",                    // case variant
        "f zero zero zero seven",   // spoken
        "f triple oh seven",        // spoken, multiplier
        "f seven",                  // spoken, short
    ]

    func testEverySectionSixVariantResolvesToTheSameCode() {
        for variant in Self.sectionSixVariants {
            XCTAssertEqual(canonical(variant), "F7", "variant \(variant) should resolve to F7")
        }
    }

    func testSectionSixVariantsAgreeWithEachOther() {
        let resolved = Set(Self.sectionSixVariants.map { canonical($0) })
        XCTAssertEqual(resolved.count, 1, "all §6 variants must resolve identically")
    }

    func testNormalizationIsIdempotent() {
        for variant in Self.sectionSixVariants {
            let once = canonical(variant)
            XCTAssertEqual(canonical(once), once, "re-normalizing \(variant) changed the result")
        }
    }

    // MARK: - Canonical form

    func testCanonicalFormStripsLeadingZeros() {
        XCTAssertEqual(canonical("F0007"), "F7")
        XCTAssertEqual(canonical("F0022"), "F22")
        XCTAssertEqual(canonical("F22"), "F22")
        XCTAssertEqual(canonical("A006"), "A6")
        XCTAssertEqual(canonical("E05"), "E5")
        XCTAssertEqual(canonical("S22"), "S22")
    }

    // MARK: - Search variants

    func testSearchVariantsCoverTheFormsAManualMightPrint() {
        let variants = FaultCodeNormalizer.normalize("F0007").faultCode?.searchVariants ?? []
        for expected in ["F7", "F 7", "F-7", "F07", "F007", "F0007", "F 0007", "F-0007"] {
            XCTAssertTrue(variants.contains(expected), "missing variant \(expected)")
        }
    }

    func testSearchVariantsAreDeduplicated() {
        let variants = FaultCodeNormalizer.normalize("F0007").faultCode?.searchVariants ?? []
        XCTAssertEqual(variants.count, Set(variants).count)
    }

    func testSearchVariantsNeverNarrowBelowTheCodesOwnWidth() {
        let variants = FaultCodeNormalizer.normalize("F22").faultCode?.searchVariants ?? []
        XCTAssertFalse(variants.contains("F2"), "F22 must never be searched as F2")
        for expected in ["F22", "F022", "F0022", "F-0022"] {
            XCTAssertTrue(variants.contains(expected), "missing variant \(expected)")
        }
    }

    func testBareNumericCodeGetsNoSeparatorVariants() {
        let variants = FaultCodeNormalizer.normalize("fault 7").faultCode?.searchVariants ?? []
        XCTAssertEqual(variants, ["7", "07", "007", "0007"])
    }

    // MARK: - Spoken input

    func testSpokenForms() {
        XCTAssertEqual(canonical("f double oh seven"), "F7")
        XCTAssertEqual(canonical("f naught naught seven"), "F7")
        XCTAssertEqual(canonical("f one two three four"), "F1234")
        XCTAssertEqual(canonical("eff zero zero seven"), "F7")
        XCTAssertEqual(canonical("fault f zero zero zero seven"), "F7")
    }

    func testMultiplierWithoutAFollowingDigitIsNotACode() {
        XCTAssertNil(canonical("triple fault"))
    }

    // MARK: - The component phrase survives

    func testResidualKeepsTheComponentPhrase() {
        let query = FaultCodeNormalizer.normalize("knife controller fault F0007")
        XCTAssertEqual(query.faultCode?.canonical, "F7")
        XCTAssertEqual(query.residualText, "knife controller fault")
    }

    func testResidualPreservesOriginalCasing() {
        let query = FaultCodeNormalizer.normalize("Knife Controller F0007")
        XCTAssertEqual(query.residualText, "Knife Controller")
    }

    func testResidualIsEmptyWhenTheQueryIsOnlyACode() {
        XCTAssertEqual(FaultCodeNormalizer.normalize("f0007").residualText, "")
    }

    // MARK: - Numbers that are not fault codes
    //
    // The failure that would matter most in the plant: searching for the wrong
    // number and confidently showing the wrong page.

    func testMachineNumberIsNotMistakenForTheCode() {
        let query = FaultCodeNormalizer.normalize("line 3 slitter F0007")
        XCTAssertEqual(query.faultCode?.canonical, "F7")
        XCTAssertEqual(query.residualText, "line 3 slitter")
    }

    func testModelNumberIsNotMistakenForTheCode() {
        XCTAssertEqual(canonical("kinetix 5700 f0007"), "F7")
        XCTAssertEqual(canonical("powerflex 755 f5"), "F5")
    }

    func testCatalogNumberIsNotAFaultCode() {
        XCTAssertNil(canonical("2198-D032-ERS3"))
    }

    func testCatalogNumberIsSkippedButARealCodeIsStillFound() {
        XCTAssertEqual(canonical("2198-D032-ERS3 fault F0007"), "F7")
    }

    func testBareNumberIsOnlyACodeWhenTheQuerySaysSo() {
        XCTAssertEqual(canonical("fault 7"), "7")
        XCTAssertEqual(canonical("code 0007"), "7")
        XCTAssertNil(canonical("line 3 slitter"))
        XCTAssertNil(canonical("seven"))
        XCTAssertEqual(canonical("fault seven"), "7")
    }

    func testFirstCodeWinsWhenSeveralArePresent() {
        XCTAssertEqual(canonical("F0007 and F0012"), "F7")
    }

    // MARK: - Non-code queries

    func testNonCodeQuestionYieldsNoCodeAndKeepsItsText() {
        let query = FaultCodeNormalizer.normalize("how do I set the tuning gains")
        XCTAssertNil(query.faultCode)
        XCTAssertEqual(query.residualText, "how do I set the tuning gains")
    }

    func testEmptyAndWhitespaceInput() {
        XCTAssertNil(canonical(""))
        XCTAssertEqual(FaultCodeNormalizer.normalize("").residualText, "")
        XCTAssertNil(canonical("   "))
        XCTAssertNil(canonical(nil))
    }

    // MARK: - Messy typing

    func testPunctuationAndWhitespaceAreTolerated() {
        XCTAssertEqual(canonical("F0007?"), "F7")
        XCTAssertEqual(canonical("...F0007"), "F7")
        XCTAssertEqual(canonical("F_0007"), "F7")
        XCTAssertEqual(canonical("   F0007   "), "F7")
        XCTAssertEqual(canonical("Fault f0007"), "F7")
    }

    // MARK: - Documented boundaries
    //
    // These record deliberate limits. If a real manual violates one, change the
    // constant and the test together.

    func testPrefixLengthBoundary() {
        XCTAssertEqual(canonical("abc0007"), "ABC7", "three letters is a valid prefix")
        XCTAssertNil(canonical("abcd0007"), "four letters is a word, not a prefix")
    }

    func testDigitCountBoundary() {
        XCTAssertEqual(canonical("F12345"), "F12345", "five digits is still a code")
        XCTAssertNil(canonical("F123456"), "six digits exceeds the cap")
    }

    /// The split form ("F 0007") and the spoken form must obey the same digit
    /// cap as the compact form, or the same code parses differently depending on
    /// how it was entered.
    func testDigitCapAppliesToEveryInputForm() {
        XCTAssertEqual(canonical("f 12345"), "F12345")
        XCTAssertNil(canonical("f 123456"))
        XCTAssertNil(canonical("f one two three four five six"))
    }

    func testLetterWithoutDigitsIsNotACode() {
        XCTAssertNil(canonical("f"))
    }
}
