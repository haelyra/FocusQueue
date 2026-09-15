import SwiftUI
import FocusQueueMap

/// Shared map renderer. It owns no task state, collection loop, file opener, or
/// provider integration. Other in-app maps supply a diagram and action callbacks.
struct InteractiveMapCanvas<Card: View>: View {
    let diagram: MapDiagram
    let zoom: Double
    let fitWidth: Bool
    let card: (MapDiagram.Item) -> Card
    let selectContainer: (String) -> Void

    var body: some View {
        GeometryReader { geometry in
            let scale = fitWidth ? min(1, max(0.5, (geometry.size.width - 12) / diagram.width)) * zoom : zoom
            let positions = Dictionary(uniqueKeysWithValues: diagram.items.map { ($0.id, $0) })
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    ForEach(diagram.containers) { container in
                        RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.025))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.secondary.opacity(0.25)))
                            .frame(width: container.width, height: container.height)
                            .overlay(alignment: .topLeading) {
                                Button { selectContainer(container.id) } label: {
                                    Text(container.label).font(.system(size: 10, weight: .semibold))
                                        .lineLimit(1).padding(.horizontal, 8).padding(.vertical, 5)
                                }.buttonStyle(.plain)
                            }.offset(x: container.x, y: container.y)
                    }
                    Canvas { context, _ in
                        for edge in diagram.edges {
                            guard let from = positions[edge.from], let to = positions[edge.to] else { continue }
                            let forward = to.x > from.x
                            let sameColumn = abs(from.x - to.x) < 10
                            let start = CGPoint(x: from.x + (forward || sameColumn ? MapDiagram.nodeWidth : 0), y: from.y + MapDiagram.nodeHeight / 2)
                            let end = CGPoint(x: to.x + (forward ? 0 : MapDiagram.nodeWidth), y: to.y + MapDiagram.nodeHeight / 2)
                            var path = Path(); path.move(to: start)
                            if sameColumn || edge.kind == "feedback" {
                                let gutter = max(start.x, end.x) + 24
                                path.addCurve(to: end, control1: CGPoint(x: gutter, y: start.y), control2: CGPoint(x: gutter, y: end.y))
                            } else {
                                let middle = (start.x + end.x) / 2
                                path.addCurve(to: end, control1: CGPoint(x: middle, y: start.y), control2: CGPoint(x: middle, y: end.y))
                            }
                            let tint: Color = edge.kind == "output" ? .green : edge.kind == "feedback" ? .orange : edge.kind == "hierarchy" ? .secondary : .accentColor
                            context.stroke(path, with: .color(tint.opacity(0.65)), style: StrokeStyle(lineWidth: 1.3, dash: ["input", "context"].contains(edge.kind) ? [4, 3] : []))
                            if edge.kind != "hierarchy" {
                                let direction = forward && !sameColumn && edge.kind != "feedback" ? -1.0 : 1.0
                                var arrow = Path(); arrow.move(to: end)
                                arrow.addLine(to: CGPoint(x: end.x + direction * 6, y: end.y - 3))
                                arrow.addLine(to: CGPoint(x: end.x + direction * 6, y: end.y + 3)); arrow.closeSubpath()
                                context.fill(arrow, with: .color(tint.opacity(0.9)))
                            }
                        }
                    }.allowsHitTesting(false).accessibilityHidden(true)
                    ForEach(diagram.items) { item in
                        card(item).frame(width: MapDiagram.nodeWidth, height: MapDiagram.nodeHeight)
                            .offset(x: item.x, y: item.y)
                    }
                }.frame(width: diagram.width + 30, height: diagram.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: (diagram.width + 30) * scale, height: diagram.height * scale, alignment: .topLeading)
            }.background(Color(nsColor: .windowBackgroundColor).opacity(0.97), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)).allowsHitTesting(false))
        }.frame(minHeight: 220)
    }
}

private struct DelayedMapPath: ViewModifier {
    let path: String?
    @State private var hovered = false
    @State private var presented = false
    func body(content: Content) -> some View {
        content.onHover { value in hovered = value; if !value { presented = false } }
            .task(id: hovered) {
                guard hovered, path != nil else { return }
                do { try await Task.sleep(for: .seconds(1)); try Task.checkCancellation(); presented = true }
                catch { }
            }
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                Text(path ?? "").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .padding(10).frame(maxWidth: 520, alignment: .leading)
            }
    }
}
extension View {
    func mapPathTooltip(_ path: String?) -> some View { modifier(DelayedMapPath(path: path)) }
}
