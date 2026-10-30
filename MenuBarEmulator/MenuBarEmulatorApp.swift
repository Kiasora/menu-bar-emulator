import SwiftUI

@main
struct MenuBarEmulatorApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    // Everything lives in one AppKit panel (see FloatingWindow); SwiftUI only needs a scene.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: FloatingWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let library = Library()
        let controls = Controls()
        let model = AppModel(library: library, controls: controls, display: Display(), covers: Covers(library: library),
                             emulator: Emulator(library: library, controls: controls), prefs: Preferences(), themes: ThemeStore(),
                             gamepad: GamepadInput())
        let window = FloatingWindow(model: model)
        window.install()
        self.window = window
    }

    func applicationWillTerminate(_ notification: Notification) {
        window?.model.emulator.stop() // writes the in-game save and the resume point
    }
}
