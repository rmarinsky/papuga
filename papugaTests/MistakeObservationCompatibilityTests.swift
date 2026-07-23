import XCTest
@testable import papuga

final class MistakeObservationCompatibilityTests: XCTestCase {
    func test_groupRenderingPreservesSourcePunctuationAroundSuggestedCore() {
        let observation = MistakeObservation(
            issueType: .spelling,
            source: "“можі?”",
            suggestedTarget: "може",
            language: "uk",
            confidence: 0.9
        )

        XCTAssertEqual(MistakeGroupData(entries: [observation]).renderedTarget, "“може?”")

        let prediction = PredictionGroup(
            id: "uk|можі",
            source: "“можі?”",
            language: "uk",
            count: 1,
            lastSeen: Date(),
            candidates: [],
            primaryTarget: "може",
            observationIDs: [observation.id]
        )
        XCTAssertEqual(prediction.renderedPrimaryTarget, "“може?”")
    }

    func test_newObservationStoresSuggestedCoreWithoutTargetPunctuation() {
        let observation = MistakeObservation(
            issueType: .spelling,
            source: "можі,",
            suggestedTarget: "може,",
            language: "uk",
            confidence: 0.9
        )

        XCTAssertEqual(observation.suggestedTarget, "може")
        XCTAssertEqual(observation.renderedSuggestedTarget, "може,")
    }

    func test_decodesLegacyObservationAndDerivesCoreAndEdges() throws {
        let json = """
        {
          "id":"00000000-0000-0000-0000-000000000001",
          "timestamp":0,
          "issueType":"spelling",
          "status":"open",
          "source":"Unfortunatly,",
          "suggestedTarget":"Unfortunately",
          "sourceTruncated":false,
          "targetTruncated":false,
          "language":"en",
          "bundleID":"com.example.editor",
          "confidence":0.68
        }
        """

        let observation = try JSONDecoder().decode(MistakeObservation.self, from: Data(json.utf8))

        XCTAssertEqual(observation.source, "Unfortunatly,")
        XCTAssertEqual(observation.sourceCore, "Unfortunatly")
        XCTAssertEqual(observation.leadingPunctuation, "")
        XCTAssertEqual(observation.trailingPunctuation, ",")
        XCTAssertEqual(observation.renderedSuggestedTarget, "Unfortunately,")
    }
}
