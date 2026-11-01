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
        /// The release zip for one-click updates (a GitHub release download), and its SHA-256.
        var download: String?
        var sha256: String?
    }

    /// Where `update.json` is read from, first one that answers. GitHub's API has it at most a minute old;
    /// raw.githubusercontent.com keeps it up to 5 minutes whatever the query string, so it's only the backup, for when the
    /// API's limit (60 checks an hour per network) runs out.
    static let feeds: [URLRequest] = [
        "https://api.github.com/repos/Kiasora/menu-bar-emulator/contents/update.json",
        "https://raw.githubusercontent.com/Kiasora/menu-bar-emulator/main/update.json",
    ].map { link in
        var request = URLRequest(url: URL(string: link)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept") // the file itself, not JSON about it
        return request
    }
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

    /// `manual` (the Check for Updates button) shows a dismissed version again. `done` gets whether there's a newer
    /// version, or nil if GitHub couldn't be reached.
    func check(manual: Bool = false, feeds: ArraySlice<URLRequest> = UpdateChecker.feeds[...], done: ((Bool?) -> Void)? = nil) {
        guard let request = feeds.first else { done?(nil); return }
        nonisolated(unsafe) weak let checker = self // the answer is handed back on the main thread
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let answered = (response as? HTTPURLResponse).map { $0.statusCode == 200 } ?? (data != nil) // file: URLs in tests
            let update = answered ? data.flatMap { try? JSONDecoder().decode(Update.self, from: $0) } : nil
            DispatchQueue.main.async {
                guard let checker else { done?(nil); return }
                guard let update else { return checker.check(manual: manual, feeds: feeds.dropFirst(), done: done) } // next source
                if manual { checker.store.removeObject(forKey: Self.dismissedKey) }
                checker.consider(update)
                done?(checker.available != nil)
            }
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
