import Foundation

/// Orthogonal channel routing: card rectangles are hard obstacles; crossings and
/// shared channels between unrelated connections carry a strong cost. Tree edges
/// use adjacent-column gutters; feedback loops can take an outside row channel.
public enum MapEdgeRouter {
    public static func intersects(_ a: MapDiagram.Point, _ b: MapDiagram.Point, item: MapDiagram.Item) -> Bool {
        let left = item.x + 0.1, right = item.x + MapDiagram.nodeWidth - 0.1
        let top = item.y + 0.1, bottom = item.y + MapDiagram.nodeHeight - 0.1
        if a.x == b.x { return a.x > left && a.x < right && max(a.y, b.y) > top && min(a.y, b.y) < bottom }
        if a.y == b.y { return a.y > top && a.y < bottom && max(a.x, b.x) > left && min(a.x, b.x) < right }
        return true
    }
    public static func route(_ diagram: inout MapDiagram) {
        typealias P = MapDiagram.Point
        let nodes = Dictionary(uniqueKeysWithValues: diagram.items.map { ($0.id, $0) })
        var routed: [(MapDiagram.Edge, [P])] = []
        let ys = Array(Set(diagram.items.flatMap { [$0.y - 10, $0.y + MapDiagram.nodeHeight + 10] })).sorted()
        func segments(_ points: [P]) -> [(P, P)] { zip(points, points.dropFirst()).filter { $0 != $1 } }
        for i in diagram.edges.indices {
            let edge = diagram.edges[i]
            guard let from = nodes[edge.from], let to = nodes[edge.to] else { continue }
            let forward = to.x > from.x
            let start = P(x: from.x + MapDiagram.nodeWidth, y: from.y + MapDiagram.nodeHeight / 2)
            let end = P(x: to.x + (forward ? 0 : MapDiagram.nodeWidth), y: to.y + MapDiagram.nodeHeight / 2)
            let a = P(x: start.x + 9, y: start.y), b = P(x: end.x + (forward ? -9 : 9), y: end.y)
            var candidates: [[P]] = []
            if forward {
                for lane in [(a.x + b.x) / 2, a.x, b.x] {
                    candidates.append([start, P(x: lane, y: start.y), P(x: lane, y: end.y), end])
                }
            }
            func score(_ path: [P]) -> Double {
                let pieces = segments(path)
                guard !pieces.contains(where: { line in diagram.items.contains { intersects(line.0, line.1, item: $0) } }) else { return .infinity }
                var cost = pieces.reduce(0.0) { $0 + abs($1.1.x - $1.0.x) + abs($1.1.y - $1.0.y) } + Double(pieces.count) * 12
                for (other, route) in routed where other.from != edge.from && other.to != edge.to {
                    for (p, q) in pieces {
                        for (r, s) in segments(route) {
                            if p.x == q.x && r.y == s.y && p.x > min(r.x, s.x) && p.x < max(r.x, s.x) && r.y > min(p.y, q.y) && r.y < max(p.y, q.y) { cost += 800 }
                            if p.y == q.y && r.x == s.x && r.x > min(p.x, q.x) && r.x < max(p.x, q.x) && p.y > min(r.y, s.y) && p.y < max(r.y, s.y) { cost += 800 }
                            if p.x == q.x && r.x == s.x && p.x == r.x && min(max(p.y, q.y), max(r.y, s.y)) > max(min(p.y, q.y), min(r.y, s.y)) { cost += 400 }
                            if p.y == q.y && r.y == s.y && p.y == r.y && min(max(p.x, q.x), max(r.x, s.x)) > max(min(p.x, q.x), min(r.x, s.x)) { cost += 400 }
                        }
                    }
                }
                return cost
            }
            var scored = candidates.enumerated().map { ($0.offset, $0.element, score($0.element)) }.filter { $0.2.isFinite }
            let directDistance = abs(start.x - end.x) + abs(start.y - end.y)
            // Adjacent tree ranks almost always have a clear, crossing-free
            // channel. Reserve the wider search for actual feedback/congestion.
            if (scored.map { $0.2 }.min() ?? .infinity) > directDistance + 100 {
                for y in ys {
                    candidates.append([start, a, P(x: a.x, y: y), P(x: b.x, y: y), b, end])
                }
                scored = candidates.enumerated().map { ($0.offset, $0.element, score($0.element)) }.filter { $0.2.isFinite }
            }
            if let best = scored.min(by: { ($0.2, $0.0) < ($1.2, $1.0) }) {
                diagram.edges[i].points = best.1; routed.append((edge, best.1))
            }
        }
    }
}
