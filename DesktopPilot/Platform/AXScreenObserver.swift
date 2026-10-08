import AppKit
import ApplicationServices
import CoreGraphics
import PilotCore

/// Reads the selected app's focused window through Accessibility.
/// The walk runs off the main actor. Our own windows are never included.
final class AXScreenObserver: ScreenObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var pinnedPID: pid_t?
    private var cachedOCR: (windowID: UInt32, bounds: Rect, at: Date, elements: [UIElementObservation])?
    private let detector = CoreMLDetectorAdapter.bundled()
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var saveScreenshots = false

    func setSaveScreenshots(_ enabled: Bool) {
        lock.lock()
        saveScreenshots = enabled
        lock.unlock()
    }

    private func shouldSaveScreenshots() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return saveScreenshots
    }

    func pin(pid: pid_t?) {
        lock.lock()
        pinnedPID = pid
        lock.unlock()
    }

    func currentTarget() -> TargetApplication? {
        lock.lock()
        let pinned = pinnedPID
        lock.unlock()
        return Self.resolve(pinned: pinned, ownPID: ownPID)
    }

    func permissionsGranted() async -> Bool {
        AXIsProcessTrusted()
    }

    func observe() async throws -> ScreenObservation {
        guard AXIsProcessTrusted() else { throw PilotError.permissionDenied }
        let geometry = await MainActor.run { DisplayGeometry.snapshot() }
        return try await takeSnapshot(geometry: geometry)
    }

    var coreMLStatus: String { detector.status }

    private func takeSnapshot(geometry: DisplayGeometry) async throws -> ScreenObservation {
        let pinned = readPinned()
        guard let target = Self.resolve(pinned: pinned, ownPID: ownPID) else {
            throw PilotError.executionFailed("No other application is available to observe.")
        }
        let application = AXUIElementCreateApplication(target.pid)
        guard let window = focusedWindow(of: application) else {
            throw PilotError.executionFailed("\(target.name) has no window to observe.")
        }
        let title = AXRead.string(window, kAXTitleAttribute) ?? target.name
        let frame = AXRead.frame(window) ?? Rect(x: 0, y: 0, width: 0, height: 0)
        var elements: [UIElementObservation] = []
        walk(window, parents: [], into: &elements, depth: 0)
        let windowID = Self.matchWindowID(pid: target.pid, title: title, axFrame: frame, geometry: geometry)

        let labeled = elements.filter { !$0.label.isEmpty }
        let sparse = elements.count < 3 || Double(labeled.count) / Double(max(elements.count, 1)) < 0.6
        if sparse, let windowID, CGPreflightScreenCaptureAccess() {
            if let extra = await extraElements(windowID: windowID, bounds: frame) {
                elements = ObservationMerger.merge([elements, extra])
            }
        }

        return ScreenObservation(
            appName: target.name,
            bundleID: target.bundleID,
            windowTitle: title,
            windowID: windowID,
            pid: target.pid,
            elements: elements
        )
    }

    private func extraElements(windowID: UInt32, bounds: Rect) async -> [UIElementObservation]? {
        if let cached = freshCache(windowID: windowID, bounds: bounds) { return cached }
        guard let capture = await WindowCaptureService.capture(windowID: windowID) else { return nil }
        let ocr = (try? VisionOCRService.recognize(capture: capture)) ?? []
        let detected = detector.detect(capture: capture)
        let merged = ocr + detected
        if shouldSaveScreenshots() {
            ScreenshotStore.write(capture.image)
        }
        storeCache(windowID: windowID, bounds: bounds, elements: merged)
        return merged
    }

    private func readPinned() -> pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return pinnedPID
    }

    private func freshCache(windowID: UInt32, bounds: Rect) -> [UIElementObservation]? {
        lock.lock()
        defer { lock.unlock() }
        guard let cachedOCR, cachedOCR.windowID == windowID, cachedOCR.bounds.iou(bounds) > 0.9, Date().timeIntervalSince(cachedOCR.at) < 1 else {
            return nil
        }
        return cachedOCR.elements
    }

    private func storeCache(windowID: UInt32, bounds: Rect, elements: [UIElementObservation]) {
        lock.lock()
        cachedOCR = (windowID, bounds, Date(), elements)
        lock.unlock()
    }

    private func focusedWindow(of application: AXUIElement) -> AXUIElement? {
        if let window = AXRead.element(application, kAXFocusedWindowAttribute) { return window }
        return AXRead.children(application, kAXWindowsAttribute).first
    }

    private func walk(_ element: AXUIElement, parents: [String], into output: inout [UIElementObservation], depth: Int) {
        guard depth < 8, output.count < 400 else { return }
        let role = AXRead.string(element, kAXRoleAttribute) ?? "AXUnknown"
        if role == "AXWindow" || role == "AXGroup" || role == "AXScrollArea" || role == "AXSplitGroup" || role == "AXToolbar" || role == "AXList" || role == "AXOutline" || role == "AXTable" {
            let label = AXRead.label(element)
            let nextParents = label.isEmpty ? parents : Array((parents + [label]).suffix(3))
            for child in AXRead.children(element, kAXChildrenAttribute) {
                walk(child, parents: nextParents, into: &output, depth: depth + 1)
            }
            if role == "AXScrollArea" || role == "AXList" || role == "AXOutline" || role == "AXTable" {
                output.append(makeObservation(element, role: role, parents: parents))
            }
            return
        }
        output.append(makeObservation(element, role: role, parents: parents))
        if role == "AXMenu" || role == "AXPopUpButton" || role == "AXSheet" {
            for child in AXRead.children(element, kAXChildrenAttribute) {
                walk(child, parents: parents, into: &output, depth: depth + 1)
            }
        }
    }

    private func makeObservation(_ element: AXUIElement, role: String, parents: [String]) -> UIElementObservation {
        let subrole = AXRead.string(element, kAXSubroleAttribute) ?? ""
        let secure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
        let label = AXRead.label(element)
        let value = secure ? nil : AXRead.string(element, kAXValueAttribute)
        return UIElementObservation(
            id: "ax-\(role)-\(label)-\(Int(AXRead.frame(element)?.x ?? 0))-\(Int(AXRead.frame(element)?.y ?? 0))",
            label: label,
            role: role,
            value: value,
            enabled: AXRead.bool(element, kAXEnabledAttribute) ?? true,
            bounds: AXRead.frame(element) ?? Rect(x: 0, y: 0, width: 0, height: 0),
            supportedActions: AXRead.actions(element),
            parentLabels: parents,
            sources: [.accessibility],
            isSecure: secure
        )
    }

    private static func resolve(pinned: pid_t?, ownPID: pid_t) -> TargetApplication? {
        let apps = NSWorkspace.shared.runningApplications
        if let pinned, pinned != ownPID, let app = apps.first(where: { $0.processIdentifier == pinned && !$0.isTerminated }) {
            return TargetApplication(name: app.localizedName ?? "App", bundleID: app.bundleIdentifier, pid: pinned)
        }
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != ownPID, front.activationPolicy == .regular {
            return TargetApplication(name: front.localizedName ?? "App", bundleID: front.bundleIdentifier, pid: front.processIdentifier)
        }
        let fallback = apps.first { $0.processIdentifier != ownPID && $0.activationPolicy == .regular && !$0.isTerminated }
        guard let fallback else { return nil }
        return TargetApplication(name: fallback.localizedName ?? "App", bundleID: fallback.bundleIdentifier, pid: fallback.processIdentifier)
    }

    private static func matchWindowID(pid: pid_t, title: String, axFrame: Rect, geometry: DisplayGeometry) -> UInt32? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let cocoa = CoordinateConverter.globalRectToCocoa(global: axFrame, primaryHeight: geometry.primaryHeight)
        var best: (id: UInt32, score: Double)?
        for window in info {
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner == pid else { continue }
            guard let number = window[kCGWindowNumber as String] as? UInt32 else { continue }
            let name = window[kCGWindowName as String] as? String ?? ""
            guard let dictionary = window[kCGWindowBounds as String] else { continue }
            let bounds = CGRect(dictionaryRepresentation: dictionary as! CFDictionary) ?? .zero
            let windowRect = Rect(x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: bounds.height)
            var score = windowRect.iou(cocoa)
            if !title.isEmpty, name == title { score += 0.5 }
            if best == nil || score > best!.score { best = (number, score) }
        }
        guard let best, best.score > 0.2 else { return nil }
        return best.id
    }
}

struct TargetApplication: Sendable, Equatable {
    var name: String
    var bundleID: String?
    var pid: pid_t
}

enum AXRead {
    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copy(element, attribute) else { return nil }
        if let text = value as? String { return text }
        return nil
    }

    static func label(_ element: AXUIElement) -> String {
        let title = string(element, kAXTitleAttribute) ?? ""
        if !title.isEmpty { return title }
        let description = string(element, kAXDescriptionAttribute) ?? ""
        if !description.isEmpty { return description }
        return string(element, kAXRoleDescriptionAttribute) ?? ""
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let value = copy(element, attribute) else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    static func frame(_ element: AXUIElement) -> Rect? {
        if let value = copy(element, "AXFrame"), let rect = cgRect(value) {
            return Rect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
        }
        guard let positionValue = copy(element, kAXPositionAttribute),
              let sizeValue = copy(element, kAXSizeAttribute),
              let position = cgPoint(positionValue),
              let size = cgSize(sizeValue) else { return nil }
        return Rect(x: position.x, y: position.y, width: size.width, height: size.height)
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    static func children(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard let value = copy(element, attribute) else { return [] }
        return value as? [AXUIElement] ?? []
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let names else { return [] }
        return names as? [String] ?? []
    }

    static func find(pid: pid_t, matching candidate: Candidate) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        let windows = children(application, kAXWindowsAttribute)
        for window in windows {
            if let found = search(window, candidate: candidate, depth: 0) { return found }
        }
        return nil
    }

    private static func search(_ element: AXUIElement, candidate: Candidate, depth: Int) -> AXUIElement? {
        guard depth < 10 else { return nil }
        let role = string(element, kAXRoleAttribute) ?? ""
        let label = label(element)
        let frame = frame(element) ?? Rect(x: 0, y: 0, width: 0, height: 0)
        if role == candidate.controlType, label.caseInsensitiveCompare(candidate.label) == .orderedSame {
            if frame.iou(candidate.bounds) >= 0.3 || frame.center.distance(to: candidate.center) < 40 {
                return element
            }
        }
        for child in children(element, kAXChildrenAttribute) {
            if let found = search(child, candidate: candidate, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func cgRect(_ value: CFTypeRef) -> CGRect? {
        var rect = CGRect.zero
        guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private static func cgPoint(_ value: CFTypeRef) -> CGPoint? {
        var point = CGPoint.zero
        guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func cgSize(_ value: CFTypeRef) -> CGSize? {
        var size = CGSize.zero
        guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }
}
