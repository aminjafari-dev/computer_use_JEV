import AppKit
import CoreGraphics
import PilotCore
import ScreenCaptureKit

struct DisplayGeometry: Sendable {
    var primaryHeight: Double

    @MainActor
    static func snapshot() -> DisplayGeometry {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
        return DisplayGeometry(primaryHeight: primary)
    }
}

struct WindowCapture: @unchecked Sendable {
    var image: CGImage
    var globalRect: Rect
    var scale: Double
}

enum WindowCaptureService {
    static func capture(windowID: UInt32) async -> WindowCapture? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        return try? await captureAsync(windowID: windowID)
    }

    private static func captureAsync(windowID: UInt32) async throws -> WindowCapture? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = await scale(for: window.frame)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let geometry = await DisplayGeometry.snapshot()
        let cocoa = Rect(x: window.frame.origin.x, y: window.frame.origin.y, width: window.frame.width, height: window.frame.height)
        let global = CoordinateConverter.cocoaRectToGlobal(cocoa: cocoa, primaryHeight: geometry.primaryHeight)
        return WindowCapture(image: image, globalRect: global, scale: scale)
    }

    @MainActor
    private static func scale(for frame: CGRect) -> Double {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        return Double(screen?.backingScaleFactor ?? 2)
    }
}
