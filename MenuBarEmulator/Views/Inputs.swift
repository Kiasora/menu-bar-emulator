import SwiftUI

/// Click, then press a key combination (needs ⌘, ⌥ or ⌃). Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    let model: AppModel
    let slot: AppModel.ShortcutSlot
    var large = false
    @Environment(\.theme) private var theme
    @State private var pulse = false

    private var shortcut: Shortcut? { slot == .popOut ? model.prefs.popOutShortcut : model.prefs.menuBarShortcut }
    private var recording: Bool { model.recordingShortcut == slot }

    var body: some View {
        Button { model.recordingShortcut = recording ? nil : slot } label: {
            HStack(spacing: large ? 8 : 4) {
                if recording {
                    Text("Press your shortcut…")
                        .font(theme.display(large ? 16 : 12, .semibold))
                        .foregroundStyle(theme.accent)
                        .opacity(pulse ? 0.45 : 1)
                        .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { pulse = true } }
                        .onDisappear { pulse = false }
                } else if let shortcut {
                    ForEach(Array(shortcut.symbols.enumerated()), id: \.offset) { _, symbol in
                        KeyCap(text: symbol, large: large).transition(.scale.combined(with: .opacity))
                    }
                } else {
                    Text(slot == .popOut ? "Set a Shortcut" : "Add a Shortcut")
                        .font(theme.display(large ? 15 : 12, .semibold))
                        .foregroundStyle(theme.subtext)
                }
            }
            .padding(.horizontal, large ? 18 : 8)
            .frame(minWidth: large ? 220 : 110, minHeight: large ? 72 : 30)
            .background(RoundedRectangle(cornerRadius: large ? 18 : 9, style: .continuous).fill(theme.board))
            .overlay {
                RoundedRectangle(cornerRadius: large ? 18 : 9, style: .continuous)
                    .stroke(recording ? theme.accent : theme.hairline, lineWidth: recording ? 2 : 1)
            }
            .contentShape(Rectangle())
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: shortcut)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(recording ? "Press a key with ⌘, ⌥ or ⌃ · Esc cancels · Delete clears" : "Click to change")
        .accessibilityLabel("\(slot == .popOut ? "Pop-out" : "Menu bar") shortcut: \(shortcut?.display ?? "none")")
        .padFocusable("shortcut-\(slot)", cornerRadius: large ? 20 : 11) { model.recordingShortcut = recording ? nil : slot }
    }
}

/// A tiny Mac screen: the shortcut's keys press down and the emulator window springs out of the menu bar icon. Loops.
struct PopOutDemo: View {
    let shortcut: Shortcut?
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase: CaseIterable { case rest, press, open, hold }

    var body: some View {
        PhaseAnimator(reduceMotion ? [Phase.hold] : Phase.allCases) { phase in
            VStack(spacing: 16) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [theme.board, theme.boardAlt], startPoint: .top, endPoint: .bottom))
                    // Menu bar with the controller icon.
                    HStack(spacing: 6) {
                        Capsule().fill(theme.subtext.opacity(0.35)).frame(width: 22, height: 4)
                        Capsule().fill(theme.subtext.opacity(0.25)).frame(width: 30, height: 4)
                        Spacer()
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(phase == .press ? theme.accent : theme.subtext)
                        Capsule().fill(theme.subtext.opacity(0.25)).frame(width: 18, height: 4)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 16)
                    .background(theme.surface.opacity(0.7))
                    // The window, springing out of the icon.
                    let open = phase == .open || phase == .hold
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(theme.surface)
                        .overlay {
                            HStack(spacing: 4) {
                                ForEach([GameSystem.gb, .gba, .nds], id: \.self) { ConsoleArt(system: $0).frame(width: 30, height: 30) }
                            }
                        }
                        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                        .frame(width: 130, height: 80)
                        .scaleEffect(open ? 1 : 0.15, anchor: .topTrailing)
                        .opacity(open ? 1 : 0)
                        .offset(x: open ? 75 : 200, y: open ? 34 : 12)
                }
                .frame(width: 280, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack(spacing: 6) {
                    ForEach(Array((shortcut?.symbols ?? ["?"]).enumerated()), id: \.offset) { _, symbol in
                        KeyCap(text: symbol, highlighted: phase == .press)
                            .scaleEffect(phase == .press ? 0.88 : 1)
                            .offset(y: phase == .press ? 2 : 0)
                    }
                }
            }
        } animation: { phase in
            switch phase {
            case .rest: .easeInOut(duration: 0.5)
            case .press: .spring(response: 0.2, dampingFraction: 0.6)
            case .open: .spring(response: 0.45, dampingFraction: 0.68)
            case .hold: .easeInOut(duration: 1.6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A drawn handheld whose buttons light up as you press keys or controller buttons, so you can see what does what.
struct KeyTester: View {
    let model: AppModel
    @Environment(\.theme) private var theme

    /// Every game button that's held right now, from the keyboard or a controller.
    private var held: Set<Controls.Action> {
        var set = Set(model.testerKeys.compactMap { model.controls.action(for: $0) })
        let pad: [GamepadInput.Button: Controls.Action] = [.up: .up, .down: .down, .left: .left, .right: .right, .a: .a, .b: .b,
                                                           .x: .x, .y: .y, .l: .l, .r: .r, .start: .start, .select: .select,
                                                           .r2: .fastForward, .l2: .rewind]
        for button in model.padButtons { if let action = pad[button] { set.insert(action) } }
        return set
    }

    var body: some View {
        let held = held
        VStack(spacing: 12) {
            ZStack {
                // Shoulders
                HStack {
                    shoulder(.l, held)
                    Spacer()
                    shoulder(.r, held)
                }
                .frame(width: 300)
                .offset(y: -70)
                // Body
                RoundedRectangle(cornerRadius: 40, style: .continuous)
                    .fill(LinearGradient(colors: [theme.surface, theme.boardAlt], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 40, style: .continuous).stroke(theme.hairline, lineWidth: 1))
                    .frame(width: 320, height: 130)
                HStack(spacing: 0) {
                    dpad(held).frame(width: 90)
                    VStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.black.opacity(0.85))
                            .frame(width: 100, height: 64)
                            .overlay(Text(lastLabel(held)).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.85)))
                        HStack(spacing: 10) {
                            pill(.select, held)
                            pill(.start, held)
                        }
                    }
                    faceButtons(held).frame(width: 90)
                }
            }
            .frame(height: 160)
            Text(model.gamepad?.connected.first.map { "\($0) connected. Press anything on it, or on the keyboard." }
                 ?? "Press your keys. Connect a controller and it lights up too.")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.subtext)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Controls tester")
    }

    private func lastLabel(_ held: Set<Controls.Action>) -> String {
        guard let action = Controls.Action.allCases.first(where: held.contains) else { return "Try it!" }
        return action.title.replacingOccurrences(of: " (hold)", with: "")
    }

    private func lit(_ action: Controls.Action, _ held: Set<Controls.Action>) -> Bool { held.contains(action) }

    private func dpad(_ held: Set<Controls.Action>) -> some View {
        ZStack {
            ForEach([Controls.Action.up, .down, .left, .right], id: \.self) { direction in
                let on = lit(direction, held)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(on ? theme.accent : theme.text.opacity(0.75))
                    .frame(width: 22, height: 22)
                    .offset(x: direction == .left ? -20 : direction == .right ? 20 : 0, y: direction == .up ? -20 : direction == .down ? 20 : 0)
                    .scaleEffect(on ? 0.9 : 1)
            }
            Rectangle().fill(theme.text.opacity(0.75)).frame(width: 22, height: 22)
        }
        .animation(.snappy(duration: 0.1), value: held)
    }

    private func faceButtons(_ held: Set<Controls.Action>) -> some View {
        ZStack {
            face(.x, held).offset(y: -22)
            face(.y, held).offset(x: -22)
            face(.a, held).offset(x: 22)
            face(.b, held).offset(y: 22)
        }
        .animation(.snappy(duration: 0.1), value: held)
    }

    private func face(_ action: Controls.Action, _ held: Set<Controls.Action>) -> some View {
        let on = lit(action, held)
        return Circle()
            .fill(on ? theme.accent : theme.text.opacity(0.75))
            .frame(width: 26, height: 26)
            .overlay(Text(action.title).font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(theme.background))
            .scaleEffect(on ? 0.88 : 1)
    }

    private func pill(_ action: Controls.Action, _ held: Set<Controls.Action>) -> some View {
        let on = lit(action, held)
        return Capsule()
            .fill(on ? theme.accent : theme.text.opacity(0.5))
            .frame(width: 30, height: 9)
            .scaleEffect(on ? 0.9 : 1)
            .animation(.snappy(duration: 0.1), value: on)
            .help(action.title)
    }

    private func shoulder(_ action: Controls.Action, _ held: Set<Controls.Action>) -> some View {
        let on = lit(action, held)
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(on ? theme.accent : theme.text.opacity(0.55))
            .frame(width: 70, height: 26)
            // The bottom tucks behind the body, so the label sits in the part that shows.
            .overlay(alignment: .top) {
                Text(action.title).font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(theme.background).padding(.top, 3)
            }
            .offset(y: on ? 3 : 0)
            .animation(.snappy(duration: 0.1), value: on)
    }
}

/// Classic / mGBA / WASD. Nothing's highlighted once a key's been changed by hand.
struct LayoutChoice: View {
    let controls: Controls
    let padID: String

    var body: some View {
        SegmentedChoice(options: Controls.Layout.allCases.map { ($0.title, Optional($0)) }, selection: controls.layout, padID: padID) {
            if let layout = $0 { controls.apply(layout) }
        }
    }
}

/// The sound switches, always at hand: mute everything, lo-fi on/off, and lo-fi while fast-forwarding.
struct LofiToggles: View {
    let model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        let prefs = model.prefs
        let soundOn = model.emulator.soundOn
        HStack(spacing: 0) {
            segment("sound", on: soundOn, label: soundOn ? "Mute everything (M)" : "Turn the sound back on (M)", action: model.emulator.toggleSound) {
                Image(systemName: soundOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            Rectangle().fill(theme.hairline).frame(width: 1, height: 12)
            segment("lofi-music", on: prefs.lofiOn, label: prefs.lofiOn ? "Lo-fi music is on. Click to turn it off" : "Turn lo-fi music on",
                    action: model.toggleLofi) {
                HStack(spacing: 4) {
                    Image(systemName: prefs.lofiOn ? "waveform" : "music.note")
                        .symbolEffect(.variableColor.iterative, isActive: model.lofiVolume > 0)
                    Text("Lo-fi")
                }
            }
            Rectangle().fill(theme.hairline).frame(width: 1, height: 12)
            segment("lofi-sped-up", on: prefs.lofiSpedUp,
                    label: prefs.lofiSpedUp ? "Lo-fi plays while fast-forwarding. Click to stop that" : "Play lo-fi while fast-forwarding",
                    action: model.toggleLofiSpedUp) {
                Image(systemName: "forward.fill")
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(2)
        .background(Capsule().fill(theme.surface.opacity(theme.isDark ? 0.75 : 1)))
        .overlay(Capsule().stroke(theme.hairline, lineWidth: 1))
    }

    private func segment<Content: View>(_ id: String, on: Bool, label: String, action: @escaping () -> Void,
                                        @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .foregroundStyle(on ? theme.accent : theme.subtext)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
        .padFocusable(id, cornerRadius: 10, action: action)
    }
}

/// Fast-forward speed, 1.5× to 16×. A controller's ← → move it too.
struct SpeedSlider: View {
    let emulator: Emulator
    let padID: String
    @Environment(\.theme) private var theme

    private var index: Double { Double(Emulator.speeds.firstIndex(of: emulator.speed) ?? 1) }

    var body: some View {
        HStack(spacing: 8) {
            Text("1.5×").font(.system(size: 10.5)).foregroundStyle(theme.subtext)
            Slider(value: Binding { index } set: { emulator.speed = Emulator.speeds[Int($0.rounded())] },
                   in: 0...Double(Emulator.speeds.count - 1), step: 1)
                .tint(theme.accent)
                .accessibilityLabel("Fast-forward speed")
                .accessibilityValue(emulator.speed.speedLabel)
            Text("16×").font(.system(size: 10.5)).foregroundStyle(theme.subtext)
        }
        .padFocusable(padID, cornerRadius: 8, adjust: step) { step(1) }
    }

    private func step(_ delta: Int) {
        let next = min(max(Int(index) + delta, 0), Emulator.speeds.count - 1)
        emulator.speed = Emulator.speeds[next]
    }
}
