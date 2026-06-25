import XCTest
@testable import papuga

final class ErrorClusteringTests: XCTestCase {

    func test_bkTree_findsNeighboursWithinDistance() {
        let tree = BKTree()
        for w in ["cat", "bat", "cut", "cot", "dog", "card"] { tree.insert(w) }
        let neighbours = Set(tree.neighbors(of: "cat", within: 1))
        XCTAssertEqual(neighbours, ["bat", "cut", "cot"]) // distance 1
        XCTAssertFalse(neighbours.contains("card")) // distance 2
        XCTAssertFalse(neighbours.contains("dog"))  // far
        XCTAssertTrue(Set(tree.neighbors(of: "cat", within: 2)).contains("card"))
    }

    func test_clustering_groupsSimilarWords() {
        func item(_ s: String, _ t: String?) -> ErrorClustering.Item {
            .init(source: s, language: "uk", count: 1, target: t, observationIDs: [UUID()])
        }
        let clusters = ErrorClustering.cluster([
            item("темплейт", nil), item("темплейтів", nil), item("темплейти", nil), // close edits
            item("привіт", nil), // far → singleton
        ], maxDistance: 2)

        let family = clusters.first { c in c.members.contains { $0.source == "темплейт" } }
        XCTAssertEqual(family?.members.count, 3, "темплейт variants cluster together")
        XCTAssertTrue(clusters.contains { $0.isSingleton && $0.members.first?.source == "привіт" })
    }

    func test_clustering_groupsBySharedTarget() {
        func item(_ s: String, _ t: String?) -> ErrorClustering.Item {
            .init(source: s, language: "uk", count: 1, target: t, observationIDs: [UUID()])
        }
        // Two dissimilar sources that correct to the same word.
        let clusters = ErrorClustering.cluster([
            item("abcdef", "ціль"), item("zzzzzz", "ціль"),
        ], maxDistance: 2)
        XCTAssertEqual(clusters.count, 1, "shared target merges them despite the distance")
        XCTAssertEqual(clusters.first?.members.count, 2)
        XCTAssertEqual(clusters.first?.representative, "ціль") // shared target is the representative
    }

    func test_clustering_keepsLanguagesSeparate() {
        func item(_ s: String, _ lang: String) -> ErrorClustering.Item {
            .init(source: s, language: lang, count: 1, target: nil, observationIDs: [UUID()])
        }
        // Same letters won't happen across scripts, but enforce the partition.
        let clusters = ErrorClustering.cluster([item("cat", "en"), item("cot", "uk")], maxDistance: 2)
        XCTAssertEqual(clusters.count, 2, "different languages never cluster")
    }
}
