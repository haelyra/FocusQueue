import SwiftUI
import FocusQueueMap

/// Shared map renderer. It owns no task state, collection loop, file opener, or
/// provider integration. Other in-app maps supply a diagram and action callbacks.
struct InteractiveMapCanvas<Card: View>: View {
    let diagram: MapDiagram
    let zoom: Double
    let fitWidth: Bool
    let card: (MapDiagram.Item) -> Card
    var backgroundAction: () -> Void = {}
    let selectContainer: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let scale = fitWidth ? min(1, max(0.45, (geometry.size.width - 12) / diagram.width)) * zoom : zoom
            let signature = diagram.items.map { "\($0.id):\($0.x):\($0.y)" }.joined(separator: "|")
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    ForEach(diagram.containers) { container in
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.025))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.secondary.opacity(0.24)))
                                .allowsHitTesting(false)
                            Button { selectContainer(container.id) } label: {
                                Label(container.label, systemImage: "square.dashed")
                                    .font(.system(size: 9, weight: .semibold)).lineLimit(1)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                                    .overlay(Capsule().stroke(Color.secondary.opacity(0.24)))
                            }
                            .buttonStyle(.plain).offset(x: 10, y: -9)
                            .help(container.label)
                        }
                        .frame(width: container.width, height: container.height)
                        .offset(x: container.x, y: container.y)
                    }
                    ForEach(diagram.edges) { edge in
                        if let points = edge.points {
                            let tint: Color = edge.kind == "output" ? .green : edge.kind == "feedback" ? .orange : .secondary
                            MapConnectionShape(points: points, arrow: edge.kind != "hierarchy")
                                .stroke(tint.opacity(0.55), style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    ForEach(diagram.items) { item in
                        card(item).frame(width: MapDiagram.nodeWidth, height: MapDiagram.nodeHeight)
                            .offset(x: item.x, y: item.y)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 12)), removal: .opacity))
                    }
                }.frame(width: max(diagram.width + 30, geometry.size.width / scale), height: max(diagram.height, geometry.size.height / scale), alignment: .topLeading)
                    .background(Color.clear.contentShape(Rectangle()).onTapGesture { backgroundAction() })
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: max((diagram.width + 30) * scale, geometry.size.width), height: max(diagram.height * scale, geometry.size.height), alignment: .topLeading)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: signature)
            }.background(Color(nsColor: .windowBackgroundColor).opacity(0.97), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)).allowsHitTesting(false))
        }.frame(minHeight: 220)
    }
}

/// Fixed-size animation vector keeps the route and its endpoints gliding with
/// the cards. Short routes repeat their last point to retain the same dimension.
private struct MapRouteVector: VectorArithmetic {
    var values: [Double]
    static var zero: Self { .init(values: Array(repeating: 0, count: 16)) }
    static func + (a: Self, b: Self) -> Self { .init(values: zip(a.values, b.values).map(+)) }
    static func - (a: Self, b: Self) -> Self { .init(values: zip(a.values, b.values).map(-)) }
    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
}
private struct MapConnectionShape: Shape {
    var vector: MapRouteVector
    let arrow: Bool
    init(points: [MapDiagram.Point], arrow: Bool) {
        let last = points.last ?? .init(x: 0, y: 0)
        let padded = Array(points.prefix(8)) + Array(repeating: last, count: max(0, 8 - points.count))
        vector = .init(values: padded.flatMap { [$0.x, $0.y] }); self.arrow = arrow
    }
    var animatableData: MapRouteVector { get { vector } set { vector = newValue } }
    func path(in rect: CGRect) -> Path {
        let points = stride(from: 0, to: vector.values.count, by: 2).map { CGPoint(x: vector.values[$0], y: vector.values[$0 + 1]) }
        var path = Path(); path.addLines(points)
        if arrow, let end = points.last, let before = points.last(where: { $0 != end }) {
            let dx = end.x - before.x, dy = end.y - before.y, length = max(1, hypot(dx, dy))
            let ux = dx / length, uy = dy / length
            path.move(to: CGPoint(x: end.x - ux * 6 - uy * 3, y: end.y - uy * 6 + ux * 3)); path.addLine(to: end)
            path.addLine(to: CGPoint(x: end.x - ux * 6 + uy * 3, y: end.y - uy * 6 - ux * 3))
        }
        return path
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
