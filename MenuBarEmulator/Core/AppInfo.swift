import AppKit

/// App-wide constants: name, version, links, and the credits for the open-source parts inside.
enum AppInfo {
    static let name = "Menu Bar Emulator"
    /// Shown in onboarding and Settings so people know rough edges are expected and feedback helps.
    static let isEarlyBuild = true

    /// Where "Send Feedback" emails go. Empty = Mail opens with no recipient filled in (people can still message on Ko-fi).
    static let feedbackEmail = ""

    /// The tip jar.
    static let tipURL = "https://ko-fi.com/kian"

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static var versionLabel: String { isEarlyBuild ? "\(version) (early build)" : version }

    static var systemInfo: String {
        "\(name) \(versionLabel) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    struct Credit: Identifiable {
        let name: String
        let detail: String
        let license: String
        let url: String
        var id: String { name }
    }

    /// Everything open source this app is built on. Their licenses require this credit (and GPL: the source).
    static let credits: [Credit] = [
        Credit(name: "mGBA", detail: "Game Boy, Game Boy Color and Game Boy Advance emulation, by Vicki Pfau and contributors",
               license: "Mozilla Public License 2.0", url: "https://github.com/mgba-emu/mgba"),
        Credit(name: "melonDS", detail: "Nintendo DS emulation, by Arisotura and contributors",
               license: "GNU GPL 3.0", url: "https://github.com/melonDS-emu/melonDS"),
        Credit(name: "melonDS DS", detail: "The libretro version of melonDS used here, by Jesse Talavera and contributors",
               license: "GNU GPL 3.0", url: "https://github.com/JesseTG/melonds-ds"),
        Credit(name: "libretro", detail: "The emulator interface (libretro.h, libretro-common)",
               license: "MIT", url: "https://github.com/libretro/libretro-common"),
        Credit(name: "libretro-thumbnails", detail: "Box art, downloaded when you add a game",
               license: "Box art belongs to its owners", url: "https://github.com/libretro-thumbnails/libretro-thumbnails"),
    ]
}
