import AppKit
import Observation

/// Which keyboard key does what. Remappable in Settings › Controls, saved in UserDefaults.
@Observable
final class Controls {
    enum Action: String, CaseIterable, Identifiable {
        case up, down, left, right, a, b, x, y, l, r, start, select, turboA, turboB
        case fastForward, slowMotion, rewind, pause, quickSave, quickLoad, swapScreens, screenshot, mute, help

        var id: String { rawValue }

        var title: String {
            switch self {
            case .up: "Up"
            case .down: "Down"
            case .left: "Left"
            case .right: "Right"
            case .a, .b, .x, .y, .l, .r: rawValue.uppercased()
            case .start: "Start"
            case .select: "Select"
            case .fastForward: "Fast Forward"
            case .pause: "Pause"
            case .quickSave: "Quick Save"
            case .quickLoad: "Quick Load"
            case .swapScreens: "Swap DS Screens"
            case .rewind: "Rewind (hold)"
            case .turboA: "Turbo A (hold)"
            case .turboB: "Turbo B (hold)"
            case .slowMotion: "Slow Motion"
            case .mute: "Mute"
            case .screenshot: "Screenshot"
            case .help: "Show Controls"
            }
        }

        /// What does this on a controller (positional, Nintendo style), for the controls sheet.
        var padName: String? {
            switch self {
            case .up, .down, .left, .right: "D-pad / left stick"
            case .a: "Right face button"
            case .b: "Bottom face button"
            case .x: "Top face button"
            case .y: "Left face button"
            case .l: "Left bumper"
            case .r: "Right bumper"
            case .start: "Menu"
            case .select: "Options"
            case .fastForward: "Right trigger (hold)"
            case .rewind: "Left trigger (hold)"
            default: nil
            }
        }

        /// Game buttons (vs. emulator actions), for grouping in Settings and the controls sheet.
        var isGameButton: Bool { joypadID != nil || self == .turboA || self == .turboB }

        /// The libretro joypad button, nil for app actions.
        var joypadID: UInt32? {
            let id: Int32? = switch self {
            case .up: RETRO_DEVICE_ID_JOYPAD_UP
            case .down: RETRO_DEVICE_ID_JOYPAD_DOWN
            case .left: RETRO_DEVICE_ID_JOYPAD_LEFT
            case .right: RETRO_DEVICE_ID_JOYPAD_RIGHT
            case .a: RETRO_DEVICE_ID_JOYPAD_A
            case .b: RETRO_DEVICE_ID_JOYPAD_B
            case .x: RETRO_DEVICE_ID_JOYPAD_X
            case .y: RETRO_DEVICE_ID_JOYPAD_Y
            case .l: RETRO_DEVICE_ID_JOYPAD_L
            case .r: RETRO_DEVICE_ID_JOYPAD_R
            case .start: RETRO_DEVICE_ID_JOYPAD_START
            case .select: RETRO_DEVICE_ID_JOYPAD_SELECT
            default: nil
            }
            return id.map(UInt32.init)
        }
    }

    struct Key: Codable, Equatable {
        var code: UInt16
        var name: String
    }

    /// Ready-made layouts, from what people already play with: the melonDS/DeSmuME defaults, mGBA's, and the WASD
    /// setup PC players like (VBA-M ships WASD with K/L for B/A; the IJKL diamond matches the DS buttons).
    /// shortcut: key names assume a US keyboard; the codes are key positions, so other layouts still play right.
    enum Layout: String, CaseIterable, Identifiable {
        case classic, mgba, wasd

        var id: String { rawValue }

        var title: String {
            switch self {
            case .classic: "Classic"
            case .mgba: "mGBA"
            case .wasd: "WASD"
            }
        }

        var detail: String {
            switch self {
            case .classic: "Arrows move, X and Z are A and B, Q and W are the shoulders. Same as melonDS and DeSmuME."
            case .mgba: "Arrows move, X and Z are A and B, A and S are the shoulders. Same as mGBA."
            case .wasd: "WASD moves, L and K are A and B, I and J are X and Y, Q and E are the shoulders. Like a PC game."
            }
        }

        var bindings: [Action: Key] {
            var keys = Controls.defaultBindings
            switch self {
            case .classic: break
            case .mgba:
                keys.merge([.l: Key(code: 0, name: "A"), .r: Key(code: 1, name: "S"),
                            .y: Key(code: 12, name: "Q"), .x: Key(code: 13, name: "W")]) { $1 }
            case .wasd:
                keys.merge([.up: Key(code: 13, name: "W"), .left: Key(code: 0, name: "A"),
                            .down: Key(code: 1, name: "S"), .right: Key(code: 2, name: "D"),
                            .a: Key(code: 37, name: "L"), .b: Key(code: 40, name: "K"),
                            .x: Key(code: 34, name: "I"), .y: Key(code: 38, name: "J"),
                            .l: Key(code: 12, name: "Q"), .r: Key(code: 14, name: "E"),
                            .turboA: Key(code: 47, name: "."), .turboB: Key(code: 43, name: ","),
                            .swapScreens: Key(code: 5, name: "G"), .slowMotion: Key(code: 17, name: "T")]) { $1 }
            }
            return keys
        }
    }

    static let defaultBindings: [Action: Key] = [
        .up: Key(code: 126, name: "↑"), .down: Key(code: 125, name: "↓"),
        .left: Key(code: 123, name: "←"), .right: Key(code: 124, name: "→"),
        .a: Key(code: 7, name: "X"), .b: Key(code: 6, name: "Z"),
        .x: Key(code: 1, name: "S"), .y: Key(code: 0, name: "A"),
        .l: Key(code: 12, name: "Q"), .r: Key(code: 13, name: "W"),
        .start: Key(code: 36, name: "Return"), .select: Key(code: 51, name: "Delete"),
        .fastForward: Key(code: 48, name: "Tab"), .pause: Key(code: 49, name: "Space"),
        .quickSave: Key(code: 18, name: "1"), .quickLoad: Key(code: 19, name: "2"),
        .swapScreens: Key(code: 2, name: "D"), .rewind: Key(code: 15, name: "R"),
        .screenshot: Key(code: 35, name: "P"), .help: Key(code: 4, name: "H"),
        .turboA: Key(code: 8, name: "C"), .turboB: Key(code: 9, name: "V"),
        .slowMotion: Key(code: 14, name: "E"), .mute: Key(code: 46, name: "M"),
    ]
    static let escape: UInt16 = 53

    private(set) var bindings: [Action: Key]
    /// The action waiting for its new key (Settings shows "Press a key…").
    var capturing: Action?

    @ObservationIgnored private let store: UserDefaults
    private static let storageKey = "MenuBarEmulator.controls"

    init(store: UserDefaults = .standard) {
        self.store = store
        var bindings = Self.defaultBindings
        if let data = store.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([String: Key].self, from: data) {
            for (raw, key) in saved { if let action = Action(rawValue: raw) { bindings[action] = key } }
        }
        self.bindings = bindings
    }

    func action(for code: UInt16) -> Action? {
        Action.allCases.first { bindings[$0]?.code == code }
    }

    func key(for action: Action) -> Key? { bindings[action] }

    /// Gives `action` the key. An action that already had that key gets this action's old key, so nothing is lost.
    func assign(_ key: Key, to action: Action) {
        if let other = self.action(for: key.code), other != action { bindings[other] = bindings[action] }
        bindings[action] = key
        save()
    }

    /// Called with the next key press while `capturing` is set. Esc cancels (it's reserved for going back).
    func capture(_ event: NSEvent) {
        guard let action = capturing else { return }
        capturing = nil
        guard event.keyCode != Self.escape else { return }
        assign(Key(code: event.keyCode, name: Self.name(for: event)), to: action)
    }

    /// The layout these keys match, nil once a key's been changed by hand.
    var layout: Layout? { Layout.allCases.first { $0.bindings.mapValues(\.code) == bindings.mapValues(\.code) } }

    func apply(_ layout: Layout) {
        capturing = nil
        bindings = layout.bindings
        save()
    }

    func reset() { apply(.classic) }

    private func save() {
        let raw = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        store.set(try? JSONEncoder().encode(raw), forKey: Self.storageKey)
    }

    static func name(for event: NSEvent) -> String {
        let special: [UInt16: String] = [
            126: "↑", 125: "↓", 123: "←", 124: "→", 36: "Return", 76: "Enter", 51: "Delete", 117: "⌦",
            48: "Tab", 49: "Space", 56: "Shift", 60: "Right Shift", 59: "Control", 58: "Option",
        ]
        if let name = special[event.keyCode] { return name }
        let chars = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return chars.isEmpty ? "Key \(event.keyCode)" : chars.uppercased()
    }
}
