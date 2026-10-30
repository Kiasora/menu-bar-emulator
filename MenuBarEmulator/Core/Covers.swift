import AppKit
import Observation

/// Box art for the library, from the libretro-thumbnails project (named after No-Intro ROM names, which is how most
/// ROMs are named). Downloaded once per game into Covers/, misses remembered so they're never asked again.
/// Games it can't find keep their console drawing.
@Observable
final class Covers {
    private(set) var images: [String: NSImage] = [:]
    /// Pictures people picked themselves; they win over downloaded box art.
    private(set) var customs: [String: NSImage] = [:]
    var enabled: Bool { didSet { store.set(enabled, forKey: "MenuBarEmulator.covers") } }

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private let store: UserDefaults
    @ObservationIgnored private var inFlight: Set<String> = []

    init(library: Library, store: UserDefaults = .standard) {
        self.library = library
        folder = library.root.appending(path: "Covers")
        self.store = store
        enabled = store.object(forKey: "MenuBarEmulator.covers") as? Bool ?? true
    }

    func image(for rom: URL) -> NSImage? { customs[key(rom)] ?? images[key(rom)] }

    func hasCustom(_ rom: URL) -> Bool { customs[key(rom)] != nil }

    /// Uses any image (PNG, JPEG, HEIC, a screenshot…) as the game's picture. Stored scaled down as PNG.
    @discardableResult
    func setCustom(_ image: URL, for rom: URL) -> Bool {
        guard let source = NSImage(contentsOf: image), source.size.width > 0, source.size.height > 0 else { return false }
        let scale = min(1, 640 / max(source.size.width, source.size.height))
        let size = NSSize(width: (source.size.width * scale).rounded(), height: (source.size.height * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]), let stored = NSImage(data: png) else { return false }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (try? png.write(to: customURL(rom), options: .atomic)) != nil else { return false }
        customs[key(rom)] = stored
        return true
    }

    func removeCustom(_ rom: URL) {
        try? FileManager.default.removeItem(at: customURL(rom))
        if canUseLegacyFiles(for: rom) { try? FileManager.default.removeItem(at: customURL(rom, legacy: true)) }
        customs[key(rom)] = nil
    }

    private func customURL(_ rom: URL, legacy: Bool = false) -> URL {
        folder.appending(path: (legacy ? rom.deletingPathExtension().lastPathComponent : key(rom)) + ".custom.png")
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "bmp"]

    /// Loads the cached cover, or downloads it. Safe to call on every appear.
    @MainActor
    func load(_ rom: URL) async {
        let key = key(rom), legacyKey = rom.deletingPathExtension().lastPathComponent
        if customs[key] == nil {
            var custom = NSImage(contentsOf: customURL(rom))
            if custom == nil, canUseLegacyFiles(for: rom) { custom = NSImage(contentsOf: customURL(rom, legacy: true)) }
            if let custom { customs[key] = custom }
        }
        guard images[key] == nil, !inFlight.contains(key), let system = GameSystem(rom: rom) else { return }
        let file = folder.appending(path: key + ".png"), miss = folder.appending(path: key + ".none")
        let legacyFile = folder.appending(path: legacyKey + ".png"), legacyMiss = folder.appending(path: legacyKey + ".none")
        if let cached = NSImage(contentsOf: file) ?? (canUseLegacyFiles(for: rom) ? NSImage(contentsOf: legacyFile) : nil) {
            images[key] = cached
            return
        }
        let missed = FileManager.default.fileExists(atPath: miss.path)
            || (canUseLegacyFiles(for: rom) && FileManager.default.fileExists(atPath: legacyMiss.path))
        guard enabled, !missed else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var allAnswered = true
        for name in Self.candidates(for: rom) {
            guard let url = Self.url(name: name, system: system) else { continue }
            guard let (data, response) = try? await URLSession.shared.data(from: url) else {
                allAnswered = false
                continue
            }
            if (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) {
                try? data.write(to: file, options: .atomic)
                images[key] = image
                return
            }
        }
        if allAnswered { try? Data().write(to: miss) } // offline doesn't count as a miss
    }

    private func key(_ rom: URL) -> String { rom.lastPathComponent }

    private func canUseLegacyFiles(for rom: URL) -> Bool { !library.hasLegacyNameCollision(for: rom) }

    /// Exact file name first, then the usual region variants of the title.
    static func candidates(for rom: URL) -> [String] {
        let name = rom.deletingPathExtension().lastPathComponent
        let title = rom.gameTitle
        var names = [name]
        let withoutRevision = name.replacing(/\s*\((Rev|v)\s?[\d.]+\)/, with: "")
        names.append(withoutRevision)
        for region in ["USA", "USA, Europe", "Europe", "World", "Japan"] { names.append("\(title) (\(region))") }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    static func url(name: String, system: GameSystem) -> URL? {
        let repo = switch system {
        case .gb: "Nintendo_-_Game_Boy"
        case .gbc: "Nintendo_-_Game_Boy_Color"
        case .gba: "Nintendo_-_Game_Boy_Advance"
        case .nds: "Nintendo_-_Nintendo_DS"
        }
        // libretro-thumbnails replaces these characters in file names.
        let safe = String(name.map { "&*/:`<>?\\|\"".contains($0) ? "_" : $0 })
        guard let encoded = safe.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: ",+"))) else { return nil }
        return URL(string: "https://raw.githubusercontent.com/libretro-thumbnails/\(repo)/master/Named_Boxarts/\(encoded).png")
    }
}
