import SwiftUI

/// The game, edge to edge (the window is the picture's shape). Controls float over it on frosted glass when the
/// mouse moves and fade away while you play. Panels (game menu, save states, display, mods, settings…) slide up.
struct GameView: View {
    @Bindable var model: AppModel
    @Environment(\.theme) private var theme
    @State private var controlsVisible = true
    @State private var hovering = false
    @State private var hideTask: Task<Void, Never>?

    private var emulator: Emulator { model.emulator }

    var body: some View {
        ZStack {
            GameSurface(model: model)

            // Everything over the picture scales down in small windows instead of getting cramped.
            FitToWindow(design: DesignSize.gameOverlay) {
                ZStack {
                    if showControls {
                        ControlBar(model: model)
                            .transition(.opacity.combined(with: .offset(y: -6)))
                    }

                    if emulator.userPaused && model.panel == nil {
                        Color.black.opacity(0.4)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                        PausedOverlay(model: model)
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }

                    VStack {
                        Spacer()
                        HStack(spacing: 6) {
                            if emulator.showFPS {
                                Text("\(Int(emulator.measuredFPS.rounded())) FPS")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .frame(height: 22)
                                    .background(Capsule().fill(.black.opacity(0.55)))
                            }
                            Spacer()
                            if emulator.isRewinding { indicator("Rewinding", "backward.fill") }
                            if emulator.slowMotion { indicator("Slow motion", "tortoise.fill") }
                        }
                        .padding(10)
                    }
                    .allowsHitTesting(false)

                    if let panel = model.panel {
                        Color.black.opacity(0.45)
                            .onTapGesture { model.back() }
                            .transition(.opacity)
                        PanelCard(panel: panel, model: model)
                            .frame(maxWidth: panel == .settings ? 460 : 380)
                            .padding(12)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
        .background(.black)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                hovering = true
                poke()
            case .ended:
                hovering = false
                scheduleHide(after: 0.5)
            }
        }
        .onAppear { poke() }
        .animation(.easeOut(duration: 0.2), value: showControls)
        .animation(.easeOut(duration: 0.2), value: emulator.userPaused)
        .animation(.easeOut(duration: 0.2), value: emulator.isRewinding)
        .animation(.easeOut(duration: 0.2), value: emulator.slowMotion)
    }

    private func indicator(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(.black.opacity(0.6)))
            .transition(.opacity)
    }

    private var showControls: Bool { controlsVisible || emulator.userPaused || model.panel != nil }

    /// Mouse moved: show the controls, then hide them (and the cursor) after a moment of stillness.
    private func poke() {
        if !controlsVisible { controlsVisible = true }
        scheduleHide(after: 2.2)
    }

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            controlsVisible = false
            if hovering && emulator.isRunning { NSCursor.setHiddenUntilMouseMoves(true) }
        }
    }
}

/// The picture: one screen, or both DS screens in the chosen layout and shell.
struct GameSurface: View {
    let model: AppModel

    var body: some View {
        let display = model.display
        GeometryReader { geo in
            if model.currentSystem == .nds {
                DSScreens(model: model, space: geo.size)
                    .frame(width: geo.size.width, height: geo.size.height)
            } else {
                let picture = model.pictureSize
                let size = Self.fit(picture, in: geo.size)
                ScreenLayer(emulator: model.emulator, filter: display.filter, onDoubleClick: model.toggleFullScreen)
                    .frame(width: size.width, height: size.height)
                    .overlay { if display.filter == .lcd { LCDGrid(columns: Int(picture.width), rows: Int(picture.height)) } }
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    /// Largest size with the picture's aspect ratio that fits.
    static func fit(_ picture: CGSize, in space: CGSize) -> CGSize {
        let scale = min(space.width / picture.width, space.height / picture.height)
        return CGSize(width: picture.width * scale, height: picture.height * scale)
    }
}

/// The DS screens cut out of the core's 256×384 frame and placed per the layout, inside the chosen shell.
private struct DSScreens: View {
    let model: AppModel
    let space: CGSize

    private struct Placed: Identifiable {
        let id: String
        let crop: ScreenLayer.Crop
        let rect: CGRect
    }

    var body: some View {
        let display = model.display
        let layout = display.dsLayout()
        let s = min(space.width / layout.size.width, space.height / layout.size.height)
        let shell = display.shell.colors
        // Big screens first, so a small one (Mini Touch) sits on top of them.
        let placed = [
            layout.top.map { Placed(id: "top", crop: .top, rect: $0) },
            layout.bottom.map { Placed(id: "bottom", crop: .bottom, rect: $0) },
            layout.extra.map { Placed(id: "extra", crop: layout.extraIsTop ? .top : .bottom, rect: $0) },
        ].compactMap { $0 }.sorted { $0.rect.width > $1.rect.width }

        ZStack(alignment: .topLeading) {
            if let shell {
                RoundedRectangle(cornerRadius: 18 * s, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: shell.0), Color(hex: shell.1)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 18 * s, style: .continuous).stroke(.white.opacity(0.2), lineWidth: 1))
                if display.layout == .stacked, display.gap >= 6, let top = layout.top, let bottom = layout.bottom { // hinge
                    Capsule()
                        .fill(.black.opacity(0.16))
                        .frame(width: layout.size.width * s * 0.86, height: CGFloat(display.gap) * s * 0.5)
                        .position(x: layout.size.width * s / 2, y: (min(top.maxY, bottom.maxY) + CGFloat(display.gap) / 2) * s)
                }
            }
            ForEach(placed) { item in
                let floating = display.layout == .miniTouch && item.rect.width < Display.screen.width
                // Without a shell, layouts with empty space get a faint edge so you can see where each screen is.
                let outlined = shell == nil && !floating && ![.stacked, .sideBySide, .single, .separate, .miniTouch].contains(display.layout)
                screen(item.crop, in: item.rect, scale: s, framed: shell != nil, floating: floating, outlined: outlined, filter: display.filter)
            }
        }
        .frame(width: layout.size.width * s, height: layout.size.height * s)
        .animation(.snappy(duration: 0.3), value: layout)
    }

    private func screen(_ crop: ScreenLayer.Crop, in rect: CGRect, scale s: CGFloat, framed: Bool, floating: Bool,
                        outlined: Bool, filter: Display.Filter) -> some View {
        ScreenLayer(emulator: model.emulator, crop: crop, filter: filter, touchScreen: crop == .bottom, onDoubleClick: model.toggleFullScreen)
            .overlay { if filter == .lcd { LCDGrid(columns: 256, rows: 192) } }
            .frame(width: rect.width * s, height: rect.height * s)
            .clipShape(RoundedRectangle(cornerRadius: framed || floating || outlined ? 3 * s : 0, style: .continuous))
            .overlay {
                if floating { // a small screen over the big one needs an edge to read as separate
                    RoundedRectangle(cornerRadius: 3 * s, style: .continuous).stroke(.white.opacity(0.75), lineWidth: 1.5)
                } else if outlined {
                    RoundedRectangle(cornerRadius: 3 * s, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(floating ? 0.55 : 0), radius: 8, y: 3)
            .padding(framed ? 3 * s : 0)
            .background(framed ? Color.black.opacity(0.9) : .clear, in: RoundedRectangle(cornerRadius: 4 * s, style: .continuous))
            .position(x: rect.midX * s, y: rect.midY * s)
    }
}

/// The other DS screen in its own window (Separate layout). The mouse works on it as the stylus;
/// hovering shows a handle to move the window and a button to put everything away.
struct SeparateScreenView: View {
    let model: AppModel
    @State private var hovering = false

    var body: some View {
        let display = model.display
        ZStack(alignment: .top) {
            Color.black
            ScreenLayer(emulator: model.emulator, crop: display.swap ? .top : .bottom, filter: display.filter, touchScreen: true)
                .overlay { if display.filter == .lcd { LCDGrid(columns: 256, rows: 192) } }
            if hovering {
                HStack(spacing: 0) {
                    Spacer()
                    WindowDragArea()
                        .frame(width: 84, height: 20)
                        .overlay(Capsule().fill(.white.opacity(0.75)).frame(width: 40, height: 5).allowsHitTesting(false))
                        .help("Drag to move")
                    Spacer()
                }
                .overlay(alignment: .trailing) {
                    GlassButton(symbol: "minus", label: "Minimize (⌥P brings it back)", size: 22) { model.hideWindow() }
                        .padding(.trailing, 6)
                }
                .padding(.top, 5)
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// The floating bar over the game. Shows everything when there's room, and gets more compact in small windows
/// (whatever's left out is in the ⋯ menu).
private struct ControlBar: View {
    @Bindable var model: AppModel
    @State private var choosingSpeed = false
    private var emulator: Emulator { model.emulator }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                bar(.full)
                bar(.compact)
                bar(.minimal)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 18)
            .background {
                ZStack {
                    WindowDragArea()
                    LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private enum Size { case full, compact, minimal }

    private func bar(_ size: Size) -> some View {
        HStack(spacing: 6) {
            GlassButton(symbol: "chevron.left", label: "Library (Esc)", size: 28) { model.back() }
            if size == .full {
                VStack(alignment: .leading, spacing: 0) {
                    Text(emulator.game?.gameTitle ?? "")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .opacity(0.7)
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 3)
                .frame(minWidth: 70, alignment: .leading)
            }
            Spacer(minLength: 4)
            if size == .full && model.openGames.count > 1 {
                GlassButton(symbol: "square.stack.fill", label: "Open games (⌘1–⌘6)", active: model.panel == .games, size: 28) { model.togglePanel(.games) }
            }
            GlassButton(symbol: emulator.userPaused ? "play.fill" : "pause.fill",
                        label: (emulator.userPaused ? "Resume" : "Pause") + key(.pause), size: 28) { emulator.userPaused.toggle() }
            if size != .minimal {
                GlassButton(symbol: emulator.soundOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                            label: (emulator.soundOn ? "Mute everything" : "Turn the sound back on") + key(.mute), active: !emulator.soundOn, size: 28) {
                    emulator.toggleSound()
                }
                GlassButton(symbol: model.prefs.lofiOn ? "waveform" : "music.note", label: model.prefs.lofiOn ? "Turn lo-fi off" : "Turn lo-fi on",
                            active: model.prefs.lofiOn, size: 28) { model.toggleLofi() }
                speedMenu(withKey: size == .full)
            }
            if size != .minimal {
                GlassButton(symbol: "bookmark.fill", label: "Save states" + key(.quickSave, prefix: " · quick save "), active: model.panel == .states, size: 28) { model.togglePanel(.states) }
                GlassButton(symbol: "slider.horizontal.3", label: "Display", active: model.panel == .display, size: 28) { model.togglePanel(.display) }
            }
            GlassButton(symbol: model.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        label: model.isFullScreen ? "Exit Full Screen (⌃⌘F)" : "Full Screen (⌃⌘F, or double-click the game)", size: 28) { model.toggleFullScreen() }
            if size == .full {
                GlassButton(symbol: "gearshape.fill", label: "Settings (⌘,)", active: model.panel == .settings, size: 28) { model.togglePanel(.settings) }
            }
            moreMenu
            GlassButton(symbol: "minus", label: "Minimize (\(model.prefs.popOutShortcut?.display ?? "menu bar icon") brings it back)", size: 28) { model.hideWindow() }
        }
    }

    private func key(_ action: Controls.Action, prefix: String = " (") -> String {
        guard let name = model.controls.key(for: action)?.name else { return "" }
        return prefix + name + (prefix == " (" ? ")" : "")
    }

    private var subtitle: String {
        var parts = [model.currentSystem?.title ?? ""]
        if emulator.fastForward || emulator.holdingFastForward {
            // Say so when a game can't reach the speed asked for (heavy DS games top out around 5–8×).
            let actual = emulator.actualSpeed
            parts.append(actual > 1 && actual + 0.3 < emulator.speed ? "\(emulator.speed.speedLabel), running \(actual.speedLabel)" : "\(emulator.speed.speedLabel) speed")
        }
        return parts.joined(separator: " · ")
    }

    /// Click toggles fast-forward; hold for the speed menu. Shows its key so it's easy to remember.
    private func speedMenu(withKey: Bool) -> some View {
        Menu {
            Section("Fast-forward speed") {
                ForEach([2.0, 4, 8, 16], id: \.self) { speed in
                    Toggle(speed.speedLabel, isOn: Binding { emulator.speed == speed } set: { _ in emulator.speed = speed })
                }
                Button("Choose Speed… (now \(emulator.speed.speedLabel))") { choosingSpeed = true }
            }
            Toggle("Slow Motion" + key(.slowMotion), isOn: Binding { emulator.slowMotion } set: { emulator.slowMotion = $0 })
            Toggle("Lo-fi While Fast-Forwarding", isOn: Binding { model.prefs.lofiSpedUp } set: { _ in model.toggleLofiSpedUp() })
        } label: {
            GlassIcon(symbol: "forward.fill", active: speeding, size: 28,
                      badge: speeding ? speedNow : withKey ? model.controls.key(for: .fastForward)?.name : nil)
        } primaryAction: {
            emulator.toggleFastForward()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
        .help("Fast-forward" + key(.fastForward) + " · hold for speeds and slow motion")
        .accessibilityLabel("Fast-forward")
        .popover(isPresented: $choosingSpeed, arrowEdge: .bottom) { speedPopover }
    }

    private var speeding: Bool { emulator.fastForward || emulator.holdingFastForward }

    /// The speed it's really running at: what was asked for, or less when a game can't keep up.
    private var speedNow: String {
        let actual = emulator.actualSpeed
        return (actual > 1 && actual + 0.3 < emulator.speed ? actual : emulator.speed).speedLabel
    }

    /// The speed slider, from the fast-forward button's menu.
    private var speedPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Fast-forward speed").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(emulator.speed.speedLabel).font(.system(size: 13, weight: .semibold)).monospacedDigit()
            }
            SpeedSlider(emulator: emulator, padID: "speed-popover")
            let actual = emulator.actualSpeed
            if (emulator.fastForward || emulator.holdingFastForward), actual > 1, actual + 0.3 < emulator.speed {
                Text("This game tops out around \(actual.speedLabel) on this Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 270)
    }

    private var moreMenu: some View {
        Menu {
            Button("Game Menu") { model.togglePanel(.menu) }
            Button("Settings…  ⌘,") { model.togglePanel(.settings) }
            Button("Save States…") { model.togglePanel(.states) }
            Button("Display…") { model.togglePanel(.display) }
            Button("Mods & Cheats…") { model.togglePanel(.mods) }
            if model.openGames.count > 1 { Button("Open Games…") { model.togglePanel(.games) } }
            Button("Controls…" + key(.help)) { model.togglePanel(.help) }
            Divider()
            Button("Take Screenshot" + key(.screenshot)) { emulator.screenshot() }
            if emulator.canUndoLoad { Button("Undo Load") { emulator.undoLoad() } }
            Button(emulator.soundOn ? "Mute" + key(.mute) : "Unmute" + key(.mute)) { emulator.soundOn.toggle() }
            Button(model.prefs.lofiOn ? "Turn Lo-fi Off" : "Turn Lo-fi On") { model.toggleLofi() }
            Button(model.prefs.silentGames ? "Turn Game Sound Back On" : "No Sound in Games") { model.toggleSilentGames() }
            Button("Bigger  ⌘+") { model.zoomGame(1) }
            Button("Smaller  ⌘−") { model.zoomGame(-1) }
            Divider()
            Button("Restart Game") { emulator.restart() }
            Button("Close Game") { if let game = emulator.game { model.closeGame(game) } }
        } label: {
            GlassIcon(symbol: "ellipsis", size: 28)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
        .help("More")
        .accessibilityLabel("More")
    }
}

/// Paused: a big Resume, plus the two things people look for (full screen, settings).
private struct PausedOverlay: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Button { model.emulator.userPaused = false } label: {
                VStack(spacing: 10) {
                    GlassIcon(symbol: "play.fill", size: 64)
                    Text("Paused")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 4)
                }
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityLabel("Resume")
            HStack(spacing: 8) {
                GlassButton(symbol: model.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                            label: "Full Screen (⌃⌘F)", size: 30, text: model.isFullScreen ? "Exit Full Screen" : "Full Screen") { model.toggleFullScreen() }
                GlassButton(symbol: "gearshape.fill", label: "Settings (⌘,)", size: 30, text: "Settings") { model.togglePanel(.settings) }
            }
        }
    }
}
