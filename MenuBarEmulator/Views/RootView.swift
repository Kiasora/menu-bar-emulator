import SwiftUI

/// The current screen (tour, library, game, settings) with blur transitions between them, plus what can appear over any
/// screen: the drop highlight, sheets (feedback, tip, credits, theme editor) and toasts. Fills whatever size the window is.
struct RootView: View {
    @Bindable var model: AppModel
    /// Nil when rendered on its own (tests); otherwise the window reshapes itself as screens change.
    let window: FloatingWindow?
    @AppStorage(ThemeKind.storageKey) private var themeRaw = ThemeKind.dark.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false

    private var theme: Theme { model.themes.theme(id: themeRaw) }

    var body: some View {
        ZStack {
            Group {
                if model.screen == .game {
                    GameView(model: model) // the picture always fills the window; its controls scale themselves
                } else {
                    // Pages keep their design in small windows, just smaller.
                    FitToWindow(design: model.screen == .onboarding ? DesignSize.page : DesignSize.scrollingPage) {
                        switch model.screen {
                        case .onboarding: OnboardingView(model: model)
                        case .settings: SettingsView(model: model)
                        default: LibraryView(model: model)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(model.screen)
            .screenTransition(reduceMotion: reduceMotion)

            FitToWindow(design: model.screen == .game ? DesignSize.gameOverlay
                        : model.screen == .onboarding ? DesignSize.page : DesignSize.scrollingPage) {
                ZStack { overlays }
            }
            .allowsHitTesting(model.sheet != nil)
        }
        // The window's title bar is invisible; without this SwiftUI leaves a gap under it and the game sits off-center.
        .ignoresSafeArea()
        .background { if model.screen == .game { Color.black } else { ThemeBackground() } }
        .foregroundStyle(theme.text)
        .environment(\.theme, theme)
        .environment(model.padFocus)
        .preferredColorScheme(theme.scheme)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.32), value: model.screen)
        .animation(.snappy(duration: 0.3), value: model.panel)
        .animation(.snappy(duration: 0.3), value: model.sheet)
        .animation(.snappy(duration: 0.3), value: model.toast)
        .animation(.easeOut(duration: 0.15), value: isTargeted)
        // Keys are read at the window level, so no control needs keyboard focus (or its blue ring).
        .focusEffectDisabled()
        .dropDestination(for: URL.self) { urls, _ in model.importURLs(urls) } isTargeted: { isTargeted = $0 }
        // Controller / arrow-key navigation: every focusable control reports where it is.
        .onPreferenceChange(PadItemsKey.self) { items in
            MainActor.assumeIsolated { model.padFocus.itemsChanged(items) }
        }
        .onChange(of: model.padScope, initial: true) { model.padFocus.scope = model.padScope }
        // The game runs only on the game screen with nothing over it.
        .onChange(of: model.screen == .game && model.panel == nil && model.sheet == nil, initial: true) { model.emulator.showingGame = $1 }
        .onChange(of: model.windowContent, initial: true) { window?.apply($1) }
        .onChange(of: model.wantsSeparateScreen, initial: true) { window?.updateSeparateScreen() }
        .onChange(of: model.prefs.pauseWhenHidden) { window?.refreshVisibility() }
        .onChange(of: model.screen) { if model.screen != .game { model.panel = nil } }
        .onChange(of: model.emulator.game) { if model.emulator.game == nil && model.screen == .game { model.screen = .library } }
    }

    /// Things that can appear over any screen: the drop highlight, sheets and toasts.
    @ViewBuilder
    private var overlays: some View {
        if isTargeted { dropOverlay.transition(.opacity) }
        if let sheet = model.sheet {
            Color.black.opacity(0.4)
                .onTapGesture { model.sheet = nil }
                .transition(.opacity)
            Group {
                switch sheet {
                case .feedback: FeedbackSheet(model: model)
                case .tip: TipSheet(model: model)
                case .credits: CreditsSheet(model: model)
                case .reset: ResetSheet(model: model)
                case .themeEditor(let id): ThemeEditor(model: model, editingID: id)
                }
            }
            .transition(.scale(scale: 0.94).combined(with: .opacity))
        }

        if let toast = model.toast {
            ToastView(toast: toast)
                .padding(.top, model.screen == .game ? 52 : 14)
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity, alignment: .top)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(toast.id)
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(2.2))
                    model.dismissToast(toast.id)
                }
                .allowsHitTesting(false)
        }
    }

    private var dropOverlay: some View {
        ZStack {
            theme.background.opacity(0.85)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 2.5, dash: [9, 7]))
                .padding(10)
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.on.square.fill").font(.system(size: 36)).foregroundStyle(theme.accent)
                Text("Drop to add to your library").font(theme.display(17, .bold))
                Text("ROMs, BIOS files, mod patches or folders. Drop an image on a game to use it as its picture.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.subtext)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
        }
        .allowsHitTesting(false)
    }
}
