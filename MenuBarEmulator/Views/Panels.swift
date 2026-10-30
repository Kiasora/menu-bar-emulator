import SwiftUI

/// The card that slides up over the game. Scrolls only when it has to; controller focus stays inside it.
struct PanelCard: View {
    let panel: AppModel.Panel
    @Bindable var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(theme.display(17))
                Spacer()
                Button { model.back() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.subtext)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(theme.board))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Close (Esc, or B on a controller)")
                .accessibilityLabel("Close")
            }
            FittingScroll {
                switch panel {
                case .menu: GameMenuPanel(model: model)
                case .states: StatesPanel(model: model)
                case .display: DisplayPanel(display: model.display, model: model)
                case .mods: ModsPanel(model: model)
                case .games: GamesPanel(model: model)
                case .help: HelpPanel(controls: model.controls, gamepad: model.gamepad)
                case .settings: SettingsContent(model: model)
                }
            }
        }
        .foregroundStyle(theme.text)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(theme.background))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .environment(\.padScope, "panel")
    }

    private var title: String {
        switch panel {
        case .menu: "Game Menu"
        case .states: "Save States"
        case .display: "Display"
        case .mods: "Mods & Cheats"
        case .games: "Open Games"
        case .help: "Controls"
        case .settings: model.settingsPage == .controls ? "Keyboard" : "Settings"
        }
    }
}

/// A scroll view that's only as tall as its content (up to whatever space there is) and follows controller focus.
struct FittingScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var height: CGFloat = 200
    @Environment(PadFocus.self) private var pad

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                    .padding(4) // room for the focus ring
            }
            .frame(maxHeight: height + 8)
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: pad.current) {
                guard pad.visible, let id = pad.current else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

private struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(theme.subtext)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Note: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(theme.subtext)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Game menu (made for controllers)

/// Big, simple tiles for everything you'd want mid-game. Opens with Home, a stick click or Start + Select.
private struct GameMenuPanel: View {
    let model: AppModel
    @Environment(\.theme) private var theme

    private struct Item: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let action: () -> Void
    }

    var body: some View {
        let emulator = model.emulator
        var items = [
            Item(id: "resume", title: "Resume", symbol: "play.fill") { model.panel = nil },
            Item(id: "quicksave", title: "Quick Save", symbol: "square.and.arrow.down.fill") { emulator.saveState("quick") },
            Item(id: "quickload", title: "Quick Load", symbol: "arrow.counterclockwise") {
                if emulator.loadState("quick") { model.panel = nil } else { model.show("No Quick Save yet", "tray") }
            },
            Item(id: "states", title: "Save States", symbol: "bookmark.fill") { model.openFromMenu(.states) },
            Item(id: "display", title: "Display", symbol: "slider.horizontal.3") { model.openFromMenu(.display) },
            Item(id: "mods", title: "Mods & Cheats", symbol: "wand.and.stars") { model.openFromMenu(.mods) },
            Item(id: "settings", title: "Settings", symbol: "gearshape.fill") { model.openFromMenu(.settings) },
            Item(id: "fullscreen", title: model.isFullScreen ? "Exit Full Screen" : "Full Screen",
                 symbol: model.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") { model.toggleFullScreen() },
            Item(id: "lofi", title: model.prefs.lofiOn ? "Lo-fi Music: On" : "Lo-fi Music: Off", symbol: "music.note") { model.toggleLofi() },
            Item(id: "silent", title: model.prefs.silentGames ? "All Sound: Off" : "All Sound: On",
                 symbol: model.prefs.silentGames ? "speaker.slash.fill" : "speaker.wave.2.fill") { model.toggleSilentGames() },
        ]
        if emulator.canUndoLoad {
            items.insert(Item(id: "undo", title: "Undo Load", symbol: "arrow.uturn.backward") { emulator.undoLoad() }, at: 3)
        }
        if model.openGames.count > 1 {
            items.append(Item(id: "games", title: "Switch Game", symbol: "square.stack.fill") { model.openFromMenu(.games) })
        }
        items.append(Item(id: "library", title: "Library", symbol: "square.grid.2x2.fill") { model.panel = nil; model.screen = .library })
        items.append(Item(id: "help", title: "Controls", symbol: "gamecontroller.fill") { model.openFromMenu(.help) })

        return VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(items) { item in
                    Button(action: item.action) {
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(item.id == "resume" ? theme.onAccent : theme.accent)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(item.id == "resume" ? theme.accent : theme.accent.opacity(0.13)))
                            Text(item.title).font(theme.display(13, .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .card(12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .padFocusable("menu-\(item.id)", cornerRadius: 13, action: item.action)
                }
            }
            Note(text: "Controller: D-pad to move, A to choose, B to go back. Opens with Home, a stick click, or Start + Select.")
        }
    }
}

// MARK: - Save states

private struct StatesPanel: View {
    let model: AppModel
    @State private var confirmRestart = false

    var body: some View {
        let emulator = model.emulator
        let _ = emulator.stateVersion // re-read the slots after a save
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Emulator.slots, id: \.self) { slot in
                SlotRow(slot: slot, info: emulator.stateInfo(slot)) {
                    emulator.saveState(slot)
                } load: {
                    if emulator.loadState(slot) { model.panel = nil }
                }
            }
            HStack(alignment: .center, spacing: 8) {
                Note(text: "Your spot also saves by itself whenever you leave. \(key(.quickSave)) quick saves, \(key(.quickLoad)) quick loads.")
                Spacer(minLength: 4)
                if emulator.canUndoLoad {
                    Button("Undo Load") { emulator.undoLoad() }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .focusable(false)
                        .padFocusable("undo-load", cornerRadius: 15) { emulator.undoLoad() }
                }
                Button(confirmRestart ? "Sure? Restart" : "Restart", action: restart)
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .focusable(false)
                    .padFocusable("restart", cornerRadius: 15, action: restart)
            }
            .padding(.top, 4)
        }
    }

    private func restart() {
        if confirmRestart {
            model.emulator.restart()
            model.panel = nil
        }
        confirmRestart.toggle()
    }

    private func key(_ action: Controls.Action) -> String { model.controls.key(for: action)?.name ?? "—" }
}

private struct SlotRow: View {
    let slot: String
    let info: (date: Date, thumbnail: NSImage?)?
    let save: () -> Void
    let load: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.board)
                if let thumbnail = info?.thumbnail {
                    Image(nsImage: thumbnail).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.subtext.opacity(0.6))
                }
            }
            .frame(width: 60, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(Emulator.slotTitle(slot)).font(theme.display(13, .semibold))
                Text(info.map { $0.date.formatted(.relative(presentation: .named)) } ?? "Empty")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.subtext)
            }
            Spacer(minLength: 6)
            Button("Save", action: save)
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .focusable(false)
                .padFocusable("save-\(slot)", cornerRadius: 15, action: save)
            Button("Load", action: load)
                .buttonStyle(PillButtonStyle())
                .focusable(false)
                .disabled(info == nil)
                .padFocusable(info == nil ? nil : "load-\(slot)", cornerRadius: 15, action: load)
        }
        .padding(8)
        .card(12)
    }
}

// MARK: - Display

private struct DisplayPanel: View {
    @Bindable var display: Display
    let model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        let emulator = model.emulator
        let system = model.currentSystem
        VStack(alignment: .leading, spacing: 16) {
            PanelSection(title: "Size") {
                HStack(spacing: 10) {
                    IconButton(symbol: "minus", label: "Smaller (⌘−)", padID: "size-down") { model.zoomGame(-1) }
                    Note(text: "Or drag the window's edge; it snaps to sharp, pixel-perfect sizes. Double-click the game for full screen.")
                    Spacer(minLength: 0)
                    IconButton(symbol: "plus", label: "Bigger (⌘+)", padID: "size-up") { model.zoomGame(1) }
                }
            }

            PanelSection(title: "Picture") {
                SegmentedChoice(options: Display.Filter.allCases.map { ($0.title, $0) }, selection: display.filter, padID: "filter") { display.filter = $0 }
                if system == .gb {
                    SegmentedChoice(options: Emulator.gbPalettes.map { ($0, $0) }, selection: emulator.gbPalette, padID: "palette") { emulator.gbPalette = $0 }
                }
                VStack(spacing: 4) {
                    if system == .gba || system == .gbc {
                        ToggleRow(title: "Color correction", subtitle: "The real screen's softer colors",
                                  isOn: Binding { emulator.colorCorrection } set: { emulator.colorCorrection = $0 }, padID: "color-correction")
                    }
                    ToggleRow(title: "LCD ghosting", subtitle: "Blends frames like the real screen (some games need it)",
                              isOn: Binding { emulator.frameBlending } set: { emulator.frameBlending = $0 }, padID: "blending")
                    ToggleRow(title: "Show FPS", isOn: Binding { emulator.showFPS } set: { emulator.showFPS = $0 }, padID: "fps")
                }
            }

            if system == .nds {
                PanelSection(title: "Screen layout") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(Display.Layout.allCases) { layout in
                            LayoutTile(layout: layout, selected: display.layout == layout) { display.layout = layout }
                        }
                    }
                    Note(text: display.layout.detail + ".")
                }
                PanelSection(title: "Shell") {
                    HStack(spacing: 8) {
                        ForEach(Display.Shell.allCases) { shell in
                            ShellSwatch(shell: shell, selected: display.shell == shell) { display.shell = shell }
                        }
                    }
                }
                VStack(spacing: 6) {
                    SettingsRow(title: "Screen gap") {
                        Slider(value: $display.gap, in: 0...48).frame(width: 150).tint(theme.accent)
                            .accessibilityLabel("Screen gap")
                    }
                    .padFocusable("gap", cornerRadius: 8, adjust: { display.gap = min(max(display.gap + Double($0 * 6), 0), 48) }) {}
                    ToggleRow(title: "Swap screens", subtitle: "Or press \(model.controls.key(for: .swapScreens)?.name ?? "—") while playing",
                              isOn: $display.swap, padID: "swap")
                }
            }
        }
    }
}

/// A small drawing of the layout + its name (the tooltip says more).
private struct LayoutTile: View {
    let layout: Display.Layout
    let selected: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Canvas { context, size in
                    let topColor = selected ? theme.onAccent : theme.text.opacity(0.75)
                    let bottomColor = selected ? theme.onAccent.opacity(0.55) : theme.text.opacity(0.38)
                    if layout == .separate {
                        // Two windows: the main one and the touch screen on its own, apart.
                        let unit = min(size.width / (256 + 128 + 40), size.height / 192)
                        let main = CGRect(x: (size.width - (424 * unit)) / 2, y: (size.height - 192 * unit) / 2, width: 256 * unit, height: 192 * unit)
                        let other = CGRect(x: main.maxX + 40 * unit, y: main.minY + 48 * unit, width: 128 * unit, height: 96 * unit)
                        context.fill(Path(roundedRect: main, cornerRadius: 1.5), with: .color(topColor))
                        context.stroke(Path(roundedRect: other, cornerRadius: 1.5), with: .color(bottomColor), style: StrokeStyle(lineWidth: 1.2, dash: [2, 1.5]))
                        context.fill(Path(roundedRect: other.insetBy(dx: 1.5, dy: 1.5), cornerRadius: 1), with: .color(bottomColor.opacity(0.6)))
                        return
                    }
                    let l = Display.dsLayout(layout, gap: 14, swap: false, shell: false)
                    let s = min(size.width / l.size.width, size.height / l.size.height)
                    let offset = CGPoint(x: (size.width - l.size.width * s) / 2, y: (size.height - l.size.height * s) / 2)
                    func draw(_ r: CGRect?, _ color: Color, outlined: Bool = false) {
                        guard let r else { return }
                        let rect = CGRect(x: offset.x + r.minX * s, y: offset.y + r.minY * s, width: r.width * s, height: r.height * s)
                        if outlined { context.fill(Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: 2), with: .color(selected ? theme.accent : theme.surface)) }
                        context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color))
                    }
                    draw(l.top, topColor)
                    draw(l.extra, l.extraIsTop ? topColor : bottomColor)
                    draw(l.bottom, bottomColor, outlined: layout == .miniTouch)
                }
                .frame(height: 20)
                Text(layout.title)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(selected ? theme.onAccent : theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? theme.accent : hovering ? theme.boardAlt : theme.surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .help(layout.detail)
        .accessibilityLabel(layout.title)
        .accessibilityHint(layout.detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .padFocusable("layout-\(layout.rawValue)", cornerRadius: 11, action: action)
    }
}

private struct ShellSwatch: View {
    let shell: Display.Shell
    let selected: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            ZStack {
                if let colors = shell.colors {
                    Circle().fill(LinearGradient(colors: [Color(hex: colors.0), Color(hex: colors.1)], startPoint: .top, endPoint: .bottom))
                } else {
                    Circle().fill(theme.surface)
                    Image(systemName: "nosign").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.subtext)
                }
            }
            .frame(width: 28, height: 28)
            .overlay(Circle().stroke(theme.hairline, lineWidth: 1))
            .padding(3)
            .overlay(Circle().stroke(selected ? theme.accent : .clear, lineWidth: 2))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(shell.title)
        .accessibilityLabel("\(shell.title) shell")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .padFocusable("shell-\(shell.rawValue)", cornerRadius: 17, action: action)
    }
}

// MARK: - Mods & cheats

private struct ModsPanel: View {
    let model: AppModel
    @Environment(\.theme) private var theme
    @State private var cheats: [Cheat] = []
    @State private var loaded = false
    @State private var name = ""
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelSection(title: "Cheats") {
                if !model.emulator.cheatsSupported {
                    Note(text: "Cheats aren't available for this game.")
                }
                ForEach($cheats) { $cheat in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(cheat.name.isEmpty ? "Cheat" : cheat.name).font(theme.display(13, .semibold))
                            Text(cheat.code.replacingOccurrences(of: "\n", with: " "))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(theme.subtext)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        ThemedToggle(isOn: $cheat.enabled, label: cheat.name)
                        Button { cheats.removeAll { $0.id == cheat.id } } label: {
                            Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(theme.subtext)
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .accessibilityLabel("Delete \(cheat.name)")
                    }
                    .padding(10)
                    .card(12)
                    .padFocusable("cheat-\(cheat.id)", cornerRadius: 13, adjust: { _ in cheat.enabled.toggle() }) { cheat.enabled.toggle() }
                }
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Name, like “Infinite money”", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.board))
                    ZStack(alignment: .topLeading) {
                        if code.isEmpty {
                            Text("Paste a GameShark, Action Replay or Code Breaker code")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.subtext.opacity(0.8))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $code)
                            .font(.system(size: 12, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(5)
                    }
                    .frame(height: 64)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.board))
                    HStack {
                        Spacer()
                        Button("Add Cheat", action: add)
                            .buttonStyle(PillButtonStyle())
                            .focusable(false)
                            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.emulator.cheatsSupported)
                    }
                }
                .padding(10)
                .card(12)
            }

            PanelSection(title: "ROM patches") {
                Note(text: "Turn this game into a ROM hack, translation or fan mod with an .ips, .ups or .bps patch. The modded version shows up in your library with its own saves.")
                Button("Apply a Patch…", action: patch)
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .focusable(false)
                    .padFocusable("apply-patch", cornerRadius: 15, action: patch)
                Note(text: "Tip: drop .ups or .bps patches on the window and they find their game by themselves.")
            }
        }
        .onAppear {
            if let game = model.emulator.game { cheats = model.library.cheats(for: game) }
            loaded = true
        }
        .onChange(of: cheats) {
            guard loaded, let game = model.emulator.game else { return }
            model.library.setCheats(cheats, for: game)
            model.emulator.applyCheats(cheats)
        }
    }

    private func add() {
        cheats.append(Cheat(name: name.trimmingCharacters(in: .whitespaces), code: code.trimmingCharacters(in: .whitespacesAndNewlines)))
        name = ""
        code = ""
    }

    private func patch() {
        if let game = model.emulator.game { model.applyPatch(to: game) }
    }
}

// MARK: - Open games

private struct GamesPanel: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(Array(model.openGames.enumerated()), id: \.element) { index, rom in
                    OpenGameTile(model: model, rom: rom, number: index + 1)
                }
            }
            Note(text: "Every open game stays exactly where you left it. ⌘1–⌘6 switch, ⌃Tab jumps back to the last one.")
        }
    }
}

private struct OpenGameTile: View {
    let model: AppModel
    let rom: URL
    let number: Int
    @Environment(\.theme) private var theme
    @State private var thumbnail: NSImage?

    var body: some View {
        let current = model.emulator.game == rom
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Color.black
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                    } else if let system = GameSystem(rom: rom) {
                        ConsoleArt(system: system).padding(10)
                    }
                }
                .aspectRatio(3 / 2, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(current ? theme.accent : .clear, lineWidth: 2))
                HStack(spacing: 4) {
                    Text(rom.gameTitle).font(theme.display(12, .semibold)).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(current ? "Playing" : "⌘\(number)").font(.system(size: 10)).foregroundStyle(current ? theme.accent : theme.subtext)
                }
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .contextMenu { Button("Close Game") { model.closeGame(rom) } }
        .padFocusable("open-\(number)", cornerRadius: 11, action: open)
        .task(id: model.emulator.stateVersion) {
            thumbnail = current ? model.emulator.snapshot.map { NSImage(cgImage: $0, size: .zero) } : model.emulator.resumeThumbnail(for: rom)
        }
    }

    private func open() {
        if model.emulator.game == rom { model.panel = nil } else { model.play(rom) }
    }
}

// MARK: - Controls cheat sheet

struct HelpPanel: View {
    let controls: Controls
    let gamepad: GamepadInput?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PanelSection(title: "Game buttons") {
                row("Move", keys: [.up, .down, .left, .right], pad: "D-pad / left stick")
                ForEach([Controls.Action.a, .b, .x, .y, .l, .r, .start, .select, .turboA, .turboB]) { action in
                    row(action.title, keys: [action], pad: action.padName)
                }
            }
            PanelSection(title: "While playing") {
                ForEach([Controls.Action.fastForward, .slowMotion, .rewind, .pause, .quickSave, .quickLoad, .swapScreens, .screenshot, .mute, .help]) { action in
                    row(action.title, keys: [action], pad: action.padName)
                }
                row("Game menu", text: "⋯", pad: "Home, a stick click, or Start + Select")
                row("Full screen", text: "⌃⌘F", pad: nil)
                row("Back to library", text: "Esc", pad: "B in menus")
            }
            Note(text: gamepad?.connected.isEmpty == false
                 ? "\(gamepad!.connected.joined(separator: ", ")) connected. Change keys in Settings › Controls."
                 : "Any controller works too (Xbox, PlayStation, Switch Pro…). Change keys in Settings › Controls.")
        }
    }

    private func row(_ title: String, keys: [Controls.Action] = [], text: String? = nil, pad: String?) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12.5)).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 3) {
                if let text { KeyCap(text: text) }
                ForEach(keys) { KeyCap(text: controls.key(for: $0)?.name ?? "—") }
            }
            if let pad {
                Text(pad).font(.system(size: 10.5)).foregroundStyle(theme.subtext).frame(width: 112, alignment: .leading).lineLimit(2)
            } else {
                Spacer().frame(width: 112)
            }
        }
    }
}
