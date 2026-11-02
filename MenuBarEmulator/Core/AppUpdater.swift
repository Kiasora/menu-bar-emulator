import AppKit
import CryptoKit
import Observation

/// One-click updates: downloads the release zip named in `update.json`, checks it's this app at the announced version,
/// swaps it in for the running copy and relaunches. Games, saves and settings live outside the app, so nothing else
/// changes. Anything unexpected stops the update and leaves the current app as it was.
@Observable
final class AppUpdater {
    enum State: Equatable {
        case idle
        case downloading(Double)
        case installing
        case failed(String)
    }

    enum UpdateError: LocalizedError {
        case badLink, download, checksum, unzip, notThisApp, wrongVersion, signature, notWritable

        var errorDescription: String? {
            switch self {
            case .badLink: "The update link doesn't look right."
            case .download: "The download didn't finish."
            case .checksum: "The download was damaged."
            case .unzip: "Couldn't open the download."
            case .notThisApp, .wrongVersion: "The download isn't the right version."
            case .signature: "The download's signature is broken."
            case .notWritable: "Can't replace the app where it is. Download it from Ko-fi instead."
            }
        }
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var observation: NSKeyValueObservation?

    /// Only GitHub release downloads (they redirect to GitHub's own storage).
    static func isTrusted(_ url: URL) -> Bool { url.scheme == "https" && url.host() == "github.com" }

    /// Downloads, checks and installs `update`, then quits and reopens the new version.
    func install(_ update: UpdateChecker.Update, app: URL = Bundle.main.bundleURL) {
        guard !state.isBusy else { return }
        guard let link = update.download.flatMap(URL.init(string:)), Self.isTrusted(link) else { return fail(UpdateError.badLink) }
        state = .downloading(0)
        nonisolated(unsafe) weak let updater = self
        let task = URLSession.shared.downloadTask(with: link) { file, response, _ in
            // The temporary file is deleted when this returns, so the work happens here, off the main thread.
            let result = Result<URL, Error> {
                guard let file, (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }
                DispatchQueue.main.async { updater?.state = .installing }
                return try Self.prepare(zip: file, version: update.version, sha256: update.sha256, replacing: app)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let staged): updater?.finish(staged, replacing: app)
                case .failure(let error): updater?.fail(error)
                }
            }
        }
        observation = task.progress.observe(\.fractionCompleted) { progress, _ in
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async { if case .downloading = updater?.state { updater?.state = .downloading(fraction) } }
        }
        task.resume()
    }

    func reset() { state = .idle }

    private func fail(_ error: Error) {
        NSLog("Update failed: \(error)")
        state = .failed((error as? LocalizedError)?.errorDescription ?? "The update didn't work.")
    }

    /// Swaps the new app in and relaunches into it once this one has quit (and saved).
    private func finish(_ staged: URL, replacing app: URL) {
        do {
            try Self.swap(staged, into: app)
        } catch {
            return fail(error)
        }
        let script = "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\""
        let relaunch = Process()
        relaunch.executableURL = URL(filePath: "/bin/sh")
        relaunch.arguments = ["-c", script, app.path]
        try? relaunch.run()
        NSApp.terminate(nil) // applicationWillTerminate saves the game
    }

    // MARK: Steps (static so tests can run them on any folder)

    /// Checks the zip and unpacks the app inside it next to `app` (same disk, so the swap is a rename).
    static func prepare(zip: URL, version: String, sha256: String?, replacing app: URL) throws -> URL {
        if let sha256 {
            let digest = SHA256.hash(data: try Data(contentsOf: zip, options: .alwaysMapped)).map { String(format: "%02x", $0) }.joined()
            guard digest == sha256.lowercased() else { throw UpdateError.checksum }
        }
        let folder = app.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else { throw UpdateError.notWritable }
        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) else { throw UpdateError.unzip }

        let bundleID = Bundle(url: app)?.bundleIdentifier ?? Bundle.main.bundleIdentifier
        let files = FileManager.default.enumerator(at: work, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        let apps = (files?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "app" }
        guard let found = apps.first(where: { Bundle(url: $0)?.bundleIdentifier == bundleID }) else { throw UpdateError.notThisApp }
        guard Bundle(url: found)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else { throw UpdateError.wrongVersion }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", found.path]) else { throw UpdateError.signature }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", found.path]) // so macOS doesn't block the update
        return found
    }

    /// Puts the new app where the old one was, in one step: there's never a moment without an app.
    static func swap(_ staged: URL, into app: URL) throws {
        _ = try FileManager.default.replaceItemAt(app, withItemAt: staged, backupItemName: nil, options: [])
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

private extension AppUpdater.State {
    var isBusy: Bool {
        switch self {
        case .downloading, .installing: true
        case .idle, .failed: false
        }
    }
}
