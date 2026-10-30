import SwiftUI
import Observation

/// Controller (and arrow-key) navigation for everything that isn't the game itself: onboarding, settings, panels, sheets.
/// Controls mark themselves `.padFocusable(id) { action }`; the D-pad moves to the nearest one in that direction,
/// A activates it, and ← → adjust controls that have a value (speeds, switches, sliders).
/// The focus ring only shows once a controller or the arrow keys are used, so mouse users never see it.
@Observable
final class PadFocus {
    enum Direction { case up, down, left, right }

    var current: String?
    var visible = false
    /// Which layer can be navigated: "screen", "panel" or "sheet" (the topmost one that's open).
    @ObservationIgnored var scope = "screen"
    @ObservationIgnored var items: [PadItem] = []

    private var reachable: [PadItem] { items.filter { $0.scope == scope } }

    func move(_ direction: Direction) {
        let items = reachable
        guard visible, let from = items.first(where: { $0.id == current }) else {
            visible = true
            current = Self.first(items)?.id
            return
        }
        if let next = Self.nearest(from: from.frame, direction, in: items.filter { $0.id != from.id }) { current = next.id }
    }

    /// ← → change the focused control's value if it has one, otherwise move.
    func horizontal(_ delta: Int) {
        if visible, let item = reachable.first(where: { $0.id == current }), let adjust = item.adjust {
            adjust(delta)
        } else {
            move(delta < 0 ? .left : .right)
        }
    }

    /// A / Return on the focused control. False when nothing is focused (so the caller can do its default).
    @discardableResult
    func activate() -> Bool {
        guard visible, let item = reachable.first(where: { $0.id == current }) else { return false }
        item.action()
        return true
    }

    /// Keeps the focus valid when what's on screen changes (a panel opened, a page changed).
    func itemsChanged(_ items: [PadItem]) {
        self.items = items
        if visible, !reachable.contains(where: { $0.id == current }) { current = Self.first(reachable)?.id }
    }

    func hide() { visible = false }

    static func first(_ items: [PadItem]) -> PadItem? {
        items.min { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
    }

    /// The closest control in a direction, preferring ones straight ahead over ones off to the side.
    static func nearest(from: CGRect, _ direction: Direction, in items: [PadItem]) -> PadItem? {
        func score(_ f: CGRect) -> CGFloat? {
            let dx = f.midX - from.midX, dy = f.midY - from.midY
            switch direction {
            case .up: return f.midY < from.midY - from.height / 4 ? -dy + abs(dx) * 2 : nil
            case .down: return f.midY > from.midY + from.height / 4 ? dy + abs(dx) * 2 : nil
            case .left: return f.midX < from.midX - from.width / 4 ? -dx + abs(dy) * 2 : nil
            case .right: return f.midX > from.midX + from.width / 4 ? dx + abs(dy) * 2 : nil
            }
        }
        return items.compactMap { item in score(item.frame).map { (item, $0) } }.min { $0.1 < $1.1 }?.0
    }
}

/// One navigable control, reported up through a preference with its frame in window coordinates.
struct PadItem: Equatable {
    let id: String
    let scope: String
    let frame: CGRect
    let action: () -> Void
    let adjust: ((Int) -> Void)?

    static func == (a: PadItem, b: PadItem) -> Bool { a.id == b.id && a.scope == b.scope && a.frame == b.frame }
}

struct PadItemsKey: PreferenceKey {
    static let defaultValue: [PadItem] = []
    static func reduce(value: inout [PadItem], nextValue: () -> [PadItem]) { value += nextValue() }
}

private struct PadScopeKey: EnvironmentKey {
    static let defaultValue = "screen"
}

extension EnvironmentValues {
    /// Set by panels and sheets so their controls are navigated separately from the screen behind them.
    var padScope: String {
        get { self[PadScopeKey.self] }
        set { self[PadScopeKey.self] = newValue }
    }
}

private struct PadFocusable: ViewModifier {
    let id: String
    let adjust: ((Int) -> Void)?
    let cornerRadius: CGFloat
    let action: () -> Void
    @Environment(PadFocus.self) private var pad
    @Environment(\.padScope) private var scope
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let focused = pad.visible && pad.current == id && pad.scope == scope
        content
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(theme.accent, lineWidth: 2.5)
                        .padding(-4)
                        .shadow(color: theme.accent.opacity(0.5), radius: 6)
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(focused ? 1.015 : 1)
            .animation(.snappy(duration: 0.15), value: focused)
            .id(id)
            .background {
                GeometryReader { geo in
                    Color.clear.preference(key: PadItemsKey.self,
                                           value: [PadItem(id: id, scope: scope, frame: geo.frame(in: .global), action: action, adjust: adjust)])
                }
            }
    }
}

extension View {
    /// Makes this control reachable with a controller / arrow keys. `adjust` gets -1 / +1 for ← / →.
    func padFocusable(_ id: String, cornerRadius: CGFloat = 10, adjust: ((Int) -> Void)? = nil, action: @escaping () -> Void) -> some View {
        modifier(PadFocusable(id: id, adjust: adjust, cornerRadius: cornerRadius, action: action))
    }
}

/// A scroll view that keeps the controller-focused control in view.
struct PadScrollView<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(PadFocus.self) private var pad

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { content }
                .scrollIndicators(.never)
                .onChange(of: pad.current) {
                    guard pad.visible, let id = pad.current else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
        }
    }
}
