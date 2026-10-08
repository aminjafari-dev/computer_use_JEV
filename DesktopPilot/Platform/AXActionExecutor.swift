import AppKit
import ApplicationServices
import CoreGraphics
import PilotCore

final class AXActionExecutor: ActionExecuting, @unchecked Sendable {
    func revalidate(_ candidate: Candidate, original: ScreenObservation, fresh: ScreenObservation) -> Revalidation {
        TargetMatching.revalidate(candidate: candidate, original: original, fresh: fresh)
    }

    func execute(_ candidate: Candidate, userText: String?, observation: ScreenObservation) async throws {
        switch candidate.operation {
        case .pressKey:
            guard let key = candidate.navigationKey else { throw PilotError.executionFailed("That key is not allowed.") }
            postKey(key)
            return
        case .insertText:
            guard let userText, !userText.isEmpty else { throw PilotError.missingUserText }
            guard !SafetyPolicy.looksLikeCredential(candidate) else { throw PilotError.refusedSecureField }
            guard let element = AXRead.find(pid: observation.pid, matching: candidate) else { throw PilotError.staleTarget }
            if AXRead.string(element, kAXSubroleAttribute) == "AXSecureTextField" { throw PilotError.refusedSecureField }
            let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, userText as CFString)
            if result != .success {
                try focus(element)
                postText(userText)
            }
            return
        case .scrollUp, .scrollDown:
            postScroll(at: candidate.center, up: candidate.operation == .scrollUp)
            return
        case .click, .doubleClick, .rightClick:
            if let element = AXRead.find(pid: observation.pid, matching: candidate) {
                let actions = AXRead.actions(element)
                if candidate.operation == .click, actions.contains(kAXPressAction as String) {
                    if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success { return }
                }
                if candidate.operation == .rightClick, actions.contains(kAXShowMenuAction as String) {
                    if AXUIElementPerformAction(element, kAXShowMenuAction as CFString) == .success { return }
                }
            }
            let button: CGMouseButton = candidate.operation == .rightClick ? .right : .left
            let count = candidate.operation == .doubleClick ? 2 : 1
            postClick(at: candidate.center, button: button, count: count)
        }
    }

    private func focus(_ element: AXUIElement) throws {
        if AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) != .success {
            throw PilotError.executionFailed("The text field could not be focused.")
        }
    }

    private func postClick(at point: Point, button: CGMouseButton, count: Int) {
        let location = CGPoint(x: point.x, y: point.y)
        let downType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        for index in 1...count {
            guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: location, mouseButton: button),
                  let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: location, mouseButton: button) else { return }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private func postScroll(at point: Point, up: Bool) {
        let location = CGPoint(x: point.x, y: point.y)
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: Int32(up ? 3 : -3),
            wheel2: 0,
            wheel3: 0
        ) else { return }
        event.location = location
        event.post(tap: .cghidEventTap)
    }

    private func postKey(_ key: NavigationKey) {
        let code = keyCode(key)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func postText(_ text: String) {
        let units = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return }
        units.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func keyCode(_ key: NavigationKey) -> CGKeyCode {
        switch key {
        case .escape: 53
        case .returnKey: 36
        case .tab: 48
        case .up: 126
        case .down: 125
        case .left: 123
        case .right: 124
        case .pageUp: 116
        case .pageDown: 121
        }
    }
}
