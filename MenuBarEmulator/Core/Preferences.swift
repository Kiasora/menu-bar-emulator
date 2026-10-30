import AppKit
import Observation

/// How the app behaves (as opposed to how a game runs): window behavior and the global shortcuts.
/// Picked during onboarding, changeable in Settings.
@Observable
final class Preferences {
    /// Pause (and save) the game when its window is hidden or covered. Off = it keeps running in the background.
    var pauseWhenHidden: Bool { didSet { store.set(pauseWhenHidden, forKey: Keys.pauseWhenHidden) } }
    /// The menu bar window closes when you click somewhere else, like a popover. Off = it stays until you close it.
    var closeOnClickOutside: Bool { didSet { store.set(closeOnClickOutside, forKey: Keys.closeOnClickOutside) } }
    /// Global shortcut that pops the window out as a floating window.
    var popOutShortcut: Shortcut? { didSet { save(popOutShortcut, Keys.popOut); onShortcutsChanged?() } }
    /// Global shortcut that opens the window under the menu bar icon.
    var menuBarShortcut: Shortcut? { didSet { save(menuBarShortcut, Keys.menuBar); onShortcutsChanged?() } }
    /// Lo-fi music everywhere (the ♪ switch at the top of the library).
    var lofiOn: Bool { didSet { store.set(lofiOn, forKey: Keys.lofiOn) } }
    /// Lo-fi while fast-forwarding, even with the music off (the ⏩ switch).
    var lofiSpedUp: Bool { didSet { store.set(lofiSpedUp, forKey: Keys.lofiSpedUp) } }
    /// Lo-fi keeps playing after the window closes, like a music app.
    var lofiInBackground: Bool { didSet { store.set(lofiInBackground, forKey: Keys.lofiInBackground) } }
    /// No sound at all while a game is up: neither the game's nor the lo-fi.
    var silentGames: Bool { didSet { store.set(silentGames, forKey: Keys.silentGames) } }

    @ObservationIgnored var onShortcutsChanged: (() -> Void)?
    @ObservationIgnored private let store: UserDefaults

    private enum Keys {
        static let pauseWhenHidden = "MenuBarEmulator.pauseWhenHidden"
        static let closeOnClickOutside = "MenuBarEmulator.closeOnClickOutside"
        static let popOut = "MenuBarEmulator.shortcut.popOut"
        static let menuBar = "MenuBarEmulator.shortcut.menuBar"
        static let lofiOn = "MenuBarEmulator.lofiOn"
        static let lofiSpedUp = "MenuBarEmulator.lofiSpedUp"
        static let lofiInBackground = "MenuBarEmulator.lofiInBackground"
        static let silentGames = "MenuBarEmulator.silentGames"
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        pauseWhenHidden = store.object(forKey: Keys.pauseWhenHidden) as? Bool ?? true
        closeOnClickOutside = store.object(forKey: Keys.closeOnClickOutside) as? Bool ?? true
        popOutShortcut = Self.load(Keys.popOut, from: store, default: Shortcut.optionP)
        menuBarShortcut = Self.load(Keys.menuBar, from: store, default: nil)
        lofiOn = store.object(forKey: Keys.lofiOn) as? Bool ?? false
        lofiSpedUp = store.object(forKey: Keys.lofiSpedUp) as? Bool ?? true
        lofiInBackground = store.object(forKey: Keys.lofiInBackground) as? Bool ?? false
        silentGames = store.object(forKey: Keys.silentGames) as? Bool ?? false
    }

    private func save(_ shortcut: Shortcut?, _ key: String) {
        // An explicit "none" is stored, so clearing a shortcut sticks instead of bringing back the default.
        store.set(try? JSONEncoder().encode(shortcut ?? Shortcut.none), forKey: key)
    }

    private static func load(_ key: String, from store: UserDefaults, default fallback: Shortcut?) -> Shortcut? {
        guard let data = store.data(forKey: key), let saved = try? JSONDecoder().decode(Shortcut.self, from: data) else { return fallback }
        return saved == .none ? nil : saved
    }
}

/// A key + modifiers combination for a global shortcut, e.g. ⌥P.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    /// NSEvent.ModifierFlags raw value (command, option, control, shift only).
    var modifiers: UInt
    var key: String

    static let optionP = Shortcut(keyCode: 35, modifiers: NSEvent.ModifierFlags.option.rawValue, key: "P")
    static let none = Shortcut(keyCode: 0xFFFF, modifiers: 0, key: "")

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// "⌃⌥⇧⌘P", in Apple's order.
    var symbols: [String] {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        return parts + [key]
    }

    var display: String { symbols.joined() }

    /// A recorded key press, if it can work as a global shortcut (needs ⌘, ⌥ or ⌃, so plain typing never triggers it).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        self.init(keyCode: event.keyCode, modifiers: flags.rawValue, key: Controls.name(for: event))
    }

    init(keyCode: UInt16, modifiers: UInt, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }
}
