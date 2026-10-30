import Foundation
import Observation

/// Everything on disk, under Application Support/MenuBarEmulator: ROMs, BIOS files, saves, save states,
/// cheats, and per-game stats (favorite, play time, last played). Imported files are copies, so originals can go.
@Observable
final class Library {
    static let romExtensions: Set<String> = ["gb", "gbc", "gba", "nds"]
    static let biosExtensions: Set<String> = ["bin", "rom"]
    static let patchExtensions: Set<String> = ["ips", "ups", "bps"]

    let root: URL
    private(set) var roms: [URL] = []
    private(set) var bios: [URL] = []
    /// Keyed by ROM file name.
    private(set) var meta: [String: GameMeta] = [:]
    /// Your own order from dragging games around (file names). Games it doesn't list go after it, A–Z.
    private(set) var order: [String] = []

    struct GameMeta: Codable, Equatable {
        var favorite = false
        var playtime: TimeInterval = 0
        var lastPlayed: Date?
    }

    /// What an import did, for the toast.
    struct ImportResult {
        var games: [URL] = []
        var bios = 0
        var mods: [URL] = []
        /// IPS patches don't say which game they're for; these need "Apply Mod Patch…" on a game.
        var needsGame: [URL] = []

        var count: Int { games.count + bios + mods.count }

        var summary: String? {
            var parts: [String] = []
            if !games.isEmpty { parts.append(games.count == 1 ? "Added \(games[0].gameTitle)" : "Added \(games.count) games") }
            if !mods.isEmpty { parts.append(mods.count == 1 ? "Modded game added" : "\(mods.count) modded games added") }
            if bios > 0 { parts.append("\(bios) BIOS file\(bios == 1 ? "" : "s")") }
            if !needsGame.isEmpty { parts.append("Right-click a game › Apply Mod Patch for \(needsGame[0].lastPathComponent)") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    init(root: URL = .applicationSupportDirectory.appending(path: "MenuBarEmulator")) {
        self.root = root
        if let data = try? Data(contentsOf: root.appending(path: "library.json")),
           let saved = try? JSONDecoder().decode([String: GameMeta].self, from: data) {
            meta = saved
        }
        if let data = try? Data(contentsOf: root.appending(path: "order.json")) {
            order = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        reload()
    }

    // MARK: Importing

    /// Copies every ROM/BIOS in `urls` (and inside any folders) into the library. Mod patches (.ips/.ups/.bps) become
    /// their own modded game when the game they're for is already here. Never overwrites anything.
    @discardableResult
    func importFiles(_ urls: [URL]) -> ImportResult {
        let fm = FileManager.default
        var result = ImportResult()
        var patches: [URL] = []
        for url in urls.flatMap(Self.expandingFolders) {
            let ext = url.pathExtension.lowercased()
            if Self.patchExtensions.contains(ext) { patches.append(url); continue }
            let isROM = Self.romExtensions.contains(ext)
            guard isROM || Self.biosExtensions.contains(ext) else { continue }
            let dir = root.appending(path: isROM ? "ROMs" : "BIOS")
            let dest = dir.appending(path: url.lastPathComponent)
            // Never overwrite: a same-named file may hold the user's only copy.
            guard !fm.fileExists(atPath: dest.path) else { continue }
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                // Plain data copy (no clone): cloning iCloud-synced files can stall forever. EXCL = never overwrite.
                guard copyfile(url.path, dest.path, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_EXCL)) == 0 else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: dest.path])
                }
                if isROM { result.games.append(dest) } else { result.bios += 1 }
            } catch {
                NSLog("Import failed for \(url.path): \(error)")
            }
        }
        reload()
        // After the games, so a patch dropped together with its game finds it.
        for patch in patches {
            do {
                result.mods.append(try applyPatch(patch))
            } catch Patcher.PatchError.noMatchingGame {
                result.needsGame.append(patch)
            } catch {
                NSLog("Patch \(patch.lastPathComponent) failed: \(error)")
            }
        }
        return result
    }

    /// Applies an IPS/UPS/BPS patch (ROM hack, translation, fan mod…) and adds the result as its own game with its
    /// own saves. Without `rom`, UPS/BPS patches find their game by checksum.
    @discardableResult
    func applyPatch(_ patchURL: URL, to rom: URL? = nil) throws -> URL {
        let patch = try Data(contentsOf: patchURL)
        let source: URL
        if let rom {
            source = rom
        } else {
            guard let wanted = Patcher.requiredSource(of: patch),
                  let match = roms.first(where: { Self.size(of: $0) == wanted.size && (try? Patcher.crc32(Data(contentsOf: $0))) == wanted.crc })
            else { throw Patcher.PatchError.noMatchingGame }
            source = match
        }
        let output = try Patcher.apply(patch, to: Data(contentsOf: source))
        let name = "\(source.gameTitle) + \(patchURL.deletingPathExtension().lastPathComponent).\(source.pathExtension)"
        let dest = root.appending(path: "ROMs").appending(path: name)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try output.write(to: dest, options: .atomic)
        }
        reload()
        return dest
    }

    /// Moves the library's copy of a ROM to the Trash (recoverable) and returns where it went. Its saves stay.
    @discardableResult
    func remove(_ rom: URL) -> URL? {
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: rom, resultingItemURL: &trashed)
        } catch {
            NSLog("Couldn't move \(rom.path) to the Trash: \(error)")
        }
        reload()
        return trashed as URL?
    }

    /// Moves the whole library (games, BIOS, saves, save states, cheats, pictures) to the Trash, so it's recoverable.
    @discardableResult
    func eraseAll() -> URL? {
        var trashed: NSURL?
        if FileManager.default.fileExists(atPath: root.path) {
            do { try FileManager.default.trashItem(at: root, resultingItemURL: &trashed) } catch { NSLog("Couldn't move the library to the Trash: \(error)") }
        }
        meta = [:]
        order = []
        reload()
        return trashed as URL?
    }

    func reload() {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        roms = files(in: "ROMs").enumerated()
            .sorted { (rank[$0.element.lastPathComponent] ?? .max, $0.offset) < (rank[$1.element.lastPathComponent] ?? .max, $1.offset) }
            .map(\.element)
        bios = files(in: "BIOS")
    }

    /// Puts `rom` in `target`'s spot (dragging games around in the library) and remembers the order.
    func move(_ rom: URL, to target: URL) {
        var names = roms.map(\.lastPathComponent)
        guard let from = names.firstIndex(of: rom.lastPathComponent), let to = names.firstIndex(of: target.lastPathComponent),
              from != to else { return }
        names.insert(names.remove(at: from), at: to)
        order = names
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(order).write(to: root.appending(path: "order.json"), options: .atomic)
        reload()
    }

    // MARK: Stats

    func meta(for rom: URL) -> GameMeta { meta[rom.lastPathComponent] ?? GameMeta() }

    func toggleFavorite(_ rom: URL) {
        meta[rom.lastPathComponent, default: GameMeta()].favorite.toggle()
        saveMeta()
    }

    func addPlaytime(_ seconds: TimeInterval, to rom: URL) {
        guard seconds > 0 else { return }
        meta[rom.lastPathComponent, default: GameMeta()].playtime += seconds
        meta[rom.lastPathComponent, default: GameMeta()].lastPlayed = Date()
        saveMeta()
    }

    var totalPlaytime: TimeInterval { meta.values.reduce(0) { $0 + $1.playtime } }

    private func saveMeta() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(meta).write(to: root.appending(path: "library.json"), options: .atomic)
    }

    // MARK: Cheats

    func cheats(for rom: URL) -> [Cheat] {
        let current = cheatsURL(rom)
        let legacy = cheatsURL(rom, legacy: true)
        let url = !FileManager.default.fileExists(atPath: current.path) && !hasLegacyNameCollision(for: rom)
            && FileManager.default.fileExists(atPath: legacy.path) ? legacy : current
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Cheat].self, from: data)) ?? []
    }

    func setCheats(_ cheats: [Cheat], for rom: URL) {
        let url = cheatsURL(rom)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(cheats).write(to: url, options: .atomic)
    }

    /// Old per-game files omitted the extension; don't guess who owned one when two games share that old name.
    func hasLegacyNameCollision(for rom: URL) -> Bool {
        let name = rom.deletingPathExtension().lastPathComponent
        return roms.contains { $0 != rom && $0.deletingPathExtension().lastPathComponent == name }
    }

    private func cheatsURL(_ rom: URL, legacy: Bool = false) -> URL {
        let name = legacy ? rom.deletingPathExtension().lastPathComponent : rom.lastPathComponent
        return root.appending(path: "Cheats").appending(path: name + ".json")
    }

    // MARK: Files

    private static func expandingFolders(_ url: URL) -> [URL] {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return [url] }
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        return files?.compactMap { $0 as? URL } ?? []
    }

    private static func size(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    private func files(in folder: String) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root.appending(path: folder), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return urls.sorted { $0.gameTitle.localizedStandardCompare($1.gameTitle) == .orderedAscending }
    }
}

/// A cheat code (GameShark, Action Replay, Code Breaker, Game Genie…). The cores detect the code type themselves.
struct Cheat: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var code: String
    var enabled = true
}

/// The handheld a ROM is for, from its file extension.
enum GameSystem: String, CaseIterable, Identifiable {
    case gb, gbc, gba, nds

    var id: String { rawValue }

    init?(rom: URL) {
        self.init(rawValue: rom.pathExtension.lowercased())
    }

    var shortName: String {
        switch self {
        case .gb: "GB"
        case .gbc: "GBC"
        case .gba: "GBA"
        case .nds: "DS"
        }
    }

    var title: String {
        switch self {
        case .gb: "Game Boy"
        case .gbc: "Game Boy Color"
        case .gba: "Game Boy Advance"
        case .nds: "Nintendo DS"
        }
    }

    var color: UInt32 {
        switch self {
        case .gb: 0x7D9A4B
        case .gbc: 0x8E5BD0
        case .gba: 0x5458D8
        case .nds: 0x7A8799
        }
    }
}

extension URL {
    /// "Pokemon - Platinum Version (USA) (Rev 1).nds" → "Pokemon - Platinum Version"
    var gameTitle: String {
        let name = deletingPathExtension().lastPathComponent
        let trimmed = name.replacing(/\s*[\(\[][^\)\]]*[\)\]]/, with: "").trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name : trimmed
    }
}

extension TimeInterval {
    /// 0 → nil, 754 → "12m", 9000 → "2h 30m"
    var playtimeLabel: String? {
        let minutes = Int(self / 60)
        guard minutes > 0 else { return self > 0 ? "<1m" : nil }
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
