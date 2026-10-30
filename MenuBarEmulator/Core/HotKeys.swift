import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts via Carbon (works in every app and needs no Accessibility permission).
/// Each shortcut has a slot; setting a slot replaces whatever was registered there.
@MainActor
enum HotKeys {
    enum Slot: UInt32 { case popOut = 1, menuBar = 2 }

    private static var actions: [UInt32: () -> Void] = [:]
    private static var refs: [UInt32: EventHotKeyRef] = [:]
    private static var shortcuts: [UInt32: Shortcut] = [:]
    private static var handlerInstalled = false
    /// While a shortcut is being recorded, the existing ones must not fire.
    private static var suspended = false

    static func set(_ shortcut: Shortcut?, for slot: Slot, action: @escaping () -> Void) {
        installHandler()
        actions[slot.rawValue] = action
        shortcuts[slot.rawValue] = shortcut
        register(slot.rawValue)
    }

    static func suspend(_ on: Bool) {
        guard suspended != on else { return }
        suspended = on
        for id in shortcuts.keys { register(id) }
    }

    private static func register(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        guard !suspended, let shortcut = shortcuts[id] else { return }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), carbonModifiers(shortcut.flags),
                                         EventHotKeyID(signature: OSType(0x4D42454D), id: id), // "MBEM"
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs[id] = ref } else { NSLog("Couldn't register \(shortcut.display) (taken by another app?)") }
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            Task { @MainActor in HotKeys.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}
