import XCTest
@testable import papuga

/// Locks the prompt/context contract: aliases are stable, kind is mapped, secrets are held
/// back, and the emitted context round-trips cleanly through the existing validator.
final class AIPromptBuilderTests: XCTestCase {

    func testKindMapping() {
        XCTAssertEqual(AIPromptBuilder.kind(for: .layoutCandidate), "layout")
        XCTAssertEqual(AIPromptBuilder.kind(for: .spelling), "spelling")
        XCTAssertEqual(AIPromptBuilder.kind(for: .manualCorrection), "spelling")
        XCTAssertEqual(AIPromptBuilder.kind(for: .grammar), "grammar")
    }

    func testRoundTripsIntoValidator() {
        let observation = MistakeObservation(issueType: .layoutCandidate, source: "ghbdtn",
                                             language: "uk", bundleID: "com.apple.Safari", confidence: 0.9)
        let groups = MistakesScreenDerivation.groups(from: [observation], filter: .all, query: "")
        let batch = AIPromptBuilder.build(from: groups, sendAppNames: false, scrubSecrets: true)

        XCTAssertEqual(batch.itemCount, 1)
        let alias = try! XCTUnwrap(batch.context.knownAliases.first)
        XCTAssertEqual(batch.context.sourceForAlias[alias], "ghbdtn")
        XCTAssertTrue(batch.prompt.contains("«ghbdtn»"))
        XCTAssertTrue(batch.prompt.contains("схоже на іншу розкладку"))

        let answer = """
        ```json
        {"version":1,"suggestions":[{"id":"\(alias)","action":"rule","target":"привіт","tag":"layout","clusterId":null,"confidence":0.95,"reason":"layout flip"}]}
        ```
        """
        let result = AIResponseValidator.validate(answer, context: batch.context)
        XCTAssertNil(result.blocked)
        XCTAssertEqual(result.recognizedCount, 1)
        XCTAssertEqual(result.recognized.first?.id, alias)
        // Cross-script flip with no corroborator → flagged for review, never auto-applied.
        XCTAssertEqual(result.recognized.first?.needsReview, true)
    }

    func testMergesSameWordAcrossApps() {
        // The same misspelling typed in two apps must become ONE prompt line whose item carries
        // both observations — the model never sees a duplicate, and applying resolves both.
        let inSafari = MistakeObservation(issueType: .spelling, source: "teh", language: "en",
                                          bundleID: "com.apple.Safari", confidence: 0.9)
        let inXcode = MistakeObservation(issueType: .spelling, source: "teh", language: "en",
                                         bundleID: "com.apple.dt.Xcode", confidence: 0.9)
        let groups = MistakesScreenDerivation.groups(from: [inSafari, inXcode], filter: .all, query: "")
        let batch = AIPromptBuilder.build(from: groups, sendAppNames: false, scrubSecrets: true)

        XCTAssertEqual(batch.itemCount, 1)
        let alias = try! XCTUnwrap(batch.context.knownAliases.first)
        XCTAssertEqual(Set(batch.items[alias]?.observationIDs ?? []), [inSafari.id, inXcode.id])
        // Only one occurrence of the word in the prompt.
        let occurrences = batch.prompt.components(separatedBy: "«teh»").count - 1
        XCTAssertEqual(occurrences, 1)
    }

    func testHoldsBackSecretSource() {
        let secret = MistakeObservation(issueType: .spelling, source: "sk-ABCDEFGHIJKLMNOP1234",
                                        language: "en", confidence: 0.5)
        let normal = MistakeObservation(issueType: .spelling, source: "teh",
                                        language: "en", confidence: 0.5)
        let groups = MistakesScreenDerivation.groups(from: [secret, normal], filter: .all, query: "")
        let batch = AIPromptBuilder.build(from: groups, sendAppNames: false, scrubSecrets: true)

        XCTAssertEqual(batch.redactedSecretCount, 1)
        XCTAssertEqual(batch.itemCount, 1)
        XCTAssertFalse(batch.prompt.contains("sk-ABCDEFGHIJKLMNOP1234"))
    }
}
