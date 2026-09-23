import CoreGraphics

public enum DisplayGeometry {
    public static func screenIndex(
        containing point: CGPoint,
        screenFrames: [CGRect]
    ) -> Int? {
        screenFrames.firstIndex { $0.contains(point) }
    }

    public static func nextScreenIndex(
        currentScreenFrame: CGRect,
        orderedScreenFrames: [CGRect]
    ) -> Int? {
        guard orderedScreenFrames.count > 1 else { return nil }
        guard let currentIndex = orderedScreenFrames.firstIndex(of: currentScreenFrame) else {
            return 0
        }
        return (currentIndex + 1) % orderedScreenFrames.count
    }

    public static func panelFrame(
        preferredWidth: CGFloat,
        visibleFrame: CGRect,
        placement: QueueWindowPlacement,
        margin: CGFloat = 12,
        topMargin: CGFloat = 12,
        minimumWidth: CGFloat = 400,
        maximumWidth: CGFloat = 620
    ) -> CGRect {
        let availableWidth = max(0, visibleFrame.width - (margin * 2))
        let availableHeight = max(0, visibleFrame.height - margin - topMargin)
        let effectiveMinimumWidth = min(minimumWidth, availableWidth)
        let width = min(max(preferredWidth, effectiveMinimumWidth), min(maximumWidth, availableWidth))

        let x: CGFloat
        switch placement {
        case .upperLeft:
            x = visibleFrame.minX + margin
        case .upperRight:
            x = visibleFrame.maxX - width - margin
        case .center:
            x = visibleFrame.midX - (width / 2)
        }

        return CGRect(
            x: x,
            y: visibleFrame.minY + margin,
            width: width,
            height: availableHeight
        ).integral
    }
}

public enum TerminalFocusGeometry {
    public struct DisplayTarget: Equatable {
        public let screenIndex: Int
        public let frame: CGRect

        public init(screenIndex: Int, frame: CGRect) {
            self.screenIndex = screenIndex
            self.frame = frame
        }
    }

    public static func centeredFrame(
        currentFrame: CGRect,
        visibleFrame: CGRect,
        maximumWidthFraction: CGFloat = 0.84,
        maximumHeightFraction: CGFloat = 0.84
    ) -> CGRect {
        let width = min(currentFrame.width, visibleFrame.width * maximumWidthFraction)
        let height = min(currentFrame.height, visibleFrame.height * maximumHeightFraction)
        return CGRect(
            x: visibleFrame.midX - (width / 2),
            y: visibleFrame.midY - (height / 2),
            width: width,
            height: height
        ).integral
    }

    public static func nextDisplayTarget(
        currentWindowFrame: CGRect,
        preferredWindowFrame: CGRect,
        screenFrames: [CGRect],
        visibleScreenFrames: [CGRect]
    ) -> DisplayTarget? {
        guard screenFrames.count > 1,
              screenFrames.count == visibleScreenFrames.count else {
            return nil
        }

        let overlaps: [(index: Int, area: CGFloat)] = screenFrames.enumerated()
            .map { index, frame in
                let intersection = frame.intersection(currentWindowFrame)
                let area: CGFloat = intersection.isNull
                    ? 0
                    : intersection.width * intersection.height
                return (index: index, area: area)
            }
        let currentIndex = overlaps
            .filter { $0.area > 0 }
            .max { $0.area < $1.area }?
            .index
        let nextIndex = currentIndex.map { ($0 + 1) % screenFrames.count } ?? 0
        return DisplayTarget(
            screenIndex: nextIndex,
            frame: centeredFrame(
                currentFrame: preferredWindowFrame,
                visibleFrame: visibleScreenFrames[nextIndex]
            )
        )
    }

}
