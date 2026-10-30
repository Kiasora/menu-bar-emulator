import AppKit
import SwiftUI
import Carbon.HIToolbox

/// What shape the window takes: a freely resizable page (library, settings, onboarding), or a game's picture
/// (aspect locked, sized in multiples of its native resolution).
enum WindowContent: Equatable {
    case home
    case game(picture: CGSize)
}

/// The one emulator window. The menu bar icon shows it anchored under the icon (closes when you click away, like a
/// popover); ⌥P shows it floating wherever you last left it, above every app including fullscreen ones.
/// The game runs only while the window is actually on screen.
@MainActor
final class FloatingWindow: NSObject, NSWindowDelegate {
    enum Mode { case menuBar, floating }

    static let defaultHomeSize = CGSize(width: 460, height: 620)
    static let minHomeSize = CGSize(width: 380, height: 480)

    let model: AppModel
    private(set) var mode: Mode = .floating
    private(set) var isFullScreen = false
    private var content: WindowContent = .home
    private var frameBeforeFullScreen: NSRect?
    private var statusItem: NSStatusItem?
    private let iconDrop = IconDropTarget()
    private var keepOpen = false // while a file picker is up, the menu bar window mustn't close
    private var hideGeneration = 0 // a show() during the fade-out cancels the pending orderOut
    /// The other DS screen in its own window (Separate layout).
    private var screenPanel: TouchScreenPanel?
    private let store: UserDefaults
    private lazy var panel = makePanel()
    /// The screen `show` is opening on, until the window's actually there (`panel.screen` still says the old one).
    private var openingScreen: NSScreen?
    /// The screen being opened on, else the one the window's on.
    private var currentScreen: NSScreen? { openingScreen ?? panel.screen ?? NSScreen.main }

    init(model: AppModel, store: UserDefaults = .standard) {
        self.model = model
        self.store = store
        super.init()
        model.importFiles = { [weak self] in self?.importWithPanel() }
        model.pickFiles = { [weak self] title, extensions in self?.pickFiles(title: title, extensions: extensions) ?? [] }
        model.toggleFullScreen = { [weak self] in self?.toggleFullScreen() }
        model.hideWindow = { [weak self] in self?.hide() }
        model.popOut = { [weak self] in self?.show(.floating) }
        model.relaunch = { [weak self] in self?.relaunchApp() }
        model.zoomGame = { [weak self] step in self?.zoom(step) }
        model.isTyping = { [weak self] in self?.panel.firstResponder is NSTextView }
        model.pickSaveDestination = { [weak self] name in self?.pickSaveDestination(name) }
    }

    // MARK: - Setup

    /// Creates the menu bar icon, the ⌥P hotkey and the key handling. First launch opens straight into the tour.
    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: AppInfo.name)
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked)
            button.toolTip = "\(AppInfo.name) (⌥P)"
            // Files can be dropped straight on the icon; NSWindow forwards drag events to its delegate.
            iconDrop.onDrop = { [weak self] urls in
                self?.model.importURLs(urls)
                self?.show(.menuBar)
            }
            button.window?.registerForDraggedTypes([.fileURL])
            button.window?.delegate = iconDrop
        }
        statusItem = item

        registerShortcuts()
        model.prefs.onShortcutsChanged = { [weak self] in self?.registerShortcuts() }

        // Clicking with the mouse hides the controller focus ring (it comes back with the next D-pad press).
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if self?.model.padFocus.visible == true { self?.model.padFocus.hide() }
            return event
        }

        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, event.window === panel || (screenPanel != nil && event.window === screenPanel) else { return event }
            return model.handle(event) ? nil : event
        }

        if model.screen == .onboarding {
            DispatchQueue.main.async { self.show(.floating) }
        }
    }

    /// The two global shortcuts from Preferences: pop out (floating) and open under the menu bar icon.
    func registerShortcuts() {
        HotKeys.set(model.prefs.popOutShortcut, for: .popOut) { [weak self] in self?.toggle(.floating) }
        HotKeys.set(model.prefs.menuBarShortcut, for: .menuBar) { [weak self] in self?.toggle(.menuBar) }
        statusItem?.button?.toolTip = AppInfo.name + (model.prefs.popOutShortcut.map { " (\($0.display))" } ?? "")
    }

    /// The game keeps running while hidden when "Pause when hidden" is off.
    func refreshVisibility() {
        let onScreen = panel.isVisible && panel.occlusionState.contains(.visible)
        model.windowOnScreen = onScreen
        model.emulator.windowVisible = !model.prefs.pauseWhenHidden || onScreen
    }

    // MARK: - Sizes

    /// The library/settings window size you last left it at. Never smaller than the minimum, even if a bad size got saved.
    private var homeSize: CGSize {
        get { Self.atLeast(store.string(forKey: "MenuBarEmulator.homeSize").map(NSSizeFromString) ?? Self.defaultHomeSize, Self.minHomeSize) }
        set { store.set(NSStringFromSize(Self.atLeast(newValue, Self.minHomeSize)), forKey: "MenuBarEmulator.homeSize") }
    }

    static func atLeast(_ size: CGSize, _ minimum: CGSize) -> CGSize {
        CGSize(width: max(size.width, minimum.width), height: max(size.height, minimum.height))
    }

    /// The window itself (for tests).
    var panelWindow: NSWindow { panel }

    /// The smallest the window may be for what's showing.
    func minimumSize(for content: WindowContent) -> CGSize {
        switch content {
        case .home: return Self.minHomeSize
        case .game(let picture):
            let scale = Self.minScale(for: picture)
            return CGSize(width: (picture.width * scale).rounded(.up), height: (picture.height * scale).rounded(.up))
        }
    }

    /// Every resize goes through here, so the window can never get smaller than its minimum (and games keep their shape),
    /// whatever AppKit's own limits do.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === panel, !isFullScreen else { return frameSize }
        let minimum = minimumSize(for: content)
        switch content {
        case .home:
            return Self.atLeast(frameSize, minimum)
        case .game(let picture):
            let width = max(frameSize.width, minimum.width)
            return NSSize(width: width, height: (width * picture.height / picture.width).rounded())
        }
    }

    static func defaultScale(for system: GameSystem) -> Double {
        switch system {
        case .gb, .gbc: 3
        case .gba: 2
        case .nds: 1.5
        }
    }

    func gameScale(for system: GameSystem) -> Double {
        let saved = store.double(forKey: "MenuBarEmulator.scale.\(system.rawValue)")
        return saved > 0 ? saved : Self.defaultScale(for: system)
    }

    private func setGameScale(_ scale: Double, for system: GameSystem) {
        store.set(scale, forKey: "MenuBarEmulator.scale.\(system.rawValue)")
    }

    /// Smallest scale that still leaves room for the controls (and never below 1×).
    static func minScale(for picture: CGSize) -> Double {
        max(1, 330 / picture.width, 280 / picture.height)
    }

    static func clampScale(_ scale: Double, picture: CGSize, screen: CGSize) -> Double {
        let minimum = minScale(for: picture)
        let maximum = max(minimum, min(screen.width * 0.94 / picture.width, screen.height * 0.94 / picture.height))
        return min(max(scale, minimum), maximum)
    }

    /// Close to a whole number = snap to it, so every pixel is the same size.
    static func snapped(_ scale: Double) -> Double {
        let whole = scale.rounded()
        return whole >= 1 && abs(scale - whole) / whole < 0.05 ? whole : scale
    }

    private var screenSize: CGSize {
        currentScreen?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
    }

    private func contentSize(for content: WindowContent) -> CGSize {
        switch content {
        case .home:
            let size = homeSize
            return CGSize(width: min(size.width, screenSize.width * 0.94), height: min(size.height, screenSize.height * 0.94))
        case .game(let picture):
            let system = model.currentSystem ?? .gba
            let scale = Self.clampScale(gameScale(for: system), picture: picture, screen: screenSize)
            return CGSize(width: (picture.width * scale).rounded(), height: (picture.height * scale).rounded())
        }
    }

    /// Reshapes the window for what's showing (library ↔ game, DS layout changes…), animated.
    func apply(_ new: WindowContent, animated: Bool = true) {
        content = new
        guard !isFullScreen else { return }
        switch new {
        case .home:
            panel.contentResizeIncrements = NSSize(width: 1, height: 1) // free resize (clears the aspect lock)
        case .game(let picture):
            panel.contentAspectRatio = picture
        }
        panel.contentMinSize = minimumSize(for: new)
        guard panel.isVisible else { return }
        setFrame(frame(for: contentSize(for: new)), animated: animated)
    }

    /// ⌘+ / ⌘− step the game size by half a size, ⌘0 goes back to the default.
    func zoom(_ step: Int) {
        guard case .game(let picture) = content, let system = model.currentSystem else { return }
        let current = gameScale(for: system)
        var next = step == 0 ? Self.defaultScale(for: system) : step > 0 ? (current * 2 + 1).rounded(.down) / 2 : (current * 2 - 1).rounded(.up) / 2
        next = Self.clampScale(next, picture: picture, screen: screenSize)
        setGameScale(next, for: system)
        apply(content)
        model.show("Size \(next.speedLabel)", "arrow.up.left.and.arrow.down.right")
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard !isFullScreen, let size = panel.contentView?.bounds.size else { return }
        switch content {
        case .home:
            homeSize = size // clamped to the minimum on the way in
        case .game(let picture):
            guard let system = model.currentSystem else { return }
            let scale = size.width / picture.width
            let snapped = Self.snapped(scale)
            setGameScale(snapped, for: system)
            if snapped != scale { apply(content) }
        }
        if mode == .floating { saveFloatingFrame() }
    }

    func windowDidMove(_ notification: Notification) {
        if mode == .floating && !isFullScreen && panel.isVisible { saveFloatingFrame() }
    }

    /// Auto-pause: covered, hidden or on another Space = not visible (unless "Pause when hidden" is off).
    func windowDidChangeOcclusionState(_ notification: Notification) {
        refreshVisibility()
    }

    // MARK: - Showing and hiding

    @objc private func statusItemClicked() { toggle(.menuBar) }

    func toggle(_ requested: Mode) {
        if isFullScreen {
            exitFullScreen()
            if requested == .menuBar { show(.menuBar) }
            return
        }
        if panel.isVisible && mode == requested {
            hide()
        } else {
            show(requested)
        }
    }

    func show(_ requested: Mode) {
        hideGeneration += 1
        if panel.isVisible && mode == .floating { saveFloatingFrame() }
        let wasVisible = panel.isVisible
        // Open on the screen you're using: the menu bar you clicked (every display has one), or the pointer's screen.
        openingScreen = Self.screen(at: NSEvent.mouseLocation) ?? NSScreen.main
        defer { openingScreen = nil }
        mode = requested
        model.isFloating = requested == .floating
        apply(content, animated: false)
        let size = contentSize(for: content)
        let target: NSRect
        switch requested {
        case .menuBar:
            target = anchoredFrame(size)
        case .floating:
            target = floatingFrame(size)
        }
        panel.setFrame(clamped(target), display: true)
        // No NSApp.activate(): the panel takes keys without pulling you out of a fullscreen Space.
        if !wasVisible && !reduceMotion {
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.makeKeyAndOrderFront(nil)
        }
        updateSeparateScreen()
    }

    func hide() {
        screenPanel?.orderOut(nil)
        if isFullScreen { exitFullScreen() }
        if mode == .floating { saveFloatingFrame() }
        guard !reduceMotion else { return panel.orderOut(nil) }
        hideGeneration += 1
        let generation = hideGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.hideGeneration else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        }
    }

    // MARK: - File pickers

    func importWithPanel() {
        let urls = pickFiles(title: "Import ROMs, BIOS files, mod patches or a folder", extensions: nil)
        if !urls.isEmpty { model.importURLs(urls) }
    }

    private func pickSaveDestination(_ name: String) -> URL? {
        let picker = NSSavePanel()
        picker.nameFieldStringValue = name
        picker.message = "Export the in-game save"
        keepOpen = true
        NSApp.activate()
        let result = picker.runModal()
        keepOpen = false
        show(mode)
        return result == .OK ? picker.url : nil
    }

    private func pickFiles(title: String, extensions: [String]?) -> [URL] {
        let picker = NSOpenPanel()
        picker.message = title
        picker.prompt = "Import"
        picker.allowsMultipleSelection = extensions == nil
        picker.canChooseDirectories = extensions == nil
        if let extensions { picker.allowedContentTypes = extensions.compactMap { .init(filenameExtension: $0) } }
        keepOpen = true
        NSApp.activate()
        let result = picker.runModal()
        keepOpen = false
        show(mode)
        return result == .OK ? picker.urls : []
    }

    // MARK: - Full screen

    /// Fills the screen, above everything; again to restore.
    func toggleFullScreen() {
        if isFullScreen { exitFullScreen(); return }
        if !panel.isVisible { show(.floating) }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        if mode == .floating { saveFloatingFrame() }
        frameBeforeFullScreen = panel.frame
        mode = .floating
        model.isFloating = true
        isFullScreen = true
        model.isFullScreen = true
        panel.contentResizeIncrements = NSSize(width: 1, height: 1)
        panel.level = .statusBar
        setFrame(screen.frame, animated: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func exitFullScreen() {
        isFullScreen = false
        model.isFullScreen = false
        panel.level = .floating
        if let before = frameBeforeFullScreen { panel.setFrame(before, display: true) }
        apply(content)
    }

    // MARK: - Frames

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func frame(for size: CGSize) -> NSRect {
        switch mode {
        case .menuBar: return anchoredFrame(size)
        case .floating:
            // Grow and shrink from the top-left corner, like a normal window.
            return clamped(NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height))
        }
    }

    private func setFrame(_ frame: NSRect, animated: Bool) {
        guard animated, !reduceMotion, panel.isVisible else { return panel.setFrame(frame, display: true) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func anchoredFrame(_ size: CGSize) -> NSRect {
        guard let screen = currentScreen else { return centeredFrame(size) }
        var icon: NSRect?
        var iconScreen = screen.frame
        if let button = statusItem?.button, let window = button.window {
            icon = window.convertToScreen(button.convert(button.bounds, to: nil))
            iconScreen = window.screen?.frame ?? screen.frame
        }
        return Self.anchored(size, icon: icon, iconScreen: iconScreen, screen: screen.frame, visible: screen.visibleFrame)
    }

    /// Just under the menu bar icon on `screen`. Every display has its own menu bar with the icon the same distance
    /// from its right edge, so the icon's spot on whichever screen AppKit reports carries over.
    static func anchored(_ size: CGSize, icon: NSRect?, iconScreen: NSRect, screen: NSRect, visible: NSRect) -> NSRect {
        let midX = icon.map { screen.maxX - (iconScreen.maxX - $0.midX) } ?? visible.maxX - size.width / 2 - 8
        let x = min(max(midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        return NSRect(x: x, y: visible.maxY - size.height - 6, width: size.width, height: size.height)
    }

    /// Where you last left the floating window. If that was on another screen, the same spot on this one.
    private func floatingFrame(_ size: CGSize) -> NSRect {
        guard let saved = savedFloatingFrame(), let screen = currentScreen,
              let home = Self.screen(at: NSPoint(x: saved.midX, y: saved.midY)) // nil: that screen's unplugged
        else { return centeredFrame(size) }
        let frame = NSRect(x: saved.minX, y: saved.maxY - size.height, width: size.width, height: size.height)
        return Self.moved(frame, from: home.visibleFrame, to: screen.visibleFrame)
    }

    /// `frame` moved from one screen to another, the same distance from the top-left corner.
    static func moved(_ frame: NSRect, from: NSRect, to: NSRect) -> NSRect {
        frame.offsetBy(dx: to.minX - from.minX, dy: to.maxY - from.maxY)
    }

    static func screen(at point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    private func centeredFrame(_ size: CGSize) -> NSRect {
        let screen = currentScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Keeps the window on screen after it grows.
    private func clamped(_ frame: NSRect) -> NSRect {
        guard let screen = currentScreen?.visibleFrame else { return frame }
        var f = frame
        f.origin.x = min(max(f.minX, screen.minX), screen.maxX - f.width)
        f.origin.y = min(max(f.minY, screen.minY), screen.maxY - f.height)
        return f
    }

    private func saveFloatingFrame() {
        guard !isFullScreen else { return }
        store.set(NSStringFromRect(panel.frame), forKey: "MenuBarEmulator.floatingFrame")
    }

    private func savedFloatingFrame() -> NSRect? {
        store.string(forKey: "MenuBarEmulator.floatingFrame").map(NSRectFromString)
    }

    /// Opens a fresh copy of the app and quits this one (used by Reset to Factory Settings).
    private func relaunchApp() {
        HotKeys.suspend(true) // free ⌥P (or whatever) so the new copy can take it
        screenPanel?.orderOut(nil)
        panel.orderOut(nil)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error { NSLog("Relaunch failed: \(error)") }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: - Separate DS screen

    /// Shows the second screen window while a DS game uses the Separate layout and the main window is up.
    func updateSeparateScreen() {
        guard panel.isVisible, model.wantsSeparateScreen else {
            screenPanel?.orderOut(nil)
            return
        }
        let second = screenPanel ?? makeScreenPanel()
        screenPanel = second
        guard !second.isVisible else { return }
        second.setFrame(separateScreenFrame(), display: true)
        second.orderFront(nil)
    }

    /// Where it was left, or next to the main window (right side if there's room, else left).
    private func separateScreenFrame() -> NSRect {
        if let saved = store.string(forKey: "MenuBarEmulator.separateFrame").map(NSRectFromString), saved.width > 0 {
            return clamped(saved)
        }
        let scale = gameScale(for: .nds)
        let size = CGSize(width: Display.screen.width * scale, height: Display.screen.height * scale)
        let main = panel.frame
        let screen = (panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var frame = NSRect(x: main.maxX + 12, y: main.maxY - size.height, width: size.width, height: size.height)
        if frame.maxX > screen.maxX { frame.origin.x = main.minX - 12 - size.width }
        return clamped(frame)
    }

    private func makeScreenPanel() -> TouchScreenPanel {
        let second = TouchScreenPanel(
            contentRect: NSRect(origin: .zero, size: Display.screen),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        second.titleVisibility = .hidden
        second.titlebarAppearsTransparent = true
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            second.standardWindowButton(button)?.isHidden = true
        }
        second.level = .statusBar // above the main window, even in full screen
        second.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        second.hidesOnDeactivate = false
        second.isReleasedWhenClosed = false
        second.backgroundColor = .black
        second.contentAspectRatio = Display.screen
        second.contentMinSize = Display.screen
        let hosting = NSHostingView(rootView: SeparateScreenView(model: model))
        hosting.sizingOptions = []
        second.contentView = hosting
        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(screenPanelMoved), name: name, object: second)
        }
        return second
    }

    @objc private func screenPanelMoved() {
        guard let second = screenPanel, second.isVisible else { return }
        store.set(NSStringFromRect(second.frame), forKey: "MenuBarEmulator.separateFrame")
    }

    // MARK: - Panel

    private func makePanel() -> EmulatorPanel {
        let panel = EmulatorPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultHomeSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = Self.minHomeSize
        panel.backgroundColor = .black
        let hosting = NSHostingView(rootView: RootView(model: model, window: self))
        hosting.sizingOptions = [] // the window decides its size, not SwiftUI's ideal size
        panel.contentView = hosting
        panel.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(panelResignedKey), name: NSWindow.didResignKeyNotification, object: panel)
        return panel
    }

    /// In menu bar mode it behaves like a popover: click anywhere else and it closes (if that's turned on).
    /// Our own windows taking focus (a file picker, the color picker) don't count.
    @objc private func panelResignedKey() {
        guard mode == .menuBar, !keepOpen, !isFullScreen, model.prefs.closeOnClickOutside else { return }
        DispatchQueue.main.async { [weak self] in
            // Still key, or another window of ours took focus: stay. Another app took focus: close.
            guard let self, !self.panel.isKeyWindow, NSApp.keyWindow == nil else { return }
            self.hide()
        }
    }
}

final class EmulatorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The Separate layout's second window. Never takes keyboard focus, so the keys keep going to the game
/// (and the menu bar window doesn't close when you tap the touch screen).
final class TouchScreenPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Receives files dropped on the menu bar icon.
private final class IconDropTarget: NSObject, NSWindowDelegate {
    var onDrop: (([URL]) -> Void)?

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        onDrop?(urls)
        return true
    }
}
