import AppKit
import CoreGraphics
import ImageIO
import PilotCore
import SwiftUI

@MainActor
final class CommandPanelController {
    private let panel: NSPanel
    private let hosting: NSHostingView<AnyView>

    init() {
        hosting = NSHostingView(rootView: AnyView(Color.clear))
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Desktop Pilot"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = true
        panel.contentView = hosting
        panel.setAccessibilityElement(false)
    }

    var isVisible: Bool { panel.isVisible }

    func bind(_ model: AppModel) {
        hosting.rootView = AnyView(CommandPanelView(model: model))
    }

    func show() {
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 24))
        }
        panel.orderFrontRegardless()
    }

    func orderOut() { panel.orderOut(nil) }
}

@MainActor
final class HighlightOverlay {
    private let window: NSWindow
    private let box = HighlightView()

    init() {
        window = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = box
        window.setAccessibilityElement(false)
    }

    func show(global: Rect) {
        let geometry = DisplayGeometry.snapshot()
        let cocoa = CoordinateConverter.globalRectToCocoa(global: global, primaryHeight: geometry.primaryHeight)
        let pad: Double = 4
        let frame = NSRect(x: cocoa.x - pad, y: cocoa.y - pad, width: cocoa.width + pad * 2, height: cocoa.height + pad * 2)
        window.setFrame(frame, display: true)
        box.needsDisplay = true
        window.orderFrontRegardless()
    }

    func hide() { window.orderOut(nil) }
}

final class HighlightView: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 6, yRadius: 6)
        path.lineWidth = 3
        path.stroke()
    }
}

enum ScreenshotStore {
    static func write(_ image: CGImage) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DesktopPilot/Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("capture-\(Int(Date().timeIntervalSince1970)).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
