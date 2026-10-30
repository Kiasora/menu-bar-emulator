import SwiftUI

// The app's building blocks. Screens use only these + Theme tokens, so a theme switch restyles everything,
// and every interactive piece here can be reached with a controller (pass a `padID`).

/// Page background: the theme color (or a custom theme's gradient) with a faint glow from the top.
struct ThemeBackground: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if let gradient = theme.gradient {
                LinearGradient(colors: gradient, startPoint: theme.diagonal ? .topLeading : .top,
                               endPoint: theme.diagonal ? .bottomTrailing : .bottom)
            } else {
                theme.background
                    .overlay(alignment: .top) {
                        RadialGradient(colors: [theme.accent.opacity(theme.isDark ? 0.10 : 0.06), .clear],
                                       center: .top, startRadius: 0, endRadius: 420)
                            .frame(height: 420)
                    }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

extension View {
    /// Soft filled card: no outline in dark themes, a whisper of one in light ones.
    func card(_ radius: CGFloat = 14, fill: Color? = nil) -> some View {
        modifier(CardModifier(radius: radius, fill: fill))
    }

    /// Screen-to-screen transition: blur + fade (plain fade with Reduce Motion).
    func screenTransition(reduceMotion: Bool) -> some View {
        transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
    }

    /// `padFocusable` only when an id is given (shared controls use it optionally).
    @ViewBuilder
    func padFocusable(_ id: String?, cornerRadius: CGFloat = 10, adjust: ((Int) -> Void)? = nil, action: @escaping () -> Void) -> some View {
        if let id { padFocusable(id, cornerRadius: cornerRadius, adjust: adjust, action: action) } else { self }
    }
}

private struct CardModifier: ViewModifier {
    let radius: CGFloat
    let fill: Color?
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(fill ?? theme.surface, in: shape)
            .overlay(shape.stroke(theme.isDark ? .clear : theme.hairline, lineWidth: 1))
    }
}

// MARK: - Buttons

/// Capsule button. Primary = accent, secondary = soft surface, quiet = text only.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, destructive }
    var kind: Kind = .primary
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, kind: kind, large: large)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let kind: Kind
        let large: Bool
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(theme.display(large ? 15 : 13, .semibold))
                .foregroundStyle(kind == .primary || kind == .destructive ? theme.onAccent : kind == .secondary ? theme.text : theme.accent)
                .padding(.horizontal, large ? 22 : kind == .quiet ? 6 : 14)
                .frame(height: large ? 42 : 30)
                .background {
                    switch kind {
                    case .primary: Capsule().fill(theme.accent.opacity(hovering ? 0.88 : 1))
                    case .secondary: Capsule().fill(hovering ? theme.boardAlt : theme.surface)
                    case .destructive: Capsule().fill(theme.bad.opacity(hovering ? 0.88 : 1))
                    case .quiet: EmptyView()
                    }
                }
                .contentShape(Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// Round icon button on pages. The label is also the tooltip and the VoiceOver name.
struct IconButton: View {
    let symbol: String
    let label: String
    var active = false
    var padID: String? = nil
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? theme.onAccent : theme.text)
                .frame(width: 32, height: 32)
                .background(Circle().fill(active ? theme.accent : hovering ? theme.boardAlt : theme.surface))
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
        .padFocusable(padID, cornerRadius: 16, action: action)
    }
}

/// A floating pill of icon buttons (instead of a row of identical circles).
struct ToolbarPill<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(3)
            .background(Capsule().fill(theme.surface.opacity(theme.isDark ? 0.9 : 1)))
            .overlay(Capsule().stroke(theme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.25 : 0.06), radius: 8, y: 2)
    }
}

/// One icon inside a ToolbarPill.
struct ToolbarIcon: View {
    let symbol: String
    let label: String
    var active = false
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? theme.accent : theme.text.opacity(hovering ? 1 : 0.82))
                .frame(width: 30, height: 28)
                .background(Capsule().fill(hovering ? theme.boardAlt : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// White icon on frosted dark glass, for controls that float over the game.
struct GlassButton: View {
    let symbol: String
    let label: String
    var active = false
    var size: CGFloat = 30
    var badge: String? = nil
    var text: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) { GlassIcon(symbol: symbol, active: active, size: size, hovering: hovering, badge: badge, text: text) }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { hovering = $0 }
            .help(label)
            .accessibilityLabel(label)
    }
}

/// The glass circle (or capsule, when it carries a key badge like "Tab").
struct GlassIcon: View {
    let symbol: String
    var active = false
    var size: CGFloat = 30
    var hovering = false
    /// A key name, shown in a little key-cap box (e.g. "Tab").
    var badge: String? = nil
    /// A plain label next to the icon (e.g. "Settings").
    var text: String? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
            if let text {
                Text(text).font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
            }
            if let badge {
                Text(badge)
                    .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                    .padding(.horizontal, 4)
                    .frame(height: size * 0.56)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white.opacity(active ? 0.25 : 0.14)))
            }
        }
        .foregroundStyle(active ? theme.onAccent : .white)
        .padding(.horizontal, badge == nil && text == nil ? 0 : 10)
        .frame(minWidth: size, minHeight: size, maxHeight: size)
        .background {
            if active {
                Capsule().fill(theme.accent)
            } else {
                Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                    .overlay(Capsule().fill(.white.opacity(hovering ? 0.16 : 0.04)))
            }
        }
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
        .contentShape(Capsule())
    }
}

/// Full-width filter bar: the segments stretch across the page, however many there are.
struct StretchFilter<Value: Hashable>: View {
    let options: [(label: String, symbol: String?, value: Value)]
    let selection: Value
    let choose: (Value) -> Void
    @Environment(\.theme) private var theme
    @Namespace private var namespace
    @State private var hovered: Value?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { withAnimation(.snappy(duration: 0.25)) { choose(option.value) } } label: {
                    HStack(spacing: 4) {
                        if let symbol = option.symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
                        Text(option.label).font(theme.display(12.5, .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(selected ? theme.background : theme.text.opacity(hovered == option.value ? 1 : 0.75))
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background {
                        if selected {
                            Capsule().fill(theme.text).matchedGeometryEffect(id: "filter", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { hovered = $0 ? option.value : nil }
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(theme.surface.opacity(theme.isDark ? 0.75 : 1)))
        .overlay(Capsule().stroke(theme.hairline, lineWidth: 1))
    }
}

/// A row of choices where the selection slides between options. With a `padID`, ← → change it from a controller.
struct SegmentedChoice<Value: Hashable>: View {
    let options: [(label: String, value: Value)]
    let selection: Value
    var padID: String? = nil
    let choose: (Value) -> Void
    @Environment(\.theme) private var theme
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { withAnimation(.snappy(duration: 0.22)) { choose(option.value) } } label: {
                    Text(option.label)
                        .font(theme.display(12, .semibold))
                        .foregroundStyle(selected ? theme.text : theme.subtext)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(theme.isDark ? theme.boardAlt.mix(with: .white, by: 0.06) : theme.surface)
                                    .shadow(color: .black.opacity(theme.isDark ? 0.3 : 0.08), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(theme.board, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padFocusable(padID, cornerRadius: 10, adjust: { step(by: $0) }) { step(by: 1) }
    }

    private func step(by delta: Int) {
        // Nothing chosen yet (say, custom keys): either direction picks the first option.
        let index = options.firstIndex(where: { $0.value == selection }) ?? -1
        let next = min(max(index + delta, 0), options.count - 1)
        withAnimation(.snappy(duration: 0.22)) { choose(options[next].value) }
    }
}

// MARK: - Settings pieces

/// Native-feeling grouped list: small caps title, one rounded container, hairlines between rows.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(theme.subtext)
                    .padding(.leading, 14)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                        subview
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                        if index < subviews.count - 1 {
                            Rectangle().fill(theme.hairline).frame(height: 1).padding(.leading, 14)
                        }
                    }
                }
            }
            .card(12)
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.subtext)
                    .padding(.horizontal, 14)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// "Label ……… control" row.
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var control: Control
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13)).foregroundStyle(theme.text)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(theme.subtext).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .frame(minHeight: 26)
        .contentShape(Rectangle())
    }
}

/// A switch row: label left, switch right; the whole row is one controller stop (A or ← → flips it).
struct ToggleRow: View {
    let title: String
    var subtitle: String? = nil
    let isOn: Binding<Bool>
    var padID: String? = nil

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) { ThemedToggle(isOn: isOn, label: title) }
            .padFocusable(padID, cornerRadius: 8, adjust: { _ in isOn.wrappedValue.toggle() }) { isOn.wrappedValue.toggle() }
    }
}

/// Small switch tinted with the theme accent.
struct ThemedToggle: View {
    let isOn: Binding<Bool>
    var label: String
    @Environment(\.theme) private var theme

    var body: some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .tint(theme.accent)
            .accessibilityLabel(label)
    }
}

/// A key cap, e.g. for "Return" or "↑".
struct KeyCap: View {
    let text: String
    var highlighted = false
    var large = false
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(.system(size: large ? 22 : 11.5, weight: .semibold, design: .rounded))
            .foregroundStyle(highlighted ? theme.onAccent : theme.text)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, large ? 14 : 8)
            .frame(minWidth: large ? 48 : 30)
            .frame(height: large ? 48 : 24)
            .background(RoundedRectangle(cornerRadius: large ? 11 : 6, style: .continuous).fill(highlighted ? theme.accent : theme.board))
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: large ? 11 : 6, style: .continuous)
                    .stroke(.black.opacity(theme.isDark ? 0.35 : 0.1), lineWidth: 1)
                    .mask(alignment: .bottom) { Rectangle().frame(height: large ? 5 : 3) }
            }
    }
}

/// A small "EARLY BUILD" badge.
struct EarlyBadge: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Text("EARLY BUILD")
            .font(.system(size: 9.5, weight: .heavy, design: .rounded))
            .tracking(0.8)
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(theme.accent.opacity(0.14)))
    }
}

// MARK: - Window

/// Lays its content out at no less than `design` and scales it down to fit when the window is smaller, so a small
/// window shows the same UI, just smaller, instead of cramming or cutting things off. Bigger windows get more room.
struct FitToWindow<Content: View>: View {
    let design: CGSize
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            let scale = Self.scale(for: geo.size, design: design)
            content
                .frame(width: geo.size.width / scale, height: geo.size.height / scale)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    /// 1 when the window is at least the design size; otherwise whatever makes the design fit.
    static func scale(for size: CGSize, design: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        return min(1, size.width / design.width, size.height / design.height)
    }
}

/// The sizes the screens are designed for. Smaller windows scale them down (see `FitToWindow`).
enum DesignSize {
    /// The tour (it doesn't scroll, so it needs its full height).
    static let page = CGSize(width: 450, height: 600)
    /// Library, settings and sheets: they scroll, so only a narrow (or very short) window scales them.
    static let scrollingPage = CGSize(width: 450, height: 420)
    /// Controls and panels over a game.
    static let gameOverlay = CGSize(width: 470, height: 360)
}

/// Drag here to move the window (used where a view would otherwise eat the click, like the game's control bar).
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

/// The toast pill: icon + short message, floating near the top.
struct ToastView: View {
    let toast: AppModel.Toast

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: toast.symbol).font(.system(size: 12, weight: .semibold))
            Text(toast.text).font(.system(size: 12.5, weight: .semibold, design: .rounded)).lineLimit(2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
        .background(Capsule().fill(.black.opacity(0.45)))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
    }
}
