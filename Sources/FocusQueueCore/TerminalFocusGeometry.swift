import CoreGraphics

public enum TerminalFocusGeometry {
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

    public static func backdropRegions(
        screenFrame: CGRect,
        focusedFrame: CGRect?,
        gap: CGFloat = 18
    ) -> [CGRect] {
        guard let focusedFrame else { return [screenFrame] }
        let aperture = focusedFrame.insetBy(dx: -gap, dy: -gap).intersection(screenFrame)
        guard !aperture.isNull, !aperture.isEmpty else { return [screenFrame] }

        return [
            CGRect(
                x: screenFrame.minX,
                y: aperture.maxY,
                width: screenFrame.width,
                height: max(0, screenFrame.maxY - aperture.maxY)
            ),
            CGRect(
                x: screenFrame.minX,
                y: screenFrame.minY,
                width: screenFrame.width,
                height: max(0, aperture.minY - screenFrame.minY)
            ),
            CGRect(
                x: screenFrame.minX,
                y: aperture.minY,
                width: max(0, aperture.minX - screenFrame.minX),
                height: aperture.height
            ),
            CGRect(
                x: aperture.maxX,
                y: aperture.minY,
                width: max(0, screenFrame.maxX - aperture.maxX),
                height: aperture.height
            ),
        ].filter { $0.width > 0 && $0.height > 0 }
    }
}
