import Foundation

/// Converts between the coordinate spaces Desktop Pilot has to reconcile.
///
/// Shared space is global points with the origin at the top-left of the primary
/// display and y increasing downward. That matches Accessibility frames and
/// Quartz event locations.
///
/// Cocoa and `NSScreen` use the bottom-left of the primary display, y upward.
/// ScreenCaptureKit window frames follow Cocoa screen space.
/// Vision text boxes are normalized to the captured image with a bottom-left origin.
public enum CoordinateConverter {
    public static func cocoaRectToGlobal(cocoa: Rect, primaryHeight: Double) -> Rect {
        Rect(
            x: cocoa.x,
            y: primaryHeight - cocoa.y - cocoa.height,
            width: cocoa.width,
            height: cocoa.height
        )
    }

    public static func globalRectToCocoa(global: Rect, primaryHeight: Double) -> Rect {
        Rect(
            x: global.x,
            y: primaryHeight - global.y - global.height,
            width: global.width,
            height: global.height
        )
    }

    public static func cocoaPointToGlobal(cocoa: Point, primaryHeight: Double) -> Point {
        Point(x: cocoa.x, y: primaryHeight - cocoa.y)
    }

    public static func globalPointToCocoa(global: Point, primaryHeight: Double) -> Point {
        Point(x: global.x, y: primaryHeight - global.y)
    }

    /// Vision's normalized box (origin bottom-left, 0...1) into pixels whose
    /// origin is the top-left of the captured image.
    public static func visionNormalizedToCapturePixels(
        originX: Double,
        originY: Double,
        boxWidth: Double,
        boxHeight: Double,
        imageWidth: Double,
        imageHeight: Double
    ) -> Rect {
        let width = boxWidth * imageWidth
        let height = boxHeight * imageHeight
        let x = originX * imageWidth
        let y = (1 - originY - boxHeight) * imageHeight
        return Rect(x: x, y: y, width: width, height: height)
    }

    /// Capture pixels (top-left of the captured image) into shared global points.
    /// `scale` is pixels per point. `captureGlobal` is the captured window in shared space.
    public static func capturePixelsToGlobal(pixels: Rect, captureGlobal: Rect, scale: Double) -> Rect {
        let safeScale = scale == 0 ? 1 : scale
        return Rect(
            x: captureGlobal.x + pixels.x / safeScale,
            y: captureGlobal.y + pixels.y / safeScale,
            width: pixels.width / safeScale,
            height: pixels.height / safeScale
        )
    }

    /// Full path from a Vision box to shared global points.
    public static func visionBoxToGlobal(
        originX: Double,
        originY: Double,
        boxWidth: Double,
        boxHeight: Double,
        imageWidth: Double,
        imageHeight: Double,
        captureGlobal: Rect,
        scale: Double
    ) -> Rect {
        let pixels = visionNormalizedToCapturePixels(
            originX: originX,
            originY: originY,
            boxWidth: boxWidth,
            boxHeight: boxHeight,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
        return capturePixelsToGlobal(pixels: pixels, captureGlobal: captureGlobal, scale: scale)
    }
}
