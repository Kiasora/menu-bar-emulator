import SwiftUI
import Observation

/// The built-in looks. Flat, quiet, Apple-style: system fonts, solid surfaces, one accent each.
enum ThemeKind: String, CaseIterable, Identifiable {
    case light, dark, midnight, sepia

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// The chosen theme's id: a built-in name or a custom theme's id.
    static let storageKey = "MenuBarEmulator.theme"

    var theme: Theme {
        switch self {
        case .light:
            Theme(id: rawValue, name: title, isDark: false, serif: false, background: 0xF5F5F7, surface: 0xFFFFFF, board: 0xECECEF,
                  boardAlt: 0xE3E3E8, text: 0x1D1D1F, subtext: 0x6E6E73, accent: 0x0071E3, good: 0x28A745, bad: 0xE5383B)
        case .dark:
            Theme(id: rawValue, name: title, isDark: true, serif: false, background: 0x1C1C1E, surface: 0x2C2C2E, board: 0x232325,
                  boardAlt: 0x2A2A2D, text: 0xF5F5F7, subtext: 0x98989D, accent: 0x0A84FF, good: 0x30D158, bad: 0xFF453A)
        case .midnight:
            Theme(id: rawValue, name: title, isDark: true, serif: false, background: 0x0B1020, surface: 0x141B2E, board: 0x0F1526,
                  boardAlt: 0x141C31, text: 0xE6E9F2, subtext: 0x8A93AD, accent: 0x5E9EFF, good: 0x3DD68C, bad: 0xFF6B6B)
        case .sepia:
            Theme(id: rawValue, name: title, isDark: false, serif: true, background: 0xF4ECDD, surface: 0xFBF6EC, board: 0xEDE3D0,
                  boardAlt: 0xE6DAC4, text: 0x3B2F20, subtext: 0x7A6A55, accent: 0xA0522D, good: 0x4F7A3A, bad: 0xB23A2E)
        }
    }
}

/// A theme someone made: a background (one color, or two for a gradient) and an accent. Everything else is derived
/// so text and controls always stay readable.
struct CustomTheme: Codable, Identifiable, Equatable {
    var id = "custom-" + UUID().uuidString
    var name: String
    var top: UInt32
    /// Second gradient color; nil = solid background.
    var bottom: UInt32?
    var accent: UInt32
    var diagonal = false
}

/// Every color the UI uses, as tokens. Screens never hard-code colors, so switching themes restyles everything.
struct Theme: Equatable {
    let id: String
    let name: String
    let isDark: Bool
    let serif: Bool
    let background, surface, board, boardAlt, text, subtext, accent, good, bad: Color
    /// Custom themes' background gradient (top to bottom, or diagonal).
    let gradient: [Color]?
    let diagonal: Bool
    let radius: CGFloat = 12

    init(id: String, name: String, isDark: Bool, serif: Bool, background: UInt32, surface: UInt32, board: UInt32, boardAlt: UInt32,
         text: UInt32, subtext: UInt32, accent: UInt32, good: UInt32, bad: UInt32, gradient: [UInt32]? = nil, diagonal: Bool = false) {
        self.id = id
        self.name = name
        self.isDark = isDark
        self.serif = serif
        self.background = Color(hex: background)
        self.surface = Color(hex: surface)
        self.board = Color(hex: board)
        self.boardAlt = Color(hex: boardAlt)
        self.text = Color(hex: text)
        self.subtext = Color(hex: subtext)
        self.accent = Color(hex: accent)
        self.good = Color(hex: good)
        self.bad = Color(hex: bad)
        self.gradient = gradient?.map { Color(hex: $0) }
        self.diagonal = diagonal
    }

    init(custom: CustomTheme) {
        let base = custom.bottom.map { Self.mix(custom.top, $0, 0.5) } ?? custom.top
        let dark = Self.luminance(base) < 0.5
        self.init(id: custom.id, name: custom.name, isDark: dark, serif: false,
                  background: custom.top,
                  surface: dark ? Self.mix(base, 0xFFFFFF, 0.10) : Self.mix(base, 0xFFFFFF, 0.72),
                  board: dark ? Self.mix(base, 0xFFFFFF, 0.05) : Self.mix(base, 0x000000, 0.05),
                  boardAlt: dark ? Self.mix(base, 0xFFFFFF, 0.14) : Self.mix(base, 0x000000, 0.10),
                  text: dark ? 0xF5F5F7 : 0x1D1D1F, subtext: dark ? 0xA4A4AC : 0x66666C,
                  accent: custom.accent, good: dark ? 0x30D158 : 0x28A745, bad: dark ? 0xFF453A : 0xE5383B,
                  gradient: custom.bottom.map { [custom.top, $0] }, diagonal: custom.diagonal)
    }

    var scheme: ColorScheme { isDark ? .dark : .light }
    /// Text/icons drawn on top of `accent`.
    var onAccent: Color { .white }
    var hairline: Color { isDark ? .white.opacity(0.08) : .black.opacity(0.08) }

    func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: serif ? .serif : .default)
    }

    /// Headings: SF Pro Rounded, a little friendlier for a game app (serif in Sepia).
    func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: serif ? .serif : .rounded)
    }

    func numberFont(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: serif ? .serif : .default).monospacedDigit()
    }

    static func luminance(_ hex: UInt32) -> Double {
        let r = Double((hex >> 16) & 0xFF) / 255, g = Double((hex >> 8) & 0xFF) / 255, b = Double(hex & 0xFF) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let x = Double((a >> shift) & 0xFF), y = Double((b >> shift) & 0xFF)
            return UInt32((x + (y - x) * t).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }
}

/// Built-in themes plus the ones people make, saved in UserDefaults.
@Observable
final class ThemeStore {
    private(set) var custom: [CustomTheme]
    @ObservationIgnored private let store: UserDefaults
    private static let key = "MenuBarEmulator.customThemes"

    init(store: UserDefaults = .standard) {
        self.store = store
        custom = (store.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([CustomTheme].self, from: $0) }) ?? []
    }

    func theme(id: String) -> Theme {
        if let kind = ThemeKind(rawValue: id) { return kind.theme }
        if let made = custom.first(where: { $0.id == id }) { return Theme(custom: made) }
        return ThemeKind.dark.theme
    }

    /// Every theme for the picker: built-ins first, then custom ones in the order they were made.
    var all: [Theme] { ThemeKind.allCases.map(\.theme) + custom.map(Theme.init(custom:)) }

    func save(_ theme: CustomTheme) {
        if let index = custom.firstIndex(where: { $0.id == theme.id }) { custom[index] = theme } else { custom.append(theme) }
        persist()
    }

    func delete(_ id: String) {
        custom.removeAll { $0.id == id }
        persist()
    }

    func customTheme(id: String) -> CustomTheme? { custom.first { $0.id == id } }

    private func persist() {
        store.set(try? JSONEncoder().encode(custom), forKey: Self.key)
    }
}

// MARK: - Environment

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = ThemeKind.dark.theme
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }

    /// The color as 0xRRGGBB (sRGB), for saving custom themes.
    var hex: UInt32 {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return 0 }
        func byte(_ v: CGFloat) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent)
    }
}
