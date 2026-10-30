import Foundation
import Observation

/// How the game picture is shown: pixel filter for every system, plus DS screen layout, gap, swap and shell.
/// Saved in UserDefaults.
@Observable
final class Display {
    enum Layout: String, CaseIterable, Identifiable {
        case stacked, sideBySide, focusTop, focusTopLeft, focusBottom, bigTopBelow, topHeavy, bigBottomAbove
        case hybrid, miniTouch, single, separate

        var id: String { rawValue }

        /// Short name for the layout picker.
        var title: String {
            switch self {
            case .stacked: "Stacked"
            case .sideBySide: "Side by Side"
            case .focusTop: "Big Top"
            case .focusTopLeft: "Touch Left"
            case .focusBottom: "Big Bottom"
            case .bigTopBelow: "Top Large"
            case .topHeavy: "Top Heavy"
            case .bigBottomAbove: "Touch Large"
            case .hybrid: "Hybrid"
            case .miniTouch: "Mini Touch"
            case .single: "One Screen"
            case .separate: "Separate"
            }
        }

        /// What it looks like, for the tooltip.
        var detail: String {
            switch self {
            case .stacked: "Top screen over the touch screen, same size, like a real DS"
            case .sideBySide: "Both screens next to each other"
            case .focusTop: "Big top screen, small touch screen on the right"
            case .focusTopLeft: "Big top screen, small touch screen on the left"
            case .focusBottom: "Big touch screen, small top screen on the right"
            case .bigTopBelow: "Big top screen, half-size touch screen below"
            case .topHeavy: "Top screen a bit bigger than the touch screen below"
            case .bigBottomAbove: "Big touch screen, half-size top screen above"
            case .hybrid: "Big top screen, plus both screens small on the right"
            case .miniTouch: "Top screen with a small touch screen in the corner"
            case .single: "One screen at a time. Press D to flip between them"
            case .separate: "The touch screen in its own window you can put anywhere"
            }
        }
    }

    enum Shell: String, CaseIterable, Identifiable {
        case none, white, onyx, cobalt, crimson, pink, mint
        var id: String { rawValue }
        var title: String { self == .none ? "None" : rawValue.capitalized }
        /// Top and bottom of the shell gradient.
        var colors: (UInt32, UInt32)? {
            switch self {
            case .none: nil
            case .white: (0xF6F7FA, 0xD8DBE3)
            case .onyx: (0x3A3B41, 0x1C1C20)
            case .cobalt: (0x4C7BE0, 0x2B4FA8)
            case .crimson: (0xE0464B, 0xA52A30)
            case .pink: (0xF7B6CF, 0xE48AAE)
            case .mint: (0xA6E3C9, 0x6FC3A2)
            }
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case sharp, smooth, lcd
        var id: String { rawValue }
        var title: String { self == .lcd ? "LCD" : rawValue.capitalized }
    }

    var layout: Layout { didSet { save() } }
    var shell: Shell { didSet { save() } }
    var filter: Filter { didSet { save() } }
    /// Space between the DS screens, in DS pixels.
    var gap: Double { didSet { save() } }
    /// Swaps which DS screen is first / big (and which one One Screen shows).
    var swap: Bool { didSet { save() } }

    static let screen = CGSize(width: 256, height: 192)
    /// Shell border around the screens, in DS pixels.
    static let shellPadding: CGFloat = 14

    @ObservationIgnored private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        layout = store.string(forKey: "MenuBarEmulator.ds.layout").flatMap(Layout.init) ?? .stacked
        shell = store.string(forKey: "MenuBarEmulator.ds.shell").flatMap(Shell.init) ?? .none
        filter = store.string(forKey: "MenuBarEmulator.filter").flatMap(Filter.init) ?? .sharp
        gap = store.object(forKey: "MenuBarEmulator.ds.gap") as? Double ?? 0
        swap = store.bool(forKey: "MenuBarEmulator.ds.swap")
    }

    private func save() {
        store.set(layout.rawValue, forKey: "MenuBarEmulator.ds.layout")
        store.set(shell.rawValue, forKey: "MenuBarEmulator.ds.shell")
        store.set(filter.rawValue, forKey: "MenuBarEmulator.filter")
        store.set(gap, forKey: "MenuBarEmulator.ds.gap")
        store.set(swap, forKey: "MenuBarEmulator.ds.swap")
    }

    /// Where the DS screens go in the main window, in DS pixels (each screen is 256×192), shell border included.
    /// A missing screen isn't shown there (One Screen, or the other window in Separate). Hybrid shows one screen twice.
    struct DSLayout: Equatable {
        var size: CGSize
        var top: CGRect?
        var bottom: CGRect?
        /// Hybrid's second copy of a screen, and whether that copy is the top screen.
        var extra: CGRect?
        var extraIsTop = true
    }

    func dsLayout() -> DSLayout {
        Self.dsLayout(layout, gap: CGFloat(gap), swap: swap, shell: shell != .none)
    }

    static func dsLayout(_ layout: Layout, gap g: CGFloat, swap: Bool, shell: Bool) -> DSLayout {
        let w = screen.width, h = screen.height
        let near = g + 8 // side layouts: the small screen never touches the big one
        // `main` is the top screen and `other` the touch screen, unless swapped.
        var main: CGRect?, other: CGRect?, extra: CGRect?
        var size: CGSize
        switch layout {
        case .stacked:
            main = CGRect(x: 0, y: 0, width: w, height: h)
            other = CGRect(x: 0, y: h + g, width: w, height: h)
            size = CGSize(width: w, height: h * 2 + g)
        case .sideBySide:
            main = CGRect(x: 0, y: 0, width: w, height: h)
            other = CGRect(x: w + g, y: 0, width: w, height: h)
            size = CGSize(width: w * 2 + g, height: h)
        case .focusTop, .focusBottom:
            main = CGRect(x: 0, y: 0, width: w, height: h)
            other = CGRect(x: w + near, y: h / 4, width: w / 2, height: h / 2)
            size = CGSize(width: w * 1.5 + near, height: h)
        case .focusTopLeft:
            other = CGRect(x: 0, y: h / 4, width: w / 2, height: h / 2)
            main = CGRect(x: w / 2 + near, y: 0, width: w, height: h)
            size = CGSize(width: w * 1.5 + near, height: h)
        case .bigTopBelow:
            main = CGRect(x: 0, y: 0, width: w, height: h)
            other = CGRect(x: w / 4, y: h + g, width: w / 2, height: h / 2)
            size = CGSize(width: w, height: h * 1.5 + g)
        case .topHeavy:
            main = CGRect(x: 0, y: 0, width: w, height: h)
            other = CGRect(x: w / 6, y: h + g, width: w * 2 / 3, height: h * 2 / 3)
            size = CGSize(width: w, height: h * 5 / 3 + g)
        case .bigBottomAbove:
            other = CGRect(x: w / 4, y: 0, width: w / 2, height: h / 2)
            main = CGRect(x: 0, y: h / 2 + g, width: w, height: h)
            size = CGSize(width: w, height: h * 1.5 + g)
        case .hybrid:
            // Big screen on the left; on the right, both screens small (so the big one appears twice).
            main = CGRect(x: 0, y: 0, width: w, height: h)
            extra = CGRect(x: w + near, y: 0, width: w / 2, height: h / 2)
            other = CGRect(x: w + near, y: h / 2, width: w / 2, height: h / 2)
            size = CGSize(width: w * 1.5 + near, height: h)
        case .miniTouch:
            let m: CGFloat = 6
            main = CGRect(x: 0, y: 0, width: w, height: h)
            other = CGRect(x: w * 2 / 3 - m, y: h * 2 / 3 - m, width: w / 3, height: h / 3)
            size = CGSize(width: w, height: h)
        case .single, .separate:
            main = CGRect(x: 0, y: 0, width: w, height: h)
            size = CGSize(width: w, height: h)
        }
        // Layouts named for the touch screen put it in the big spot.
        let touchFirst = [.focusBottom, .bigBottomAbove].contains(layout) != swap
        let pad = shell ? shellPadding : 0
        func padded(_ rect: CGRect?) -> CGRect? { rect?.offsetBy(dx: pad, dy: pad) }
        if layout == .hybrid && touchFirst {
            // Big touch screen; the small column still reads top screen over touch screen.
            return DSLayout(size: CGSize(width: size.width + pad * 2, height: size.height + pad * 2),
                            top: padded(extra), bottom: padded(main), extra: padded(other), extraIsTop: false)
        }
        return DSLayout(size: CGSize(width: size.width + pad * 2, height: size.height + pad * 2),
                        top: padded(touchFirst ? other : main),
                        bottom: padded(touchFirst ? main : other),
                        extra: padded(extra),
                        extraIsTop: !touchFirst)
    }
}
