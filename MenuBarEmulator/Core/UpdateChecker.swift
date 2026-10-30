import Foundation
import Observation

/// Tells people when a new version is out. It reads `update.json` from the GitHub repo at launch and once a day, and
/// Kian announces an update by editing that file (version, message, link). Nothing about the user is sent.
@Observable
final class UpdateChecker {
    struct Update: Codable, Equatable {
        var version: String
        var message: String?
        var url: String?
    }

    static let feed = URL(string: "https://raw.githubusercontent.com/Kiasora/menu-bar-emulator/main/update.json")!
    private static let dismissedKey = "MenuBarEmulator.dismissedUpdate"

    /// A newer version the user hasn't dismissed yet.
    private(set) var available: Update?

    @ObservationIgnored private let store: UserDefaults
    @ObservationIgnored private let current: String
    @ObservationIgnored private var timer: Timer?

    init(store: UserDefaults = .standard, current: String = AppInfo.version) {
        self.store = store
        self.current = current
    }

    func start() {
        check()
        nonisolated(unsafe) weak let checker = self // the timer fires on the main run loop
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { _ in checker?.check() }
    }

    func check() {
        let request = URLRequest(url: Self.feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        nonisolated(unsafe) weak let checker = self // the answer is handed back on the main thread
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data, let update = try? JSONDecoder().decode(Update.self, from: data) else { return }
            DispatchQueue.main.async { checker?.consider(update) }
        }.resume()
    }

    func consider(_ update: Update) {
        let newer = Self.isNewer(update.version, than: current)
        available = newer && store.string(forKey: Self.dismissedKey) != update.version ? update : nil
    }

    /// Hides this version's banner for good (a newer one shows again).
    func dismiss() {
        if let version = available?.version { store.set(version, forKey: Self.dismissedKey) }
        available = nil
    }

    /// Where "Get it" goes: the link in the file, else the Ko-fi page.
    var link: URL { available?.url.flatMap(URL.init(string:)) ?? URL(string: AppInfo.tipURL)! }

    /// "1.10" is newer than "1.9"; "1.0.1" is newer than "1.0".
    static func isNewer(_ version: String, than current: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }, b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
