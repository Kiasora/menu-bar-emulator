import AppKit
import Observation

/// App state shared by the window and every screen: which screen is up, panels and sheets, open games, library
/// filter/search/selection, toasts, and where every key and controller button goes.
@Observable
final class AppModel {
    enum Screen: Hashable { case onboarding, library, game, settings }
    enum Panel: Hashable { case menu, states, display, mods, games, help, settings }
    enum Sheet: Hashable { case feedback, tip, credits, reset, themeEditor(String?) }
    enum SettingsPage: Hashable { case main, controls }
    enum LibraryFilter: Hashable { case all, favorites, system(GameSystem) }
    enum ShortcutSlot: Hashable { case popOut, menuBar }

    struct Toast: Equatable {
        let id = UUID()
        let text: String
        let symbol: String
    }

    let library: Library
    let controls: Controls
    let lofi = LofiPlayer()
    /// The window is up and not covered (set by the window). Unlike `emulator.windowVisible`, never true while hidden.
    var windowOnScreen = false
    let display: Display
    let covers: Covers
    let emulator: Emulator
    let prefs: Preferences
    let themes: ThemeStore
    let padFocus = PadFocus()
    let gamepad: GamepadInput?
    @ObservationIgnored let store: UserDefaults

    var screen: Screen
    var panel: Panel? { didSet { if panel == nil { emulatorMenuOpen = false } } }
    var sheet: Sheet?
    var settingsPage: SettingsPage = .main
    var onboardingStep = 0
    var filter: LibraryFilter = .all
    var search = ""
    var isSearching = false
    /// Highlighted game, moved with the arrow keys or a controller.
    var selection: URL?
    /// Set by the library grid so ↑/↓ move a whole row.
    var libraryColumns = 3
    /// Games you've opened, most recent first; switching resumes each exactly where it was.
    private(set) var openGames: [URL] = []
    private(set) var toast: Toast?
    /// The global shortcut being recorded (onboarding or Settings), if any.
    var recordingShortcut: ShortcutSlot? {
        didSet {
            let recording = recordingShortcut != nil
            MainActor.assumeIsolated { HotKeys.suspend(recording) } // so pressing the old shortcut records it instead
        }
    }
    /// The buttons held on a controller right now (the onboarding tester shows them).
    private(set) var padButtons = Set<GamepadInput.Button>()
    /// Keys held right now while the tester is up.
    private(set) var testerKeys = Set<UInt16>()
    var isFloating = false
    var isFullScreen = false
    @ObservationIgnored private var emulatorMenuOpen = false

    // Hooks into the window, set by FloatingWindow.
    @ObservationIgnored var importFiles: () -> Void = {}
    @ObservationIgnored var pickFiles: (_ title: String, _ extensions: [String]) -> [URL] = { _, _ in [] }
    @ObservationIgnored var pickSaveDestination: (_ suggestedName: String) -> URL? = { _ in nil }
    @ObservationIgnored var toggleFullScreen: () -> Void = {}
    @ObservationIgnored var hideWindow: () -> Void = {}
    @ObservationIgnored var popOut: () -> Void = {}
    /// Quits and opens the app again (after a factory reset).
    @ObservationIgnored var relaunch: () -> Void = {}
    @ObservationIgnored var zoomGame: (Int) -> Void = { _ in }
    @ObservationIgnored var isTyping: () -> Bool = { false }
    @ObservationIgnored private var settingsReturn: Screen = .library

    static let maxOpenGames = 6
    static let onboardingSteps = 6

    init(library: Library, controls: Controls, display: Display, covers: Covers, emulator: Emulator,
         prefs: Preferences, themes: ThemeStore, gamepad: GamepadInput?, store: UserDefaults = .standard) {
        self.library = library
        self.controls = controls
        self.display = display
        self.covers = covers
        self.emulator = emulator
        self.prefs = prefs
        self.themes = themes
        self.gamepad = gamepad
        self.store = store
        screen = store.bool(forKey: "MenuBarEmulator.onboarded") ? .library : .onboarding
        openGames = (store.stringArray(forKey: "MenuBarEmulator.openGames") ?? [])
            .map { library.root.appending(path: "ROMs").appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        emulator.onToast = { [weak self] text, symbol in self?.show(text, symbol) }
        emulator.onAppAction = { [weak self] action in self?.appAction(action) }
        gamepad?.onChange = { [weak self] buttons in self?.padChanged(buttons) }
        gamepad?.onConnect = { [weak self] name, connected in
            self?.show(connected ? "\(name) connected" : "\(name) disconnected", "gamecontroller.fill")
        }
        watchLofi()
    }

    // MARK: Lo-fi

    /// How loud the lo-fi should be right now: 0 unless it's on (and the window's up, a game's running, or it's set to
    /// keep playing in the background), or a game's fast-forwarding with the ⏩ switch on. Mute (the speaker at the
    /// top, or M) silences it along with everything else.
    var lofiVolume: Float {
        let playing = emulator.isRunning
        let spedUp = playing && (emulator.fastForward || emulator.holdingFastForward)
        let on = (prefs.lofiOn && (windowOnScreen || playing || prefs.lofiInBackground)) || (prefs.lofiSpedUp && spedUp)
        let inGame = screen == .game || playing
        return on && emulator.soundOn && !(prefs.silentGames && inGame) ? Float(emulator.volume) : 0
    }

    func toggleLofi() {
        prefs.lofiOn.toggle()
        show(prefs.lofiOn ? "Lo-fi on" : prefs.lofiSpedUp ? "Lo-fi off, except while fast-forwarding" : "Lo-fi off",
             prefs.lofiOn ? "music.note" : "speaker.slash.fill")
    }

    func toggleSilentGames() {
        prefs.silentGames.toggle()
        show(prefs.silentGames ? "No sound in games" : "Game sound back on", prefs.silentGames ? "speaker.slash.fill" : "speaker.wave.2.fill")
    }

    func toggleLofiSpedUp() {
        prefs.lofiSpedUp.toggle()
        show(prefs.lofiSpedUp ? "Lo-fi plays while fast-forwarding" : "No lo-fi while fast-forwarding", "forward.fill")
    }

    /// Keeps the lo-fi following `lofiVolume` as fast-forward, the screen, the setting or the sound change.
    private func watchLofi() {
        nonisolated(unsafe) weak let model = self // the change lands back on the main thread before it's used
        let volume = withObservationTracking {
            emulator.silenced = prefs.silentGames
            return lofiVolume
        } onChange: {
            DispatchQueue.main.async { model?.watchLofi() }
        }
        lofi.setVolume(volume)
    }

    // MARK: What's showing

    var currentSystem: GameSystem? { emulator.game.flatMap(GameSystem.init(rom:)) }

    /// What shape the window should be: a resizable page, or the game's picture.
    var windowContent: WindowContent { screen == .game ? .game(picture: pictureSize) : .home }

    /// The game picture's size in pixels: the DS layout, or the core's frame (the system's native size until then).
    var pictureSize: CGSize {
        guard let system = currentSystem else { return CGSize(width: 240, height: 160) }
        if system == .nds { return display.dsLayout().size }
        return emulator.frameSize ?? (system == .gba ? CGSize(width: 240, height: 160) : CGSize(width: 160, height: 144))
    }

    /// The Separate layout puts the other DS screen in a second window.
    var wantsSeparateScreen: Bool { screen == .game && currentSystem == .nds && display.layout == .separate }

    /// The controls tester is on screen (onboarding, or Settings › Keyboard).
    var testerVisible: Bool {
        (screen == .onboarding && onboardingStep == 3 && sheet == nil)
            || (settingsPage == .controls && (screen == .settings || panel == .settings) && sheet == nil)
    }

    /// Which layer the controller / arrow keys navigate.
    var padScope: String { sheet != nil ? "sheet" : panel != nil ? "panel" : "screen" }

    var visibleROMs: [URL] {
        library.roms.filter { rom in
            let matches: Bool = switch filter {
            case .all: true
            case .favorites: library.meta(for: rom).favorite
            case .system(let system): GameSystem(rom: rom) == system
            }
            return matches && (search.isEmpty || rom.gameTitle.localizedCaseInsensitiveContains(search))
        }
    }

    var systemsInLibrary: [GameSystem] {
        GameSystem.allCases.filter { system in library.roms.contains { GameSystem(rom: $0) == system } }
    }

    var hasFavorites: Bool { library.roms.contains { library.meta(for: $0).favorite } }

    /// The filters the library offers right now (All, Favorites if any, then each system you have).
    var filters: [LibraryFilter] {
        [.all] + (hasFavorites ? [.favorites] : []) + systemsInLibrary.map { .system($0) }
    }

    // MARK: Actions

    func play(_ rom: URL) {
        if emulator.game != rom { emulator.play(rom) }
        guard emulator.game == rom else {
            show(emulator.error ?? "Couldn't start that game", "exclamationmark.triangle.fill")
            return
        }
        openGames.removeAll { $0 == rom }
        openGames.insert(rom, at: 0)
        if openGames.count > Self.maxOpenGames { openGames.removeLast(openGames.count - Self.maxOpenGames) }
        saveOpenGames()
        selection = rom
        panel = nil
        sheet = nil
        screen = .game
    }

    /// Closes an open game (its spot is saved, so opening it again resumes).
    func closeGame(_ rom: URL) {
        if emulator.game == rom { emulator.stop() }
        openGames.removeAll { $0 == rom }
        saveOpenGames()
        if screen == .game && emulator.game == nil { screen = .library }
    }

    func remove(_ rom: URL) {
        closeGame(rom)
        if selection == rom { selection = nil }
        covers.removeCustom(rom)
        library.remove(rom)
    }

    func switchToOpenGame(_ index: Int) {
        guard openGames.indices.contains(index) else { return }
        play(openGames[index])
    }

    func back() {
        if recordingShortcut != nil { recordingShortcut = nil; return }
        if controls.capturing != nil { controls.capturing = nil; return }
        if sheet != nil { sheet = nil; return }
        if panel != nil {
            panel = emulatorMenuOpen && panel != .menu ? .menu : nil // panels opened from the game menu go back to it
            return
        }
        switch screen {
        case .game: screen = .library
        case .settings:
            if settingsPage != .main { settingsPage = .main } else { screen = settingsReturn }
        case .library:
            if isSearching || !search.isEmpty {
                search = ""
                isSearching = false
            } else {
                hideWindow()
            }
        case .onboarding:
            if onboardingStep > 0 { onboardingStep -= 1 }
        }
    }

    func openSettings(_ page: SettingsPage = .main) {
        settingsPage = page
        if screen == .game { // stay in the game: settings slide up over it
            panel = .settings
            return
        }
        if screen != .settings { settingsReturn = screen == .onboarding ? .library : screen }
        panel = nil
        screen = .settings
    }

    func togglePanel(_ new: Panel) {
        if new == .menu { emulatorMenuOpen = panel != .menu }
        panel = panel == new ? nil : new
    }

    /// From the in-game menu: open a panel, and come back to the menu when it closes.
    func openFromMenu(_ new: Panel) {
        emulatorMenuOpen = true
        panel = new
    }

    func nextOnboardingStep() {
        if onboardingStep < Self.onboardingSteps - 1 { onboardingStep += 1 } else { finishOnboarding() }
    }

    func finishOnboarding() {
        recordingShortcut = nil
        store.set(true, forKey: "MenuBarEmulator.onboarded")
        screen = .library
    }

    /// Back to the first-launch state: every setting, control, shortcut, theme, window size, open game and the tour.
    /// With `eraseLibrary`, games, saves, states and pictures go to the Trash too. Then the app restarts fresh.
    func factoryReset(eraseLibrary: Bool) {
        emulator.stop()
        sheet = nil
        panel = nil
        openGames = []
        selection = nil
        FactoryReset.clearSettings(in: store)
        if eraseLibrary { library.eraseAll() }
        relaunch()
    }

    func replayOnboarding() {
        onboardingStep = 0
        panel = nil
        screen = .onboarding
    }

    func show(_ text: String, _ symbol: String) {
        toast = Toast(text: text, symbol: symbol)
    }

    func dismissToast(_ id: UUID) {
        if toast?.id == id { toast = nil }
    }

    /// Files dropped on the window or icon, or picked in Import.
    @discardableResult
    func importURLs(_ urls: [URL]) -> Bool {
        let result = library.importFiles(urls)
        if let summary = result.summary {
            show(summary, result.count > 0 ? "checkmark.circle.fill" : "info.circle.fill")
        } else if !urls.isEmpty {
            show("Nothing new to add", "info.circle")
        }
        if selection == nil { selection = result.games.first }
        return result.count > 0
    }

    func applyPatch(to rom: URL) {
        guard let patch = pickFiles("Choose a mod patch for \(rom.gameTitle)", Array(Library.patchExtensions)).first else { return }
        do {
            let modded = try library.applyPatch(patch, to: rom)
            selection = modded
            show("Added \(modded.gameTitle)", "wand.and.stars")
        } catch Patcher.PatchError.wrongGame {
            show("That patch is for a different game or version", "exclamationmark.triangle.fill")
        } catch {
            show("Couldn't apply that patch", "exclamationmark.triangle.fill")
        }
    }

    func choosePicture(for rom: URL) {
        guard let image = pickFiles("Choose a picture for \(rom.gameTitle)", Array(Covers.imageExtensions)).first else { return }
        setPicture(image, for: rom)
    }

    @discardableResult
    func setPicture(_ image: URL, for rom: URL) -> Bool {
        let ok = covers.setCustom(image, for: rom)
        show(ok ? "New picture for \(rom.gameTitle)" : "Couldn't use that image", ok ? "photo.fill" : "exclamationmark.triangle.fill")
        return ok
    }

    func exportSave(for rom: URL) {
        guard let destination = pickSaveDestination("\(rom.gameTitle).sav") else { return }
        do {
            try emulator.exportSave(for: rom, to: destination)
            show("Save exported", "square.and.arrow.up.fill")
        } catch {
            show("This game has no save yet", "tray")
        }
    }

    func importSave(for rom: URL) {
        guard let source = pickFiles("Choose a save file (.sav, .srm) for \(rom.gameTitle)", ["sav", "srm", "dsv", "bin"]).first else { return }
        do {
            try emulator.importSave(from: source, for: rom)
            show("Save imported", "square.and.arrow.down.fill")
        } catch {
            show("Couldn't import that save", "exclamationmark.triangle.fill")
        }
    }

    private func saveOpenGames() {
        store.set(openGames.map(\.lastPathComponent), forKey: "MenuBarEmulator.openGames")
    }

    private func appAction(_ action: Controls.Action) {
        switch action {
        case .swapScreens:
            guard currentSystem == .nds else { return show("Swapping screens is for DS games", "rectangle.2.swap") }
            display.swap.toggle()
            if display.layout == .single {
                show(display.swap ? "Showing the touch screen" : "Showing the top screen", "rectangle.2.swap")
            } else {
                show("Screens swapped", "arrow.up.arrow.down")
            }
        case .help:
            togglePanel(.help)
        default:
            break
        }
    }

    func cycleFilter(_ delta: Int) {
        let all = filters
        guard let index = all.firstIndex(of: filter) else { filter = .all; return }
        filter = all[(index + delta + all.count) % all.count]
    }

    // MARK: Keys

    /// Every key the window gets comes here first. Returns true when it was used.
    func handle(_ event: NSEvent) -> Bool {
        let down = event.type == .keyDown
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if let slot = recordingShortcut {
            guard down else { return true }
            recordShortcut(event, into: slot)
            return true
        }
        if down, flags == [.command, .control], chars == "f" {
            toggleFullScreen()
            return true
        }
        if controls.capturing != nil {
            if down { controls.capture(event) }
            return true
        }
        if testerVisible { // the controls tester lights up whatever's held
            if down { testerKeys.insert(event.keyCode) } else { testerKeys.remove(event.keyCode) }
        }
        if flags.contains(.command) { return down && command(chars) }
        if isTyping() {
            if down && event.keyCode == Controls.escape { back(); return true }
            return false
        }
        if down && event.keyCode == Controls.escape {
            back()
            return true
        }
        switch screen {
        case .game where panel == nil && sheet == nil:
            if flags.contains(.control) && event.keyCode == 48 { // ⌃Tab: previous game
                if down { switchToOpenGame(1) }
                return true
            }
            return emulator.handleKey(event.keyCode, down: down, isRepeat: down && event.isARepeat)
        case .library where sheet == nil && panel == nil:
            return down && libraryKey(event)
        default:
            return down && navigationKey(event)
        }
    }

    /// Arrow keys / Return / Space move through and press controls in menus (same as a controller).
    private func navigationKey(_ event: NSEvent) -> Bool {
        padFocus.scope = padScope
        // On the onboarding tester the arrow keys are for trying out, not for moving around.
        if screen == .onboarding && onboardingStep == 3 && [123, 124, 125, 126].contains(event.keyCode) { return true }
        switch event.keyCode {
        case 126: padFocus.move(.up)
        case 125: padFocus.move(.down)
        case 123: padFocus.horizontal(-1)
        case 124: padFocus.horizontal(1)
        case 36, 76, 49:
            if padFocus.activate() { return true }
            guard screen == .onboarding, panel == nil, sheet == nil, event.keyCode != 49 else { return false }
            nextOnboardingStep()
        default: return false
        }
        return true
    }

    private func recordShortcut(_ event: NSEvent, into slot: ShortcutSlot) {
        if event.keyCode == Controls.escape { recordingShortcut = nil; return }
        if event.keyCode == 51 || event.keyCode == 117 { // Delete clears it
            if slot == .popOut { prefs.popOutShortcut = nil } else { prefs.menuBarShortcut = nil }
            recordingShortcut = nil
            return
        }
        guard let shortcut = Shortcut(event: event) else {
            show("Add ⌘, ⌥ or ⌃ so it doesn't fire while typing", "command")
            return
        }
        let other = slot == .popOut ? prefs.menuBarShortcut : prefs.popOutShortcut
        guard shortcut != other else { return show("That one's already used", "exclamationmark.triangle.fill") }
        if slot == .popOut { prefs.popOutShortcut = shortcut } else { prefs.menuBarShortcut = shortcut }
        recordingShortcut = nil
        show("Shortcut set: \(shortcut.display)", "command")
    }

    private func command(_ chars: String) -> Bool {
        switch chars {
        case ",": openSettings(); return true
        case "o": importFiles(); return true
        case "f":
            guard screen == .library else { return false }
            isSearching = true
            return true
        case "=", "+", "-", "0":
            guard screen == .game else { return false }
            zoomGame(chars == "0" ? 0 : chars == "-" ? -1 : 1)
            return true
        default:
            guard let number = Int(chars), (1...Self.maxOpenGames).contains(number), openGames.count >= number else { return false }
            switchToOpenGame(number - 1)
            return true
        }
    }

    private func libraryKey(_ event: NSEvent) -> Bool {
        let roms = visibleROMs
        switch event.keyCode {
        case 123: moveSelection(-1, in: roms)
        case 124: moveSelection(1, in: roms)
        case 125: moveSelection(libraryColumns, in: roms)
        case 126: moveSelection(-libraryColumns, in: roms)
        case 36, 76:
            guard let rom = selection.flatMap({ roms.contains($0) ? $0 : nil }) ?? roms.first else { return false }
            play(rom)
        default:
            // Type to search.
            guard let typed = event.characters, typed.count == 1, let character = typed.first,
                  character.isLetter || character.isNumber else { return false }
            isSearching = true
            search.append(character)
        }
        return true
    }

    func moveSelection(_ delta: Int, in roms: [URL]) {
        guard !roms.isEmpty else { return }
        guard let current = selection.flatMap({ roms.firstIndex(of: $0) }) else {
            selection = roms.first
            return
        }
        selection = roms[min(max(current + delta, 0), roms.count - 1)]
    }

    // MARK: Controller

    /// In a game the controller plays it (Home, a stick click or Start+Select opens the game menu); in the library
    /// it moves the highlight; everywhere else it moves the focus ring. B is always back.
    func padChanged(_ buttons: Set<GamepadInput.Button>) {
        let newlyPressed = buttons.subtracting(padButtons)
        padButtons = buttons
        if screen == .game && panel == nil && sheet == nil {
            let menuCombo = buttons.isSuperset(of: [.start, .select]) && buttons.isDisjoint(with: [.a, .b])
            if !newlyPressed.isDisjoint(with: [.home, .r3, .l3]) || (menuCombo && !newlyPressed.isDisjoint(with: [.start, .select])) {
                emulator.setPad([])
                padFocus.visible = true
                togglePanel(.menu)
                return
            }
            emulator.setPad(buttons)
            return
        }
        emulator.setPad([])
        for button in newlyPressed { navigate(button) }
    }

    private func navigate(_ button: GamepadInput.Button) {
        // On the onboarding tester the controller lights things up; only Start goes on and Select goes back.
        if screen == .onboarding && onboardingStep == 3 && sheet == nil {
            if button == .start { nextOnboardingStep() }
            if button == .select { back() }
            return
        }
        if screen == .library && panel == nil && sheet == nil {
            let roms = visibleROMs
            switch button {
            case .left: moveSelection(-1, in: roms)
            case .right: moveSelection(1, in: roms)
            case .up: moveSelection(-libraryColumns, in: roms)
            case .down: moveSelection(libraryColumns, in: roms)
            case .a, .start: if let rom = selection.flatMap({ roms.contains($0) ? $0 : nil }) ?? roms.first { play(rom) }
            case .x: if let rom = selection { library.toggleFavorite(rom) }
            case .y: openSettings()
            case .l: cycleFilter(-1)
            case .r: cycleFilter(1)
            case .b: back()
            default: break
            }
            return
        }
        padFocus.scope = padScope
        switch button {
        case .up: padFocus.move(.up)
        case .down: padFocus.move(.down)
        case .left: padFocus.horizontal(-1)
        case .right: padFocus.horizontal(1)
        case .a:
            if padFocus.activate() { return }
            if screen == .onboarding && panel == nil && sheet == nil { nextOnboardingStep() } else { padFocus.move(.down) }
        case .b: back()
        case .start:
            if screen == .onboarding { nextOnboardingStep() } else if panel != nil && screen == .game { panel = nil }
        case .home, .r3, .l3:
            if screen == .game { togglePanel(.menu) }
        case .l: if screen == .onboarding { back() }
        case .r: if screen == .onboarding { nextOnboardingStep() }
        default: break
        }
    }
}

