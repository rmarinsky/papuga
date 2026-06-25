import Foundation

/// Burkhard-Keller tree (1973) for fast "all words within edit distance k"
/// queries — used to cluster the user's mistakes by mutual similarity without an
/// O(n²) all-pairs scan. Keyed on plain Levenshtein (a true metric, so the
/// triangle-inequality pruning is exact).
///
/// Reference: Burkhard & Keller, "Some Approaches to Best-Match File Searching",
/// CACM 1973.
final class BKTree {
    private final class Node {
        let word: String
        var children: [Int: Node] = [:]
        init(_ word: String) { self.word = word }
    }

    private var root: Node?
    private(set) var count = 0

    func insert(_ word: String) {
        guard let root else { self.root = Node(word); count = 1; return }
        var node = root
        while true {
            let distance = Self.distance(word, node.word)
            if distance == 0 { return } // already present
            if let child = node.children[distance] {
                node = child
            } else {
                node.children[distance] = Node(word)
                count += 1
                return
            }
        }
    }

    /// Every stored word within `maxDistance` of `query` (excluding the query
    /// itself unless `includeSelf`).
    func neighbors(of query: String, within maxDistance: Int, includeSelf: Bool = false) -> [String] {
        guard let root else { return [] }
        var results: [String] = []
        var stack = [root]
        while let node = stack.popLast() {
            let distance = Self.distance(query, node.word)
            if distance <= maxDistance, distance != 0 || includeSelf {
                results.append(node.word)
            }
            let lower = distance - maxDistance
            let upper = distance + maxDistance
            for (edge, child) in node.children where edge >= lower && edge <= upper {
                stack.append(child)
            }
        }
        return results
    }

    static func distance(_ a: String, _ b: String) -> Int {
        ManualCorrectionTracker.levenshteinDistance(a, b)
    }
}
