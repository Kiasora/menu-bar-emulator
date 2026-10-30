import SwiftUI

/// Settings as its own page (from the library). In a game, the same `SettingsContent` opens as a panel.
struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                IconButton(symbol: "chevron.left", label: "Back (Esc)") { model.back() }
                Text(model.settingsPage == .main ? "Settings" : "Keyboard").font(theme.display(24, .heavy))
                    .contentTransition(.opacity)
                Spacer()
                ToolbarPill {
                    ToolbarIcon(symbol: model.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                label: "Full Screen (⌃⌘F)") { model.toggleFullScreen() }
                    ToolbarIcon(symbol: "minus", label: "Minimize") { model.hideWindow() }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .background(WindowDragArea())

            PadScrollView {
                SettingsContent(model: model)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 20)
                    .padding(.top, 4)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
            }
            .id(model.settingsPage)
            .transition(.opacity)
        }
        .animation(.snappy(duration: 0.25), value: model.settingsPage)
        .onDisappear { model.controls.capturing = nil }
    }
}

/// Every setting, grouped. Used by the Settings page and the in-game Settings panel.
struct SettingsContent: View {
    @Bindable var model: AppModel

    var body: some View {
        switch model.settingsPage {
        case .main: MainSettings(model: model)
        case .controls: ControlsSettings(model: model)
        }
    }
}

private struct MainSettings: View {
    @Bindable var model: AppModel
    @AppStorage(ThemeKind.storageKey) private var themeRaw = ThemeKind.dark.rawValue
    @Environment(\.theme) private var theme

    private var emulator: Emulator { model.emulator }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if AppInfo.isEarlyBuild { supportBanner }

            SettingsGroup(title: "Playing") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Fast-forward speed (\(key(.fastForward)) toggles it)").font(.system(size: 13))
                        Spacer()
                        Text(emulator.speed.speedLabel)
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(theme.accent)
                    }
                    SpeedSlider(emulator: emulator, padID: "ff-speed")
                }
                ToggleRow(title: "Rewind", subtitle: "Hold \(key(.rewind)) in Game Boy and GBA games",
                          isOn: Binding { emulator.rewindEnabled } set: { emulator.rewindEnabled = $0 }, padID: "rewind")
                ToggleRow(title: "Sound", subtitle: "Everything, lo-fi too. \(key(.mute)) or the speaker up top mutes it",
                          isOn: Binding { emulator.soundOn } set: { emulator.soundOn = $0 }, padID: "sound")
                ToggleRow(title: "No sound in games", subtitle: "Silences everything while a game's up, lo-fi included",
                          isOn: Binding { model.prefs.silentGames } set: { model.prefs.silentGames = $0 }, padID: "silent-games")
                SettingsRow(title: "Volume") {
                    Slider(value: Binding { emulator.volume } set: { emulator.volume = $0 }, in: 0...1)
                        .frame(width: 170)
                        .tint(theme.accent)
                        .disabled(!emulator.soundOn)
                        .accessibilityLabel("Volume")
                }
                .padFocusable("volume", cornerRadius: 8, adjust: { emulator.volume = min(max(emulator.volume + Double($0) * 0.1, 0), 1) }) {}
            }

            SettingsGroup(title: "Music", footer: "Both are also at the top of the library, and in the game bar.") {
                ToggleRow(title: "Lo-fi music", subtitle: "Plays everywhere, games included, until you turn it off",
                          isOn: Binding { model.prefs.lofiOn } set: { model.prefs.lofiOn = $0 }, padID: "lofi-on")
                ToggleRow(title: "Lo-fi while fast-forwarding", subtitle: "Fades in where the sped-up game's sound would be",
                          isOn: Binding { model.prefs.lofiSpedUp } set: { model.prefs.lofiSpedUp = $0 }, padID: "lofi-sped-up")
                ToggleRow(title: "Keep playing when the window's closed", subtitle: "Lo-fi carries on in the background, like a music app",
                          isOn: Binding { model.prefs.lofiInBackground } set: { model.prefs.lofiInBackground = $0 }, padID: "lofi-background")
            }
            SettingsGroup(title: "Window") {
                ToggleRow(title: "Pause when hidden", subtitle: "Off: games keep running while the window is away",
                          isOn: Binding { model.prefs.pauseWhenHidden } set: { model.prefs.pauseWhenHidden = $0 }, padID: "pause-hidden")
                ToggleRow(title: "Close when I click outside", subtitle: "For the window under the menu bar icon",
                          isOn: Binding { model.prefs.closeOnClickOutside } set: { model.prefs.closeOnClickOutside = $0 }, padID: "close-outside")
                SettingsRow(title: "Full screen", subtitle: "Or double-click a game") {
                    Button(model.isFullScreen ? "Exit" : "Enter") { model.toggleFullScreen() }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .focusable(false)
                    KeyCap(text: "⌃⌘F")
                }
                .padFocusable("fullscreen", cornerRadius: 8) { model.toggleFullScreen() }
                if !model.isFloating {
                    SettingsRow(title: "Pop out", subtitle: "A floating window that stays on top") {
                        Button("Pop Out") { model.popOut() }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                            .focusable(false)
                    }
                    .padFocusable("pop-out", cornerRadius: 8) { model.popOut() }
                }
            }

            SettingsGroup(title: "Shortcuts", footer: "Work from any app. Click one, then press a key with ⌘, ⌥ or ⌃. Delete clears it.") {
                SettingsRow(title: "Pop out", subtitle: "Floating window, on top of everything") {
                    ShortcutRecorder(model: model, slot: .popOut)
                }
                SettingsRow(title: "Open from menu bar", subtitle: "Same as clicking the menu bar icon") {
                    ShortcutRecorder(model: model, slot: .menuBar)
                }
            }

            SettingsGroup(title: "Controls", footer: "Any controller works: Xbox, PlayStation, Switch Pro, MFi. Right trigger fast-forwards, left trigger rewinds; Home, a stick click or Start + Select opens the game menu, and it drives every menu too.") {
                Button { model.settingsPage = .controls } label: {
                    SettingsRow(title: "Keyboard and tester", subtitle: "\(key(.a)) = A · \(key(.b)) = B · arrows move") {
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.subtext)
                    }
                }
                .buttonStyle(.plain)
                .focusable(false)
                .padFocusable("keyboard", cornerRadius: 8) { model.settingsPage = .controls }
                SettingsRow(title: "Controller") {
                    let names = model.gamepad?.connected ?? []
                    Label(names.isEmpty ? "None connected" : names.joined(separator: ", "),
                          systemImage: names.isEmpty ? "gamecontroller" : "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(names.isEmpty ? theme.subtext : theme.good)
                        .lineLimit(1)
                }
            }

            SettingsGroup(title: "Picture") {
                ToggleRow(title: "Color correction", subtitle: "GBA and GBC: the real screens' softer colors",
                          isOn: Binding { emulator.colorCorrection } set: { emulator.colorCorrection = $0 }, padID: "color-correction")
                ToggleRow(title: "LCD ghosting", subtitle: "Blends frames like the real screens (some games use it for see-through effects)",
                          isOn: Binding { emulator.frameBlending } set: { emulator.frameBlending = $0 }, padID: "blending")
                VStack(alignment: .leading, spacing: 8) {
                    Text("Game Boy colors (original Game Boy games)").font(.system(size: 13))
                    SegmentedChoice(options: Emulator.gbPalettes.map { ($0, $0) }, selection: emulator.gbPalette, padID: "palette") { emulator.gbPalette = $0 }
                }
                ToggleRow(title: "Show FPS", isOn: Binding { emulator.showFPS } set: { emulator.showFPS = $0 }, padID: "fps")
                ToggleRow(title: "Box art", subtitle: "Downloads covers from libretro-thumbnails. Right-click a game to use your own picture.",
                          isOn: Binding { model.covers.enabled } set: { model.covers.enabled = $0 }, padID: "box-art")
            }

            SettingsGroup(title: "Look") {
                ThemePicker(model: model, selection: $themeRaw)
            }

            SettingsGroup(title: "Library") {
                SettingsRow(title: "Games, BIOS and saves", subtitle: "Application Support › MenuBarEmulator") {
                    Button("Show") { NSWorkspace.shared.open(model.library.root) }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .focusable(false)
                }
                .padFocusable("show-library", cornerRadius: 8) { NSWorkspace.shared.open(model.library.root) }
                SettingsRow(title: "Screenshots", subtitle: "Pictures › Menu Bar Emulator") {
                    Button("Show", action: showScreenshots)
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .focusable(false)
                }
                .padFocusable("show-screenshots", cornerRadius: 8, action: showScreenshots)
                SettingsRow(title: "Add games, BIOS or mod patches") {
                    Button("Add…") { model.importFiles() }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .focusable(false)
                }
                .padFocusable("import", cornerRadius: 8) { model.importFiles() }
            }

            SettingsGroup(title: "About") {
                linkRow("Welcome Tour", symbol: "sparkles", id: "tour") { model.replayOnboarding() }
                linkRow("Credits and Licenses", symbol: "doc.text", id: "credits") { model.sheet = .credits }
                linkRow("Reset to Factory Settings…", symbol: "arrow.counterclockwise", id: "factory-reset", destructive: true) { model.sheet = .reset }
                SettingsRow(title: "Version") { Text(AppInfo.versionLabel).font(.system(size: 12)).foregroundStyle(theme.subtext) }
                SettingsRow(title: "Made by") { Text("Kian").font(.system(size: 12)).foregroundStyle(theme.subtext) }
            }

            Button("Quit Menu Bar Emulator", action: quit)
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .focusable(false)
                .padFocusable("quit", cornerRadius: 15, action: quit)
                .frame(maxWidth: .infinity)
        }
    }

    /// Thank-you note + the two support buttons, first thing in Settings.
    private var supportBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 38, height: 38)
                .background(Circle().fill(theme.accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Thanks for trying the early build").font(theme.display(13.5, .bold))
                Text("Things might break. Feedback and support help a lot.").font(.system(size: 11.5)).foregroundStyle(theme.subtext)
            }
            Spacer(minLength: 6)
            VStack(spacing: 6) {
                Button("Feedback") { model.sheet = .feedback }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .focusable(false)
                    .padFocusable("banner-feedback", cornerRadius: 15) { model.sheet = .feedback }
                Button("Tip ♥") { model.sheet = .tip }
                    .buttonStyle(PillButtonStyle())
                    .focusable(false)
                    .padFocusable("banner-tip", cornerRadius: 15) { model.sheet = .tip }
            }
        }
        .padding(12)
        .card(14)
    }

    private func key(_ action: Controls.Action) -> String { model.controls.key(for: action)?.name ?? "—" }

    private func showScreenshots() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Pictures/Menu Bar Emulator")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    private func quit() {
        model.emulator.stop()
        NSApp.terminate(nil)
    }

    private func linkRow(_ title: String, symbol: String, id: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(destructive ? theme.bad : theme.accent).frame(width: 18)
                Text(title).font(.system(size: 13)).foregroundStyle(destructive ? theme.bad : theme.text)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.subtext)
            }
            .frame(minHeight: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .padFocusable(id, cornerRadius: 8, action: action)
    }
}

/// Theme swatches: the built-in looks, the ones you've made, and "+" to make another.
struct ThemePicker: View {
    let model: AppModel
    @Binding var selection: String
    @Environment(\.theme) private var theme

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 74, maximum: 110), spacing: 8)], spacing: 10) {
            ForEach(model.themes.all, id: \.id) { preview in
                swatch(preview)
            }
            Button(action: newTheme) {
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(theme.subtext.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .overlay(Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.subtext))
                        .frame(height: 46)
                    Text("New Theme").font(.system(size: 11)).foregroundStyle(theme.subtext)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Make your own theme with your colors and a gradient")
            .padFocusable("theme-new", cornerRadius: 11, action: newTheme)
        }
    }

    private func newTheme() { model.sheet = .themeEditor(nil) }

    private func swatch(_ preview: Theme) -> some View {
        let selected = preview.id == selection
        let isCustom = ThemeKind(rawValue: preview.id) == nil
        let choose = { withTransaction(Transaction(animation: nil)) { selection = preview.id } } // instant, like the arcade
        return Button(action: choose) {
            VStack(spacing: 6) {
                ZStack(alignment: .topLeading) {
                    Group {
                        if let gradient = preview.gradient {
                            LinearGradient(colors: gradient, startPoint: preview.diagonal ? .topLeading : .top,
                                           endPoint: preview.diagonal ? .bottomTrailing : .bottom)
                        } else {
                            preview.background
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(preview.text).frame(width: 26, height: 5)
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3).fill(preview.surface).frame(width: 18, height: 18)
                            RoundedRectangle(cornerRadius: 3).fill(preview.accent).frame(width: 18, height: 18)
                        }
                    }
                    .padding(7)
                }
                .frame(height: 46)
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(selected ? theme.accent : theme.hairline, lineWidth: selected ? 2 : 1))
                Text(preview.name)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? theme.text : theme.subtext)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .contextMenu {
            if isCustom {
                Button("Edit…") { model.sheet = .themeEditor(preview.id) }
                Button("Delete", role: .destructive) {
                    model.themes.delete(preview.id)
                    if selection == preview.id { selection = ThemeKind.dark.rawValue }
                }
            }
        }
        .help(isCustom ? "Right-click to edit or delete" : preview.name)
        .accessibilityLabel("\(preview.name) theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .padFocusable("theme-\(preview.id)", cornerRadius: 11, action: choose)
    }
}

/// Every key (click a cap to rebind it; taken keys swap so nothing is left unbound), with the tester on top.
private struct ControlsSettings: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup(title: "Layout", footer: model.controls.layout?.detail ?? "Custom: you've changed some keys. Pick a layout to start over from it.") {
                LayoutChoice(controls: model.controls, padID: "key-layout")
            }
            KeyTester(model: model)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .card(14)
            SettingsGroup(title: "Game buttons") {
                ForEach(Controls.Action.allCases.filter(\.isGameButton)) { action in KeyRow(action: action, controls: model.controls) }
            }
            SettingsGroup(title: "While playing", footer: "Click a key, then press the new one. Esc cancels. The mouse is always the DS stylus.") {
                ForEach(Controls.Action.allCases.filter { !$0.isGameButton }) { action in KeyRow(action: action, controls: model.controls) }
            }
            Button("Reset to Defaults") { model.controls.reset() }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .focusable(false)
                .padFocusable("reset-keys", cornerRadius: 15) { model.controls.reset() }
                .frame(maxWidth: .infinity)
        }
    }
}

private struct KeyRow: View {
    let action: Controls.Action
    let controls: Controls

    var body: some View {
        let waiting = controls.capturing == action
        SettingsRow(title: action.title, subtitle: action.padName) {
            Button(action: toggle) {
                KeyCap(text: waiting ? "Press a key…" : controls.key(for: action)?.name ?? "—", highlighted: waiting)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityLabel("\(action.title): \(controls.key(for: action)?.name ?? "none"). Click to change.")
        }
        .padFocusable("key-\(action.rawValue)", cornerRadius: 8, action: toggle)
    }

    private func toggle() { controls.capturing = controls.capturing == action ? nil : action }
}
