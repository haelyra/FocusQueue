import Foundation

public enum MapAgentFocus {
    /// Current reported work first. Backfill to four with important/recent
    /// historical writes, then declared outputs. Git status never assigns authors.
    public static func relations(agent: MapNode, snapshot: MapSnapshot, options: WorkspaceMapOptions, now: Date) -> [MapRelation] {
        let all = snapshot.relations.filter { ($0.from == agent.id && $0.kind == .output) || ($0.to == agent.id && $0.kind == .input) }
        func recent(_ edge: MapRelation) -> Bool {
            guard agent.state(at: now) == "working", let date = edge.observedAt else { return false }
            return now.timeIntervalSince(date) >= -60 && now.timeIntervalSince(date) <= options.scopeLifetime
        }
        func ranked(_ a: MapRelation, _ b: MapRelation) -> Bool {
            let ap = a.importance ?? 0, bp = b.importance ?? 0
            if ap != bp { return ap > bp }
            if a.observedAt != b.observedAt { return (a.observedAt ?? .distantPast) > (b.observedAt ?? .distantPast) }
            return a.id < b.id
        }
        if options.retrospective { return all.filter { $0.kind == .output && $0.evidence == "Reported write" }.sorted(by: ranked) }
        if options.includeOlderScope { return all.sorted(by: ranked) }
        let provided = all.filter { $0.evidence.hasPrefix("Provided") }
        var chosen = all.filter { recent($0) && !$0.evidence.hasPrefix("Provided") }.sorted(by: ranked)
        var files = Set(chosen.map { $0.kind == .input ? $0.from : $0.to })
        for edge in all.filter({ $0.kind == .output }).sorted(by: {
            if ($0.evidence == "Reported write") != ($1.evidence == "Reported write") { return $0.evidence == "Reported write" }
            return ranked($0, $1)
        }) where files.count < 4 {
            if files.insert(edge.to).inserted { chosen.append(edge) }
        }
        return chosen + provided
    }
}
