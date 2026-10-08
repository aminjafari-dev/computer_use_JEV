import Carbon
import AppKit

struct HotKeyCombo: Equatable, Codable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let showPanel = HotKeyCombo(keyCode: 2, modifiers: UInt32(controlKey | shiftKey))
    static let emergencyStop = HotKeyCombo(keyCode: 53, modifiers: UInt32(controlKey | optionKey))

    var display: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(Self.name(for: keyCode))
        return parts.joined()
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        return value
    }

    private static func name(for keyCode: UInt32) -> String {
        let map: [UInt32: String] = [
            53: "Escape", 36: "Return", 48: "Tab", 49: "Space",
            123: "Left", 124: "Right", 125: "Down", 126: "Up",
            116: "Page Up", 121: "Page Down"
        ]
        if let name = map[keyCode] { return name }
        return Self.letter(for: keyCode)
    }

    private static func letter(for keyCode: UInt32) -> String {
        let letters: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
            34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M"
        ]
        return letters[keyCode] ?? "Key \(keyCode)"
    }
}

@MainActor
final class HotKeyManager {
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private let box = HotKeyBox()
    var onShow: @MainActor () -> Void {
        get { box.onShow }
        set { box.onShow = newValue }
    }
    var onStop: @MainActor () -> Void {
        get { box.onStop }
        set { box.onStop = newValue }
    }

    func register(show: HotKeyCombo, stop: HotKeyCombo) {
        unregister()
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            let box = Unmanaged<HotKeyBox>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in
                box.perform(id)
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(box).toOpaque(), &handler)

        hotKeyRefs = [register(show, id: 1), register(stop, id: 2)]
    }

    func unregister() {
        for ref in hotKeyRefs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        hotKeyRefs = []
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    private func register(_ combo: HotKeyCombo, id: UInt32) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4450_4C54), id: id)
        RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        return ref
    }
}

private final class HotKeyBox: @unchecked Sendable {
    var onShow: @MainActor () -> Void = {}
    var onStop: @MainActor () -> Void = {}

    @MainActor func perform(_ id: UInt32) {
        if id == 1 { onShow() }
        if id == 2 { onStop() }
    }
}
