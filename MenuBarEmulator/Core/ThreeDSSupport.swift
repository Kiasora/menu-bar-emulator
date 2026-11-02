import CryptoKit
import Foundation
import Observation

/// The 3DS emulator (Azahar) is a download you opt into instead of part of the app: it's bigger than every other
/// emulator put together, and only 3DS players need it. It comes straight from Azahar's own GitHub release, pinned to
/// one version and checked against that file's checksum before it's installed.
@Observable
final class ThreeDSSupport {
    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        case installed
        case failed(String)
    }

    static let version = "2126.2"
    static let download = URL(string: "https://github.com/azahar-emu/azahar/releases/download/2126.2/azahar-libretro-macos-arm64-2126.2.zip")!
    static let sha256 = "52c51e8c62f944a642590652a318fe9c5376fab383b59388384ba81556fb7494"
    static let downloadSize = "7 MB"

    let coreFile: URL
    private(set) var state: State
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init(folder: URL) {
        coreFile = folder.appending(path: GameSystem.n3ds.core + ".libretro")
        state = FileManager.default.fileExists(atPath: coreFile.path) ? .installed : .notInstalled
    }

    var isInstalled: Bool { state == .installed }

    /// Downloads, checks and installs the 3DS emulator, then calls `done` on the main thread if it worked.
    func install(from link: URL = download, sha256: String = sha256, done: @escaping () -> Void = {}) {
        if case .downloading = state { return }
        state = .downloading(0)
        let target = coreFile
        nonisolated(unsafe) weak let support = self
        let task = URLSession.shared.downloadTask(with: link) { file, response, _ in
            // The temporary file is deleted when this returns, so the work happens here, off the main thread.
            let result = Result<Void, Error> {
                guard let file, link.isFileURL || (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppUpdater.UpdateError.download }
                try Self.install(zip: file, sha256: sha256, to: target)
            }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    support?.state = .installed
                    done()
                case .failure(let error):
                    NSLog("3DS download failed: \(error)")
                    support?.state = .failed((error as? LocalizedError)?.errorDescription ?? "The download didn't work.")
                }
            }
        }
        observation = task.progress.observe(\.fractionCompleted) { progress, _ in
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async { if case .downloading = support?.state { support?.state = .downloading(fraction) } }
        }
        task.resume()
    }

    /// Deletes the downloaded emulator. 3DS saves stay: they're in the library's Saves folder.
    func remove() {
        try? FileManager.default.removeItem(at: coreFile)
        state = .notInstalled
    }

    /// Checks the zip and puts the emulator inside it at `target` (static so tests can run it on any folder).
    static func install(zip: URL, sha256: String, to target: URL) throws {
        let digest = SHA256.hash(data: try Data(contentsOf: zip, options: .alwaysMapped)).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256.lowercased() else { throw AppUpdater.UpdateError.checksum }
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? fm.removeItem(at: work) }
        guard AppUpdater.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) else { throw AppUpdater.UpdateError.unzip }
        let files = fm.enumerator(at: work, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        guard let core = files.first(where: { $0.lastPathComponent == "azahar_libretro.dylib" }) else { throw AppUpdater.UpdateError.notThisApp }
        guard AppUpdater.run("/usr/bin/codesign", ["--verify", core.path]) else { throw AppUpdater.UpdateError.signature }
        AppUpdater.run("/usr/bin/xattr", ["-d", "com.apple.quarantine", core.path]) // so macOS doesn't block loading it
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: core)
        } else {
            try fm.moveItem(at: core, to: target)
        }
    }
}
