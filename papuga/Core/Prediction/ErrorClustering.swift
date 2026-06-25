import Foundation

/// Clusters all of the user's mistakes by similarity, so the "Усі" tab can show
/// patterns even among one-off errors: mistakes within a small edit distance of
/// each other, or that correct to the same word, are grouped together.
///
/// Edges come from two cheap signals — a shared correction target (O(n)) and
/// BK-tree neighbours within `maxDistance` (sub-quadratic) — merged with
/// union-find. Per-language so Cyrillic and Latin never cross.
enum ErrorClustering {
    struct Item {
        let source: String
        let language: String
        let count: Int
        let target: String?
        let observationIDs: [UUID]
        var normalizedSource: String { MistakeObservation.normalizedToken(source) }
        var normalizedTarget: String? { target.map(MistakeObservation.normalizedToken) }
    }

    static func cluster(_ items: [Item], maxDistance: Int = 2) -> [ErrorCluster] {
        guard !items.isEmpty else { return [] }
        var clusters: [ErrorCluster] = []
        let byLanguage = Dictionary(grouping: items.indices) { items[$0].language }

        for (language, indices) in byLanguage {
            let local = indices.map { items[$0] }
            let parent = UnionFind(count: local.count)

            // Edge 1: same correction target.
            var byTarget: [String: [Int]] = [:]
            for (i, item) in local.enumerated() {
                if let target = item.normalizedTarget, !target.isEmpty {
                    byTarget[target, default: []].append(i)
                }
            }
            for group in byTarget.values where group.count > 1 {
                for i in group.dropFirst() { parent.union(group[0], i) }
            }

            // Edge 2: small edit distance (BK-tree neighbours).
            let tree = BKTree()
            var indexOf: [String: Int] = [:]
            for (i, item) in local.enumerated() {
                let token = item.normalizedSource
                if indexOf[token] == nil { indexOf[token] = i; tree.insert(token) }
            }
            for (i, item) in local.enumerated() {
                for neighbour in tree.neighbors(of: item.normalizedSource, within: maxDistance) {
                    if let j = indexOf[neighbour] { parent.union(i, j) }
                }
            }

            // Build clusters from connected components.
            var components: [Int: [Int]] = [:]
            for i in local.indices { components[parent.find(i), default: []].append(i) }
            for member in components.values {
                let memberItems = member.map { local[$0] }
                clusters.append(makeCluster(memberItems, language: language))
            }
        }

        return clusters.sorted { lhs, rhs in
            if lhs.members.count != rhs.members.count { return lhs.members.count > rhs.members.count }
            return lhs.totalCount > rhs.totalCount
        }
    }

    private static func makeCluster(_ items: [Item], language: String) -> ErrorCluster {
        let members = items
            .map { item in
                ErrorClusterMember(
                    id: "\(language)|\(item.normalizedSource)",
                    source: item.source, language: language, count: item.count,
                    target: item.target, observationIDs: item.observationIDs
                )
            }
            .sorted { $0.count > $1.count }

        // Representative: a shared target if the whole cluster agrees on one,
        // otherwise the most frequent member's word.
        let targets = Set(items.compactMap { $0.normalizedTarget }.filter { !$0.isEmpty })
        let representative = targets.count == 1 ? (members.first?.target ?? members[0].source) : members[0].source
        let id = "\(language)|" + members.map(\.source).joined(separator: ",")
        return ErrorCluster(id: id, representative: representative, language: language, members: members)
    }
}

/// Minimal union-find with path compression.
private final class UnionFind {
    private var parent: [Int]
    init(count: Int) { parent = Array(0..<count) }
    func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var node = x
        while parent[node] != root { let next = parent[node]; parent[node] = root; node = next }
        return root
    }
    func union(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[ra] = rb } }
}
