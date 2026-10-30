import SwiftUI

/// First launch: six quick steps. Welcome, add games, pick a shortcut, try the controls, preferences, and a thank-you.
/// Return / A goes on, Esc / B goes back.
struct OnboardingView: View {
    @Bindable var model: AppModel
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ThemeKind.storageKey) private var themeRaw = ThemeKind.dark.rawValue

    private var step: Int { model.onboardingStep }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if step > 0 {
                    Button { model.back() } label: { Label("Back", systemImage: "chevron.left") }
                        .buttonStyle(PillButtonStyle(kind: .quiet))
                        .focusable(false)
                        .transition(.opacity)
                }
                Spacer()
                if step < AppModel.onboardingSteps - 1 {
                    Button("Skip") { model.finishOnboarding() }
                        .buttonStyle(PillButtonStyle(kind: .quiet))
                        .focusable(false)
                }
            }
            .frame(height: 30)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .background(WindowDragArea())

            ZStack {
                page
                    .id(step)
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(x: 40)).combined(with: .scale(scale: 0.98)),
                                                                     removal: .opacity.combined(with: .offset(x: -40))))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 26)

            VStack(spacing: 16) {
                Button(primaryTitle) { model.nextOnboardingStep() }
                    .buttonStyle(PillButtonStyle(large: true))
                    .focusable(false)
                    .padFocusable("onboarding-next", cornerRadius: 24) { model.nextOnboardingStep() }
                PageDots(count: AppModel.onboardingSteps, current: step)
                Text(hint).font(.system(size: 10.5)).foregroundStyle(theme.subtext.opacity(0.8))
            }
            .padding(.bottom, 20)
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.5, dampingFraction: 0.86), value: step)
    }

    private var primaryTitle: String {
        switch step {
        case 0: "Get Started"
        case 1: model.library.roms.isEmpty ? "Skip for Now" : "Continue"
        case AppModel.onboardingSteps - 1: "Start Playing"
        default: "Continue"
        }
    }

    private var hint: String {
        step == 3 ? "Start on a controller (or Return) to go on" : "Return or A to go on · Esc or B to go back"
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case 0: welcome
        case 1: games
        case 2: shortcut
        case 3: controls
        case 4: preferences
        default: thanks
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 24) {
            FloatingConsoles(size: 82)
            VStack(spacing: 10) {
                if AppInfo.isEarlyBuild { EarlyBadge() }
                Text("Handheld classics,\none click away.")
                    .font(theme.display(30, .heavy))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Game Boy, Game Boy Color, Game Boy Advance and DS, living in your menu bar. Click away and your game pauses and saves itself.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.subtext)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 360)
                Text("Made by Kian")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.subtext.opacity(0.8))
            }
        }
    }

    private var games: some View {
        VStack(spacing: 18) {
            title("Add your games", "ROMs, BIOS files, mod patches or a whole folder. They're copied in, so your originals stay where they are.")
            VStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(theme.accent)
                    .symbolEffect(.bounce, value: model.library.roms.count)
                Text("Drop files anywhere on this window").font(theme.display(14, .semibold))
                Button("Choose Files…") { model.importFiles() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .focusable(false)
                    .padFocusable("choose-files", cornerRadius: 15) { model.importFiles() }
            }
            .frame(maxWidth: 360)
            .padding(.vertical, 24)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(theme.subtext.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            }
            if !model.library.roms.isEmpty {
                Label("\(model.library.roms.count) game\(model.library.roms.count == 1 ? "" : "s") ready", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.good)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.library.roms.count)
    }

    private var shortcut: some View {
        VStack(spacing: 16) {
            title("Pick your shortcut", "Press it in any app to pop the emulator out on top of everything. Press it again to put it away.")
            PopOutDemo(shortcut: model.prefs.popOutShortcut)
            ShortcutRecorder(model: model, slot: .popOut, large: true)
            HStack(spacing: 8) {
                Text("Open it under the menu bar icon too:").font(.system(size: 11.5)).foregroundStyle(theme.subtext)
                ShortcutRecorder(model: model, slot: .menuBar)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 16) {
            title("Try the controls", "Pick a layout, then press keys or controller buttons and watch them light up.")
            VStack(spacing: 6) {
                LayoutChoice(controls: model.controls, padID: "tour-layout")
                    .frame(maxWidth: 300)
                Text(model.controls.layout?.detail ?? "Custom keys.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.subtext)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
            }
            KeyTester(model: model)
            HStack(spacing: 14) {
                legend("Move", moveKeys)
                legend("A / B", "\(key(.a)) / \(key(.b))")
                legend("Start", key(.start))
                legend("Fast-forward", key(.fastForward))
            }
            Text("Every key can be changed later in Settings › Keyboard.")
                .font(.system(size: 11))
                .foregroundStyle(theme.subtext)
        }
    }

    private var preferences: some View {
        VStack(spacing: 16) {
            title("Make it yours", "A few choices. All of them are in Settings later.")
            VStack(spacing: 2) {
                ToggleRow(title: "Pause when the window is hidden", subtitle: "Off: games keep running in the background",
                          isOn: Binding { model.prefs.pauseWhenHidden } set: { model.prefs.pauseWhenHidden = $0 }, padID: "pref-pause")
                ToggleRow(title: "Close when I click somewhere else", subtitle: "Off: the menu bar window stays until you close it",
                          isOn: Binding { model.prefs.closeOnClickOutside } set: { model.prefs.closeOnClickOutside = $0 }, padID: "pref-close")
                ToggleRow(title: "Lo-fi music", subtitle: "Chill original tracks. Also at the top of the library",
                          isOn: Binding { model.prefs.lofiOn } set: { model.prefs.lofiOn = $0 }, padID: "pref-lofi")
                ToggleRow(title: "Lo-fi while fast-forwarding", subtitle: "Fills the quiet when you speed a game up",
                          isOn: Binding { model.prefs.lofiSpedUp } set: { model.prefs.lofiSpedUp = $0 }, padID: "pref-lofi-sped-up")
                ToggleRow(title: "Keep lo-fi playing when it's closed", subtitle: "Music carries on after you put the window away",
                          isOn: Binding { model.prefs.lofiInBackground } set: { model.prefs.lofiInBackground = $0 }, padID: "pref-lofi-background")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: 400)
            .card(14)
            ThemePicker(model: model, selection: $themeRaw)
                .frame(maxWidth: 400)
        }
    }

    private var thanks: some View {
        VStack(spacing: 18) {
            Image(systemName: "heart.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color(hex: 0xFF5A7A))
                .frame(width: 72, height: 72)
                .background(Circle().fill(Color(hex: 0xFF5A7A).opacity(0.14)))
                .symbolEffect(.bounce, options: .repeat(2), value: step)
            title("Thanks for trying it", "This is an early build, so some things might break. If something feels off or you have an idea, tell me. Feedback and support are hugely appreciated.")
            HStack(spacing: 10) {
                Button { model.sheet = .feedback } label: { Label("Send Feedback", systemImage: "bubble.left.fill") }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .focusable(false)
                    .padFocusable("thanks-feedback", cornerRadius: 15) { model.sheet = .feedback }
                Button { model.sheet = .tip } label: { Label("Leave a Tip", systemImage: "heart") }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .focusable(false)
                    .padFocusable("thanks-tip", cornerRadius: 15) { model.sheet = .tip }
            }
        }
    }

    // MARK: Pieces

    private func title(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(theme.display(26, .heavy))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(theme.subtext)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func legend(_ action: String, _ key: String) -> some View {
        VStack(spacing: 4) {
            KeyCap(text: key)
            Text(action).font(.system(size: 10.5)).foregroundStyle(theme.subtext)
        }
    }

    private func key(_ action: Controls.Action) -> String { model.controls.key(for: action)?.name ?? "—" }

    /// "Arrows", "WASD", or whatever four keys move.
    private var moveKeys: String {
        let keys = [Controls.Action.up, .left, .down, .right].map(key).joined()
        return keys == "↑←↓→" ? "Arrows" : keys
    }
}

struct PageDots: View {
    let count: Int
    let current: Int
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? theme.accent : theme.subtext.opacity(0.3))
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}
