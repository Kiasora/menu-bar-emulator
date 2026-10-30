import Foundation

/// Everything a factory reset touches. Every setting the app saves lives under the "MenuBarEmulator." prefix
/// (theme, controls, shortcuts, custom themes, display, speed, sound, window sizes, open games, the tour…).
enum FactoryReset {
    static let prefix = "MenuBarEmulator."

    /// Removes every app setting from `store`; nothing else in it is touched.
    static func clearSettings(in store: UserDefaults) {
        for key in store.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            store.removeObject(forKey: key)
        }
    }
}
