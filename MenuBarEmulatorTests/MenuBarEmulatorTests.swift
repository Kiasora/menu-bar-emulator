import XCTest
import AppKit
import SwiftUI
@testable import MenuBarEmulator

/// Shared setup: a temp folder and fresh UserDefaults. Optional real-ROM fixtures stay outside the source and test bundle.
class EmulatorTestCase: XCTestCase {
    var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    func defaults() -> UserDefaults {
        UserDefaults(suiteName: "MenuBarEmulatorTests.\(UUID().uuidString)")!
    }

    func makeFile(_ name: String, _ contents: String = "x") throws -> URL {
        let url = temp.appending(path: name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Real-ROM integration tests are opt-in: public source checkouts skip them instead of bundling games or test ROMs.
    func testROM(_ path: String) throws -> URL {
        let name = (path as NSString).lastPathComponent
        let local = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "LocalTestFixtures/ROMs")
        let folder = ProcessInfo.processInfo.environment["MENU_BAR_EMULATOR_TEST_ROMS"].map { URL(fileURLWithPath: $0) } ?? local
        let url = folder.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Optional ROM fixture \(name) not provided; set MENU_BAR_EMULATOR_TEST_ROMS to run this integration test")
        }
        return url
    }

    static let gb = "mgba/cinema/gb/acid/dmg-acid2/test.gb"
    static let gbc = "mgba/cinema/gb/acid/cgb-acid2/test.gbc"
    static let gba = "mgba/cinema/gba/obj/2d-wrap/test.gba"
    static let ds = "melonds-ds/test/nds/micrecord.nds"

    func makeEmulator(_ library: Library? = nil) -> Emulator {
        Emulator(library: library ?? Library(root: temp.appending(path: "Library")), controls: Controls(store: defaults()))
    }

    func makeModel(library: Library? = nil, store: UserDefaults? = nil) -> AppModel {
        let library = library ?? Library(root: temp.appending(path: "Library"))
        let store = store ?? defaults()
        let controls = Controls(store: store)
        let covers = Covers(library: library, store: store)
        covers.enabled = false
        return AppModel(library: library, controls: controls, display: Display(store: store), covers: covers,
                        emulator: Emulator(library: library, controls: controls), prefs: Preferences(store: store),
                        themes: ThemeStore(store: store), gamepad: nil, store: store)
    }

    func key(_ code: UInt16, _ characters: String = "", down: Bool = true, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
}

// MARK: - Library

final class LibraryTests: EmulatorTestCase {
    func testSortsRomsAndBiosAndSkipsOtherFiles() throws {
        let library = Library(root: temp.appending(path: "Library"))
        let files = try ["Pokemon Emerald.gba", "Zelda.GB", "Mario.nds", "bios7.bin", "notes.txt"].map { try makeFile($0) }

        XCTAssertEqual(library.importFiles(files).count, 4)
        XCTAssertEqual(library.roms.map(\.lastPathComponent), ["Mario.nds", "Pokemon Emerald.gba", "Zelda.GB"])
        XCTAssertEqual(library.bios.map(\.lastPathComponent), ["bios7.bin"])
    }

    func testNeverOverwritesExistingFile() throws {
        let library = Library(root: temp.appending(path: "Library"))
        library.importFiles([try makeFile("Game.gba", "original")])
        let other = temp.appending(path: "other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let newer = other.appending(path: "Game.gba")
        try Data("newer".utf8).write(to: newer)

        XCTAssertEqual(library.importFiles([newer]).count, 0)
        XCTAssertEqual(try String(contentsOf: library.roms[0], encoding: .utf8), "original")
    }

    func testImportsFoldersAndRemovesToTrash() throws {
        let folder = temp.appending(path: "Games/GBA")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appending(path: "Emerald.gba"))
        let library = Library(root: temp.appending(path: "Library"))
        XCTAssertEqual(library.importFiles([temp.appending(path: "Games")]).count, 1)
        let rom = try XCTUnwrap(library.roms.first)
        let trashed = try XCTUnwrap(library.remove(rom))
        try? FileManager.default.removeItem(at: trashed) // don't leave test files in the real Trash
        XCTAssertTrue(library.roms.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "Emerald.gba").path), "original untouched")
    }

    func testFavoritesPlaytimeAndCheatsPersist() throws {
        let root = temp.appending(path: "Library")
        let library = Library(root: root)
        library.importFiles([try makeFile("Emerald.gba")])
        let rom = try XCTUnwrap(library.roms.first)
        library.toggleFavorite(rom)
        library.addPlaytime(90, to: rom)
        library.addPlaytime(60, to: rom)
        library.setCheats([Cheat(name: "Money", code: "82025838 FFFF")], for: rom)

        let reopened = Library(root: root)
        XCTAssertTrue(reopened.meta(for: rom).favorite)
        XCTAssertEqual(reopened.meta(for: rom).playtime, 150)
        XCTAssertNotNil(reopened.meta(for: rom).lastPlayed)
        XCTAssertEqual(reopened.cheats(for: rom).map(\.code), ["82025838 FFFF"])
        XCTAssertEqual(TimeInterval(150).playtimeLabel, "2m")
        XCTAssertEqual(TimeInterval(9000).playtimeLabel, "2h 30m")
        XCTAssertNil(TimeInterval(0).playtimeLabel)
    }

    func testGameTitles() {
        XCTAssertEqual(URL(filePath: "/x/Pokemon - Platinum Version (USA) (Rev 1).nds").gameTitle, "Pokemon - Platinum Version")
        XCTAssertEqual(URL(filePath: "/x/Zelda [!].gb").gameTitle, "Zelda")
        XCTAssertEqual(URL(filePath: "/x/(Prototype).gba").gameTitle, "(Prototype)")
        XCTAssertEqual(URL(filePath: "/x/Emerald + Radical Red.gba").gameTitle, "Emerald + Radical Red")
        XCTAssertEqual(GameSystem(rom: URL(filePath: "/x/a.GBA")), .gba)
    }

    func testCoverArtNames() throws {
        let rom = URL(filePath: "/x/Pokemon - Platinum Version (USA) (Rev 1).nds")
        let names = Covers.candidates(for: rom)
        XCTAssertEqual(names.first, "Pokemon - Platinum Version (USA) (Rev 1)")
        XCTAssertTrue(names.contains("Pokemon - Platinum Version (USA)"))
        let url = try XCTUnwrap(Covers.url(name: "Mario & Luigi (USA, Europe)", system: .gba))
        XCTAssertEqual(url.absoluteString, "https://raw.githubusercontent.com/libretro-thumbnails/Nintendo_-_Game_Boy_Advance/master/Named_Boxarts/Mario%20_%20Luigi%20(USA%2C%20Europe).png")
    }
}

// MARK: - Mod patches

final class PatcherTests: EmulatorTestCase {
    private func varint(_ value: UInt64) -> [UInt8] {
        var data = value, out: [UInt8] = []
        while true {
            let x = UInt8(data & 0x7F)
            data >>= 7
            if data == 0 { out.append(0x80 | x); return out }
            out.append(x)
            data -= 1
        }
    }

    private func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }

    private func withFooter(_ body: [UInt8], source: [UInt8], target: [UInt8]) -> Data {
        var patch = body + le32(Patcher.crc32(source)) + le32(Patcher.crc32(target))
        patch += le32(Patcher.crc32(patch))
        return Data(patch)
    }

    func testCRC32() {
        XCTAssertEqual(Patcher.crc32(Array("123456789".utf8)), 0xCBF4_3926)
    }

    func testIPS() throws {
        var patch = Array("PATCH".utf8)
        patch += [0, 0, 7, 0, 5] + Array("there".utf8)   // normal record at 7
        patch += [0, 0, 0, 0, 0, 0, 3, UInt8(ascii: "J")] // RLE: 3 × "J" at 0
        patch += Array("EOF".utf8)
        let out = try Patcher.apply(Data(patch), to: Data("Hello, world".utf8))
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "JJJlo, there")
    }

    func testUPS() throws {
        let source = Array("Hello, world".utf8), target = Array("Hello, there".utf8)
        var body = Array("UPS1".utf8) + varint(12) + varint(12) + varint(7)
        body += (7..<12).map { source[$0] ^ target[$0] } + [0]
        let patch = withFooter(body, source: source, target: target)
        XCTAssertEqual(try Patcher.apply(patch, to: Data(source)), Data(target))
        XCTAssertEqual(Patcher.requiredSource(of: patch)?.crc, Patcher.crc32(source))
        XCTAssertThrowsError(try Patcher.apply(patch, to: Data("Hello, WORLD".utf8))) { XCTAssertEqual($0 as? Patcher.PatchError, .wrongGame) }
    }

    func testBPSAllFourActions() throws {
        let source = Array("Hello, world!".utf8)
        let target = Array("Hello, BPS!BPSHello".utf8)
        var body = Array("BPS1".utf8) + varint(UInt64(source.count)) + varint(UInt64(target.count)) + varint(0)
        body += varint(6 << 2 | 0)                              // SourceRead 7: "Hello, "
        body += varint(3 << 2 | 1) + Array("BPS!".utf8)         // TargetRead 4
        body += varint(2 << 2 | 3) + varint(7 << 1)             // TargetCopy 3 from 7: "BPS"
        body += varint(4 << 2 | 2) + varint(0)                  // SourceCopy 5 from 0: "Hello"
        let patch = withFooter(body, source: source, target: target)
        XCTAssertEqual(try Patcher.apply(patch, to: Data(source)), Data(target))
        XCTAssertEqual(Patcher.requiredSource(of: patch)?.size, source.count)
    }

    func testDroppedPatchFindsItsGameAndBecomesAModdedGame() throws {
        let source = Array("Hello, world!".utf8), target = Array("Hello, BPS!".utf8)
        var body = Array("BPS1".utf8) + varint(UInt64(source.count)) + varint(UInt64(target.count)) + varint(0)
        body += varint(6 << 2 | 0) + varint(3 << 2 | 1) + Array("BPS!".utf8)
        let patchURL = temp.appending(path: "Cool Hack.bps")
        try withFooter(body, source: source, target: target).write(to: patchURL)
        let game = temp.appending(path: "Game (USA).gba")
        try Data(source).write(to: game)

        let library = Library(root: temp.appending(path: "Library"))
        let result = library.importFiles([game, patchURL])
        XCTAssertEqual(result.games.count, 1)
        XCTAssertEqual(result.mods.map(\.lastPathComponent), ["Game + Cool Hack.gba"])
        XCTAssertEqual(try Data(contentsOf: result.mods[0]), Data(target))
        XCTAssertEqual(library.roms.count, 2)

        // IPS patches can't say which game they're for.
        let ips = temp.appending(path: "Old.ips")
        try Data(Array("PATCH".utf8) + Array("EOF".utf8)).write(to: ips)
        XCTAssertEqual(library.importFiles([ips]).needsGame, [ips])
    }
}

// MARK: - Emulator

final class EmulatorTests: EmulatorTestCase {
    /// Boots a real test ROM and checks it draws a non-blank picture of the right size.
    private func assertBoots(_ path: String, width: Int, height: Int) throws {
        let emulator = makeEmulator()
        emulator.windowVisible = true
        emulator.showingGame = true
        emulator.play(try testROM(path))
        XCTAssertNil(emulator.error)
        XCTAssertTrue(emulator.isRunning)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        emulator.windowVisible = false // auto-pause when hidden
        XCTAssertFalse(emulator.isRunning)

        let frame = try XCTUnwrap(emulator.frame)
        XCTAssertEqual(frame.width, width)
        XCTAssertEqual(frame.height, height)
        XCTAssertEqual(emulator.frameSize, CGSize(width: width, height: height))
        XCTAssertNotNil(emulator.snapshot, "pausing keeps a picture for the library")
        let bytes = try XCTUnwrap(frame.dataProvider?.data as Data?)
        XCTAssertGreaterThan(Set(bytes).count, 2, "frame is a single flat color")
        emulator.stop()
        XCTAssertNil(emulator.game)
    }

    func testGameBoyBoots() throws { try assertBoots(Self.gbc, width: 160, height: 144) }
    func testGBABoots() throws { try assertBoots(Self.gba, width: 240, height: 160) }
    func testDSBoots() throws { try assertBoots(Self.ds, width: 256, height: 384) }

    func testRunsOnlyWhenVisibleOnGameScreenAndNotPaused() throws {
        let emulator = makeEmulator()
        emulator.play(try testROM(Self.gb))
        XCTAssertFalse(emulator.isRunning, "window not visible yet")
        emulator.windowVisible = true
        XCTAssertFalse(emulator.isRunning, "still on the library screen")
        emulator.showingGame = true
        XCTAssertTrue(emulator.isRunning)
        XCTAssertTrue(emulator.handleKey(49, down: true)) // Space = pause
        XCTAssertFalse(emulator.isRunning)
        XCTAssertTrue(emulator.handleKey(49, down: false))
        XCTAssertTrue(emulator.handleKey(49, down: true))
        XCTAssertTrue(emulator.isRunning)
        XCTAssertTrue(emulator.handleKey(48, down: true)) // Tab = fast-forward
        XCTAssertTrue(emulator.fastForward)
        XCTAssertTrue(emulator.handleKey(48, down: true, isRepeat: true)) // holding doesn't flicker it
        XCTAssertTrue(emulator.fastForward)
        emulator.setPad([.r2])
        XCTAssertTrue(emulator.holdingFastForward, "right trigger holds fast-forward")
        emulator.setPad([])
        emulator.showingGame = false
        XCTAssertFalse(emulator.handleKey(48, down: true), "keys pass through outside the game screen")
        emulator.stop()
        XCTAssertNil(emulator.game)
    }

    func testPacingFollowsRealTime() {
        var debt = 0.0
        XCTAssertEqual(Emulator.framesToRun(elapsed: 1.0 / 60, fps: 60, speed: 1, debt: &debt), 1)
        XCTAssertEqual(Emulator.framesToRun(elapsed: 1.0 / 120, fps: 60, speed: 1, debt: &debt), 0, "half a frame carries over")
        XCTAssertEqual(Emulator.framesToRun(elapsed: 1.0 / 120, fps: 60, speed: 1, debt: &debt), 1)
        debt = 0
        XCTAssertEqual(Emulator.framesToRun(elapsed: 1.0 / 60, fps: 60, speed: 4, debt: &debt), 4)
        debt = 0
        XCTAssertEqual(Emulator.framesToRun(elapsed: 5, fps: 60, speed: 1, debt: &debt), 3, "a long stall never runs a burst of frames")
    }

    func testSaveStatesAndResumeWhereYouLeftOff() throws {
        let rom = try testROM(Self.gba)
        let emulator = makeEmulator()
        emulator.windowVisible = true
        emulator.showingGame = true
        emulator.play(rom)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        XCTAssertFalse(emulator.hasState("1"))
        XCTAssertTrue(emulator.saveState("1"))
        XCTAssertNotNil(emulator.stateInfo("1")?.thumbnail, "thumbnail saved")
        XCTAssertTrue(emulator.loadState("1"))
        XCTAssertFalse(emulator.loadState("2"), "empty slot")
        XCTAssertTrue(emulator.handleKey(18, down: true)) // 1 = quick save
        XCTAssertTrue(emulator.hasState("quick"))

        emulator.stop() // leaving the game saves your spot
        XCTAssertNotNil(emulator.resumeThumbnail(for: rom))
        emulator.play(rom)
        XCTAssertTrue(emulator.hasState(Emulator.autoSlot))
        XCTAssertNil(emulator.error)
        emulator.stop()
    }

    func testRewindStepsBack() throws {
        let emulator = makeEmulator()
        emulator.windowVisible = true
        emulator.showingGame = true
        emulator.play(try testROM(Self.gba))
        XCTAssertTrue(emulator.canRewind)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        let stored = emulator.rewindSeconds
        XCTAssertGreaterThan(stored, 0.5)

        XCTAssertTrue(emulator.handleKey(15, down: true)) // R = rewind (hold)
        XCTAssertTrue(emulator.isRewinding)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertLessThan(emulator.rewindSeconds, stored)
        XCTAssertTrue(emulator.handleKey(15, down: false))
        XCTAssertFalse(emulator.isRewinding)
        emulator.stop()
    }

    func testCheatsApplyWithoutBreakingTheGame() throws {
        let emulator = makeEmulator()
        emulator.windowVisible = true
        emulator.showingGame = true
        emulator.play(try testROM(Self.gba))
        XCTAssertTrue(emulator.cheatsSupported)
        emulator.applyCheats([Cheat(name: "Test", code: "82000000 0001\n82000002 0002")])
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(emulator.error)
        XCTAssertTrue(emulator.isRunning)
        emulator.stop()
    }

    func testRemappingSwapsAndPersists() {
        let store = defaults()
        let controls = Controls(store: store)
        XCTAssertEqual(controls.action(for: 7), .a) // X
        controls.assign(Controls.Key(code: 6, name: "Z"), to: .a) // Z belonged to B
        XCTAssertEqual(controls.action(for: 6), .a)
        XCTAssertEqual(controls.action(for: 7), .b, "B gets A's old key instead of losing its key")
        XCTAssertEqual(Controls(store: store).action(for: 6), .a, "saved")
        controls.reset()
        XCTAssertEqual(Controls(store: store).action(for: 7), .a)
        XCTAssertEqual(Set(Controls.defaultBindings.values.map(\.code)).count, Controls.defaultBindings.count, "no two actions share a key")
    }
}

// MARK: - App and window

final class AppTests: EmulatorTestCase {
    func testLibraryKeysTypeToSearchAndOpenGames() throws {
        let library = Library(root: temp.appending(path: "Library"))
        // Copies get distinct names so the library has three games.
        for (path, name) in [(Self.gb, "Alpha.gb"), (Self.gbc, "Bravo.gbc"), (Self.gba, "Charlie.gba")] {
            let copy = temp.appending(path: name)
            try Data(contentsOf: try testROM(path)).write(to: copy) // plain read/write: cloning iCloud-synced files can stall
            library.importFiles([copy])
        }
        let store = defaults()
        store.set(true, forKey: "MenuBarEmulator.onboarded")
        let model = makeModel(library: library, store: store)
        model.emulator.windowVisible = true
        XCTAssertEqual(model.screen, .library)
        model.libraryColumns = 2

        XCTAssertTrue(model.handle(key(124)))                 // → selects the first game
        XCTAssertEqual(model.selection?.lastPathComponent, "Alpha.gb")
        XCTAssertTrue(model.handle(key(125)))                 // ↓ moves a whole row
        XCTAssertEqual(model.selection?.lastPathComponent, "Charlie.gba")
        XCTAssertTrue(model.handle(key(36)))                  // Return plays it
        XCTAssertEqual(model.screen, .game)
        XCTAssertEqual(model.emulator.game?.lastPathComponent, "Charlie.gba")
        XCTAssertEqual(model.windowContent, .game(picture: CGSize(width: 240, height: 160)))

        XCTAssertTrue(model.handle(key(Controls.escape)))     // Esc: back to the library, game stays open
        XCTAssertEqual(model.screen, .library)
        XCTAssertEqual(model.windowContent, .home)
        XCTAssertNotNil(model.emulator.game)

        model.play(library.roms[0])                           // open a second game
        XCTAssertEqual(model.openGames.map(\.lastPathComponent), ["Alpha.gb", "Charlie.gba"])
        XCTAssertTrue(model.handle(key(19, "2", flags: .command))) // ⌘2 switches back
        XCTAssertEqual(model.emulator.game?.lastPathComponent, "Charlie.gba")
        XCTAssertEqual(model.openGames.first?.lastPathComponent, "Charlie.gba")
        model.closeGame(library.roms[2])
        XCTAssertEqual(model.screen, .library)
        XCTAssertEqual(model.openGames.map(\.lastPathComponent), ["Alpha.gb"])
        XCTAssertEqual(makeModel(library: library, store: store).openGames.count, 1, "open games are remembered")

        XCTAssertTrue(model.handle(key(11, "b")))              // typing searches
        XCTAssertTrue(model.isSearching)
        XCTAssertEqual(model.visibleROMs.map(\.lastPathComponent), ["Bravo.gbc"])
        XCTAssertTrue(model.handle(key(Controls.escape)))
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.visibleROMs.count, 3)
        model.filter = .system(.gba)
        XCTAssertEqual(model.visibleROMs.map(\.lastPathComponent), ["Charlie.gba"])
        model.emulator.stop()
    }

    func testOnboardingRunsOnceAndReturnAdvances() {
        let store = defaults()
        let model = makeModel(store: store)
        XCTAssertEqual(model.screen, .onboarding)
        for _ in 0..<AppModel.onboardingSteps { XCTAssertTrue(model.handle(key(36))) }
        XCTAssertEqual(model.screen, .library)
        XCTAssertEqual(makeModel(store: store).screen, .library, "only the first launch")
    }

    @MainActor
    func testWindowSizesSnapAndFit() {
        let gba = CGSize(width: 240, height: 160)
        XCTAssertEqual(FloatingWindow.minScale(for: gba), 1.75)
        XCTAssertEqual(FloatingWindow.snapped(2.04), 2)
        XCTAssertEqual(FloatingWindow.snapped(2.3), 2.3)
        XCTAssertEqual(FloatingWindow.snapped(0.97), 1)
        let big = FloatingWindow.clampScale(10, picture: gba, screen: CGSize(width: 1440, height: 900))
        XCTAssertEqual(big * 160, 900 * 0.94, accuracy: 0.01, "never taller than the screen")
        XCTAssertEqual(FloatingWindow.clampScale(1, picture: gba, screen: CGSize(width: 1440, height: 900)), 1.75, "never too small for the controls")
    }

    /// The real panel has a hidden title bar and gets resized a lot; the picture must always fill it, centered.
    @MainActor
    func testGamePictureFillsTheRealWindowWhileResizing() throws {
        let store = defaults()
        store.set(true, forKey: "MenuBarEmulator.onboarded")
        let model = makeModel(store: store)
        let panel = EmulatorPanel(contentRect: NSRect(x: 200, y: 200, width: 460, height: 620),
                                  styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        let hosting = NSHostingView(rootView: RootView(model: model, window: nil))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.orderFront(nil)
        // The game screen appears while the window is still library-sized, like in the app. (No ROM needed:
        // this checks where the picture goes, not what's in it.)
        model.screen = .game
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        for size in [CGSize(width: 480, height: 320), CGSize(width: 720, height: 480), CGSize(width: 420, height: 280), CGSize(width: 600, height: 400)] {
            panel.setContentSize(size)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let screen = try XCTUnwrap(Self.find(ScreenView.self, in: hosting))
            let frame = screen.convert(screen.bounds, to: nil)
            XCTAssertEqual(frame.minX, 0, accuracy: 1, "left edge at \(size)")
            XCTAssertEqual(frame.minY, 0, accuracy: 1, "bottom edge at \(size)")
            XCTAssertEqual(frame.width, size.width, accuracy: 1, "width at \(size)")
            XCTAssertEqual(frame.height, size.height, accuracy: 1, "height at \(size) (no gap under the title bar)")
            XCTAssertEqual(screen.picture.frame, screen.bounds, "picture layer follows the view at \(size)")
        }
        panel.orderOut(nil)
        model.emulator.stop()
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews { if let found = find(type, in: subview) { return found } }
        return nil
    }

    func testDSLayouts() throws {
        func layout(_ l: Display.Layout, gap: CGFloat = 0, swap: Bool = false, shell: Bool = false) -> Display.DSLayout {
            Display.dsLayout(l, gap: gap, swap: swap, shell: shell)
        }
        let stacked = layout(.stacked)
        XCTAssertEqual(stacked.size, CGSize(width: 256, height: 384), "same as the core's own frame")
        XCTAssertEqual(stacked.bottom?.minY, 192)
        let swapped = layout(.stacked, gap: 10, swap: true, shell: true)
        XCTAssertEqual(swapped.bottom?.minY, Display.shellPadding, "touch screen on top when swapped")
        XCTAssertEqual(swapped.size.height, 384 + 10 + Display.shellPadding * 2)
        XCTAssertEqual(layout(.sideBySide).size, CGSize(width: 512, height: 192))
        XCTAssertEqual(layout(.focusBottom).bottom?.width, 256, "Big Bottom = big touch screen")
        XCTAssertEqual(layout(.focusTop).bottom?.width, 128)

        // Every layout, swapped or not, with or without shell and gap: screens stay inside, and only Mini Touch overlaps.
        for l in Display.Layout.allCases {
            for (swap, shell, gap) in [(false, false, 0.0), (true, true, 20.0)] {
                let d = layout(l, gap: gap, swap: swap, shell: shell)
                let rects = [d.top, d.bottom, d.extra].compactMap { $0 }
                let bounds = CGRect(origin: .zero, size: d.size)
                for r in rects { XCTAssertTrue(bounds.contains(r), "\(l) swap=\(swap): \(r) outside \(d.size)") }
                if l != .miniTouch {
                    for (i, a) in rects.enumerated() {
                        for b in rects.dropFirst(i + 1) { XCTAssertFalse(a.intersects(b), "\(l) swap=\(swap): screens overlap") }
                    }
                }
                for r in rects { XCTAssertEqual(r.width / r.height, 256 / 192, accuracy: 0.001, "\(l): screens keep their shape") }
            }
        }

        // The "big top" family really has the bigger top screen.
        XCTAssertEqual(layout(.bigTopBelow).bottom?.width, 128)
        XCTAssertGreaterThan(try XCTUnwrap(layout(.bigTopBelow).bottom?.minY), try XCTUnwrap(layout(.bigTopBelow).top?.maxY) - 1, "touch screen below")
        XCTAssertEqual(try XCTUnwrap(layout(.topHeavy).bottom?.width), 256 * 2 / 3, accuracy: 0.01)
        XCTAssertEqual(layout(.bigBottomAbove).top?.width, 128)
        XCTAssertEqual(layout(.bigBottomAbove).bottom?.width, 256)
        XCTAssertLessThan(try XCTUnwrap(layout(.focusTopLeft).bottom?.minX), try XCTUnwrap(layout(.focusTopLeft).top?.minX), "touch screen on the left")

        // Hybrid: big screen plus a column that always reads top screen over touch screen.
        let hybrid = layout(.hybrid)
        XCTAssertEqual(hybrid.top?.width, 256)
        XCTAssertTrue(hybrid.extraIsTop)
        XCTAssertLessThan(try XCTUnwrap(hybrid.extra?.minY), try XCTUnwrap(hybrid.bottom?.minY))
        let hybridSwapped = layout(.hybrid, swap: true)
        XCTAssertEqual(hybridSwapped.bottom?.width, 256, "swapped: big touch screen")
        XCTAssertFalse(hybridSwapped.extraIsTop)
        XCTAssertLessThan(try XCTUnwrap(hybridSwapped.top?.minY), try XCTUnwrap(hybridSwapped.extra?.minY), "column still top over touch")

        // Mini Touch: the touch screen sits inside the top screen's corner.
        let mini = layout(.miniTouch)
        XCTAssertTrue(try XCTUnwrap(mini.top).contains(try XCTUnwrap(mini.bottom)))

        // One Screen shows one, flipped by swap. Separate keeps only one screen in the main window.
        XCTAssertNotNil(layout(.single).top)
        XCTAssertNil(layout(.single).bottom)
        XCTAssertNil(layout(.single, swap: true).top)
        XCTAssertNotNil(layout(.single, swap: true).bottom)
        XCTAssertEqual(layout(.separate).size, CGSize(width: 256, height: 192))
        XCTAssertNil(layout(.separate).bottom)
        XCTAssertEqual(Display.Layout.allCases.count, 12)
    }

    func testSeparateLayoutAsksForASecondWindowOnlyInDSGames() throws {
        let store = defaults()
        store.set(true, forKey: "MenuBarEmulator.onboarded")
        let model = makeModel(store: store)
        model.display.layout = .separate
        XCTAssertFalse(model.wantsSeparateScreen, "not in a game")
        let ds = temp.appending(path: "Game.nds")
        try Data(contentsOf: try testROM(Self.ds)).write(to: ds)
        model.library.importFiles([ds])
        model.play(model.library.roms[0])
        XCTAssertTrue(model.wantsSeparateScreen)
        XCTAssertEqual(model.pictureSize, CGSize(width: 256, height: 192), "the main window holds one screen")
        model.display.layout = .stacked
        XCTAssertFalse(model.wantsSeparateScreen)
        model.emulator.stop()
    }

    func testDSScreensAreCutFromTheRightHalf() throws {
        // 1×4 image: top half red, bottom half blue.
        let pixels: [UInt32] = [0xFFFF0000, 0xFFFF0000, 0xFF0000FF, 0xFF0000FF]
        let data = pixels.withUnsafeBytes { Data($0) }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        let image = try XCTUnwrap(CGImage(width: 1, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info,
                                          provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        func color(_ crop: ScreenLayer.Crop) throws -> (r: UInt8, b: UInt8) {
            let view = ScreenView()
            view.crop = crop
            view.show(image)
            let cropped = try XCTUnwrap(view.current)
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return (pixel[0], pixel[2])
        }
        XCTAssertGreaterThan(try color(.top).r, 200)
        XCTAssertGreaterThan(try color(.bottom).b, 200)
    }
}

// MARK: - v5: shortcuts, themes, controller everywhere, pictures, emulator extras

final class V5Tests: EmulatorTestCase {
    func testShortcutsRecordAndPersistIncludingCleared() {
        let store = defaults()
        let prefs = Preferences(store: store)
        XCTAssertEqual(prefs.popOutShortcut, .optionP, "⌥P out of the box")
        XCTAssertNil(prefs.menuBarShortcut)
        XCTAssertTrue(prefs.pauseWhenHidden)
        XCTAssertTrue(prefs.closeOnClickOutside)
        let menuBar = Shortcut(keyCode: 46, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, key: "M")
        prefs.menuBarShortcut = menuBar
        prefs.popOutShortcut = nil
        prefs.pauseWhenHidden = false
        let reopened = Preferences(store: store)
        XCTAssertEqual(reopened.menuBarShortcut, menuBar)
        XCTAssertNil(reopened.popOutShortcut, "clearing sticks instead of bringing ⌥P back")
        XCTAssertFalse(reopened.pauseWhenHidden)
        XCTAssertEqual(menuBar.display, "⌃⌥M")
        XCTAssertEqual(Shortcut(keyCode: 35, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, key: "P").display, "⇧⌘P")
        XCTAssertNil(Shortcut(event: key(35, "p")), "a plain key can't be a global shortcut")
        XCTAssertNotNil(Shortcut(event: key(35, "p", flags: .option)))
    }

    func testRecordingAShortcutThroughTheModel() {
        let store = defaults()
        store.set(true, forKey: "MenuBarEmulator.onboarded")
        let model = makeModel(store: store)
        model.recordingShortcut = .popOut
        XCTAssertTrue(model.handle(key(11, "b")), "plain keys are eaten while recording")
        XCTAssertEqual(model.prefs.popOutShortcut, .optionP, "but not accepted")
        XCTAssertEqual(model.recordingShortcut, .popOut)
        XCTAssertTrue(model.handle(key(11, "b", flags: [.command, .shift])))
        XCTAssertEqual(model.prefs.popOutShortcut?.display, "⇧⌘B")
        XCTAssertNil(model.recordingShortcut)
        model.recordingShortcut = .menuBar
        XCTAssertTrue(model.handle(key(11, "b", flags: [.command, .shift])))
        XCTAssertNil(model.prefs.menuBarShortcut, "the same shortcut can't do two things")
        XCTAssertTrue(model.handle(key(51)))                  // Delete clears
        XCTAssertNil(model.recordingShortcut)
    }

    func testCustomThemesDeriveReadableColorsAndPersist() {
        let store = defaults()
        let themes = ThemeStore(store: store)
        let dark = CustomTheme(name: "Night", top: 0x101020, bottom: 0x302050, accent: 0xFF7AB6, diagonal: true)
        let light = CustomTheme(name: "Paper", top: 0xFFF8EE, bottom: nil, accent: 0x0A84FF)
        themes.save(dark)
        themes.save(light)
        XCTAssertTrue(themes.theme(id: dark.id).isDark)
        XCTAssertEqual(themes.theme(id: dark.id).gradient?.count, 2)
        XCTAssertFalse(themes.theme(id: light.id).isDark)
        XCTAssertNil(themes.theme(id: light.id).gradient)
        XCTAssertEqual(themes.theme(id: "midnight").name, "Midnight")
        XCTAssertEqual(themes.theme(id: "gone").id, "dark", "unknown ids fall back to Dark")
        XCTAssertEqual(ThemeStore(store: store).custom.map(\.name), ["Night", "Paper"])
        themes.delete(dark.id)
        XCTAssertEqual(ThemeStore(store: store).custom.map(\.name), ["Paper"])
        XCTAssertEqual(themes.all.count, ThemeKind.allCases.count + 1)
        XCTAssertEqual(Theme.mix(0x000000, 0xFFFFFF, 0.5), 0x808080)
        XCTAssertEqual(Color(hex: 0x3366CC).hex, 0x3366CC)
    }

    func testPadFocusMovesSpatially() {
        let pad = PadFocus()
        var pressed: [String] = []
        func item(_ id: String, _ x: CGFloat, _ y: CGFloat, scope: String = "screen") -> PadItem {
            PadItem(id: id, scope: scope, frame: CGRect(x: x, y: y, width: 100, height: 40), action: { pressed.append(id) }, adjust: nil)
        }
        // A 2×2 grid, plus a panel item that must be ignored while the screen is in focus.
        pad.itemsChanged([item("a", 0, 0), item("b", 120, 0), item("c", 0, 60), item("d", 120, 60), item("panel", 500, 500, scope: "panel")])
        XCTAssertFalse(pad.activate(), "nothing focused until the controller is used")
        pad.move(.down)
        XCTAssertEqual(pad.current, "a", "first press focuses the top-left control")
        pad.move(.right)
        XCTAssertEqual(pad.current, "b")
        pad.move(.down)
        XCTAssertEqual(pad.current, "d")
        pad.move(.right)
        XCTAssertEqual(pad.current, "d", "nothing further right")
        pad.horizontal(-1)
        XCTAssertEqual(pad.current, "c", "← moves when the control has no value")
        XCTAssertTrue(pad.activate())
        XCTAssertEqual(pressed, ["c"])
        pad.scope = "panel"
        pad.itemsChanged(pad.items)
        XCTAssertEqual(pad.current, "panel", "opening a panel moves focus into it")
    }

    func testControllerDrivesTheLibraryAndOpensTheGameMenu() throws {
        let library = Library(root: temp.appending(path: "Library"))
        for (path, name) in [(Self.gb, "Alpha.gb"), (Self.gba, "Bravo.gba")] {
            let copy = temp.appending(path: name)
            try Data(contentsOf: try testROM(path)).write(to: copy)
            library.importFiles([copy])
        }
        let store = defaults()
        store.set(true, forKey: "MenuBarEmulator.onboarded")
        let model = makeModel(library: library, store: store)
        model.emulator.windowVisible = true
        model.padChanged([.right]); model.padChanged([])
        XCTAssertEqual(model.selection?.lastPathComponent, "Alpha.gb")
        model.padChanged([.r]); model.padChanged([])           // R cycles the filter
        XCTAssertEqual(model.filter, .system(.gb))
        model.padChanged([.l]); model.padChanged([])
        XCTAssertEqual(model.filter, .all)
        model.padChanged([.a]); model.padChanged([])           // A plays
        XCTAssertEqual(model.screen, .game)
        model.padChanged([.start, .select])                    // Start + Select: game menu
        XCTAssertEqual(model.panel, .menu)
        model.padChanged([])
        model.padChanged([.b]); model.padChanged([])           // B closes it
        XCTAssertNil(model.panel)
        model.padChanged([.home]); model.padChanged([])
        XCTAssertEqual(model.panel, .menu)
        model.openFromMenu(.settings)
        model.back()
        XCTAssertEqual(model.panel, .menu, "panels opened from the menu go back to it")
        model.back()
        XCTAssertNil(model.panel)
        model.emulator.stop()
    }

    func testCustomPictures() throws {
        let library = Library(root: temp.appending(path: "Library"))
        library.importFiles([try makeFile("Game.gba")])
        let covers = Covers(library: library, store: defaults())
        let rom = try XCTUnwrap(library.roms.first)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 600, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = temp.appending(path: "art.png")
        try rep.representation(using: .png, properties: [:])!.write(to: png)
        XCTAssertFalse(covers.hasCustom(rom))
        XCTAssertTrue(covers.setCustom(png, for: rom))
        XCTAssertTrue(covers.hasCustom(rom))
        XCTAssertEqual(try XCTUnwrap(covers.image(for: rom)).representations.first?.pixelsWide, 640, "stored scaled down")
        XCTAssertFalse(covers.setCustom(temp.appending(path: "nope.png"), for: rom))
        covers.removeCustom(rom)
        XCTAssertNil(covers.image(for: rom))
    }

    func testColorCorrectionAndGhosting() {
        func pixel(_ bgra: UInt32) -> Data { withUnsafeBytes(of: bgra.littleEndian) { Data($0) } }
        func value(_ data: Data) -> UInt32 { data.withUnsafeBytes { $0.load(as: UInt32.self) } }
        var white = pixel(0xFFFFFFFF)
        Emulator.correctColors(&white, width: 1, height: 1)
        let w = value(white)
        XCTAssertEqual(Double((w >> 16) & 0xFF), 255 * 0.94, accuracy: 3, "white gets a touch darker, like the real screen")
        XCTAssertEqual(Int((w >> 16) & 0xFF), Int(w & 0xFF), accuracy: 2, "and stays neutral")
        var red = pixel(0xFFFF0000)
        Emulator.correctColors(&red, width: 1, height: 1)
        XCTAssertGreaterThan((value(red) >> 8) & 0xFF, 0, "pure red bleeds a little into green")
        var a = pixel(0xFF000000 | 0xC8C8C8)
        let b = pixel(0xFF000000 | 0x646464)
        Emulator.blend(&a, with: b)
        XCTAssertEqual(value(a) & 0xFF, (0xC8 + 0x64) / 2, accuracy: 1)
    }

    func testUndoLoadAndSaveFileImportExport() throws {
        let rom = try testROM(Self.gba)
        let emulator = makeEmulator()
        emulator.windowVisible = true
        emulator.showingGame = true
        emulator.play(rom)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(emulator.saveState("1"))
        XCTAssertFalse(emulator.canUndoLoad)
        XCTAssertTrue(emulator.loadState("1"))
        XCTAssertTrue(emulator.canUndoLoad)
        emulator.undoLoad()
        XCTAssertFalse(emulator.canUndoLoad)
        XCTAssertTrue(emulator.handleKey(8, down: true), "C = turbo A")
        XCTAssertTrue(emulator.handleKey(8, down: false))
        XCTAssertTrue(emulator.handleKey(14, down: true), "E = slow motion")
        XCTAssertTrue(emulator.slowMotion)
        XCTAssertEqual(emulator.currentSpeed, 0.5)
        emulator.stop()

        // Import a save from another emulator: it lands where the game reads it, and the resume point is dropped.
        let sav = temp.appending(path: "from-elsewhere.sav")
        try Data(repeating: 0xAB, count: 32).write(to: sav)
        XCTAssertNotNil(emulator.resumeThumbnail(for: rom), "the stop above saved a resume point")
        try emulator.importSave(from: sav, for: rom)
        XCTAssertEqual(try Data(contentsOf: emulator.saveFile(for: rom)), Data(repeating: 0xAB, count: 32))
        XCTAssertNil(emulator.resumeThumbnail(for: rom))
        let out = temp.appending(path: "exported.sav")
        try emulator.exportSave(for: rom, to: out)
        XCTAssertEqual(try Data(contentsOf: out), Data(repeating: 0xAB, count: 32))
    }

    func testFiltersStretchToWhatYouHave() throws {
        let library = Library(root: temp.appending(path: "Library"))
        library.importFiles([try makeFile("A.gba"), try makeFile("B.nds")])
        let model = makeModel(library: library)
        XCTAssertEqual(model.filters, [.all, .system(.gba), .system(.nds)], "only GBA and DS → three segments")
        library.toggleFavorite(library.roms[0])
        XCTAssertEqual(model.filters.count, 4)
        model.cycleFilter(-1)
        XCTAssertEqual(model.filter, .system(.nds), "wraps around")
    }
}

final class SmallWindowTests: XCTestCase {
    func testSmallWindowsScaleTheDesignInsteadOfCuttingIt() {
        XCTAssertEqual(FitToWindow<EmptyView>.scale(for: CGSize(width: 900, height: 900), design: DesignSize.page), 1, "big windows never scale up")
        XCTAssertEqual(FitToWindow<EmptyView>.scale(for: CGSize(width: 380, height: 900), design: DesignSize.page), 380 / 450, accuracy: 0.001)
        XCTAssertEqual(FitToWindow<EmptyView>.scale(for: CGSize(width: 900, height: 300), design: DesignSize.page), 300 / 600, accuracy: 0.001)
        XCTAssertEqual(FitToWindow<EmptyView>.scale(for: CGSize(width: 700, height: 420), design: DesignSize.scrollingPage), 1,
                       "a wide, short library just scrolls")
        XCTAssertEqual(FitToWindow<EmptyView>.scale(for: .zero, design: DesignSize.page), 1)
    }
}

final class WindowSizeTests: EmulatorTestCase {
    /// A window once got saved at 159×304 and came back that small, cut off. It must never get below the minimum.
    @MainActor
    func testWindowNeverGetsTooSmallEvenWithABadSavedSize() throws {
        let store = defaults()
        store.set(true, forKey: "MenuBarEmulator.onboarded")
        store.set(NSStringFromSize(NSSize(width: 159, height: 304)), forKey: "MenuBarEmulator.homeSize")
        let model = makeModel(store: store)
        let window = FloatingWindow(model: model, store: store)
        window.show(.floating)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let panel = window.panelWindow
        XCTAssertGreaterThanOrEqual(panel.frame.width, FloatingWindow.minHomeSize.width, "the bad saved size is repaired")
        XCTAssertGreaterThanOrEqual(panel.frame.height, FloatingWindow.minHomeSize.height)

        // Dragging it tiny stops at the minimum.
        XCTAssertEqual(window.windowWillResize(panel, to: NSSize(width: 150, height: 200)), NSSize(width: 380, height: 480))
        XCTAssertEqual(window.windowWillResize(panel, to: NSSize(width: 700, height: 300)), NSSize(width: 700, height: 480))

        // Even if something squeezes it anyway, the size that gets saved is never below the minimum.
        panel.setContentSize(NSSize(width: 150, height: 150))
        window.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: panel))
        let saved = try XCTUnwrap(store.string(forKey: "MenuBarEmulator.homeSize").map(NSSizeFromString))
        XCTAssertGreaterThanOrEqual(saved.width, 380)
        XCTAssertGreaterThanOrEqual(saved.height, 480)

        // A game window keeps its shape and its minimum too.
        let gba = CGSize(width: 240, height: 160)
        window.apply(.game(picture: gba), animated: false)
        let minimum = window.minimumSize(for: .game(picture: gba))
        XCTAssertEqual(window.windowWillResize(panel, to: NSSize(width: 100, height: 100)), NSSize(width: minimum.width, height: (minimum.width * 160 / 240).rounded()))
        let big = window.windowWillResize(panel, to: NSSize(width: 960, height: 500))
        XCTAssertEqual(big.width / big.height, 1.5, accuracy: 0.01, "keeps the GBA shape")
        window.apply(.home, animated: false)
        XCTAssertGreaterThanOrEqual(panel.frame.width, 380)
        window.hide()
    }

    /// A MacBook sitting under a monitor: clicking the icon on the MacBook's menu bar opened the window up on
    /// the monitor; it has to open under the icon on the screen that was clicked.
    @MainActor
    func testOpensOnTheScreenThatWasUsed() {
        let monitor = NSRect(x: 0, y: 0, width: 2560, height: 1440)
        let monitorVisible = NSRect(x: 0, y: 0, width: 2560, height: 1415)
        let macbook = NSRect(x: 600, y: -982, width: 1512, height: 982) // below the monitor
        let macbookVisible = NSRect(x: 600, y: -982, width: 1512, height: 945)
        let icon = NSRect(x: 2300, y: 1415, width: 30, height: 25) // AppKit reports the icon on the monitor's menu bar
        let size = CGSize(width: 460, height: 620)

        let frame = FloatingWindow.anchored(size, icon: icon, iconScreen: monitor, screen: macbook, visible: macbookVisible)
        XCTAssertTrue(macbookVisible.contains(frame), "\(frame) should be on the MacBook")
        XCTAssertEqual(frame.maxY, macbookVisible.maxY - 6, "just under the MacBook's menu bar")
        XCTAssertEqual(frame.midX, macbook.maxX - (monitor.maxX - icon.midX), accuracy: 1, "under the icon there")
        let same = FloatingWindow.anchored(size, icon: icon, iconScreen: monitor, screen: monitor, visible: monitorVisible)
        XCTAssertEqual(same.midX, icon.midX, accuracy: 1, "on the icon's own screen it's right under it, as before")
        XCTAssertEqual(same.maxY, monitorVisible.maxY - 6)

        // The floating window comes to the screen you're on, at the same spot.
        let floating = NSRect(x: 100, y: 700, width: 460, height: 620)
        let moved = FloatingWindow.moved(floating, from: monitorVisible, to: macbookVisible)
        XCTAssertTrue(macbookVisible.contains(moved))
        XCTAssertEqual(moved.minX - macbookVisible.minX, floating.minX - monitorVisible.minX)
        XCTAssertEqual(macbookVisible.maxY - moved.maxY, monitorVisible.maxY - floating.maxY)
        XCTAssertEqual(FloatingWindow.moved(floating, from: monitorVisible, to: monitorVisible), floating)
    }
}

final class FactoryResetTests: EmulatorTestCase {
    func testResetClearsEverySettingAndNothingElse() throws {
        let store = defaults()
        store.set(true, forKey: "MenuBarEmulator.onboarded")
        store.set("keep me", forKey: "SomethingElse")
        let library = Library(root: temp.appending(path: "Library"))
        library.importFiles([try makeFile("Game.gba")])
        let model = makeModel(library: library, store: store)
        model.prefs.popOutShortcut = nil
        model.prefs.pauseWhenHidden = false
        model.controls.assign(Controls.Key(code: 6, name: "Z"), to: .a)
        model.themes.save(CustomTheme(name: "Mine", top: 0x101010, accent: 0xFF0000))
        model.display.layout = .hybrid
        model.play(library.roms[0]) // fake ROM: fails to start, which is fine here
        var relaunched = false
        model.relaunch = { relaunched = true }

        model.factoryReset(eraseLibrary: false)
        XCTAssertTrue(relaunched, "the app restarts so everything reloads fresh")
        XCTAssertTrue(store.dictionaryRepresentation().keys.filter { $0.hasPrefix(FactoryReset.prefix) }.isEmpty)
        XCTAssertEqual(store.string(forKey: "SomethingElse"), "keep me", "only the app's own settings")
        XCTAssertEqual(library.roms.count, 1, "games stay unless you ask")

        let fresh = makeModel(library: library, store: store)
        XCTAssertEqual(fresh.screen, .onboarding, "the welcome tour comes back")
        XCTAssertEqual(fresh.prefs.popOutShortcut, .optionP)
        XCTAssertTrue(fresh.prefs.pauseWhenHidden)
        XCTAssertEqual(fresh.controls.action(for: 7), .a)
        XCTAssertTrue(fresh.themes.custom.isEmpty)
        XCTAssertEqual(fresh.display.layout, .stacked)
        XCTAssertTrue(fresh.openGames.isEmpty)
    }

    func testResetCanAlsoMoveGamesAndSavesToTheTrash() throws {
        let name = "MenuBarEmulatorTest-\(UUID().uuidString)"
        let library = Library(root: temp.appending(path: name))
        library.importFiles([try makeFile("Game.gba")])
        let model = makeModel(library: library)
        model.factoryReset(eraseLibrary: true)
        XCTAssertTrue(library.roms.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.root.path))
        // It went to the Trash (recoverable). Don't leave test files there.
        let trash = try XCTUnwrap(FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first)
        let trashed = trash.appending(path: name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path), "recoverable from the Trash")
        try? FileManager.default.removeItem(at: trashed)
    }
}

final class LayoutAndOrderTests: EmulatorTestCase {
    func testKeyboardLayouts() {
        let store = defaults()
        let controls = Controls(store: store)
        XCTAssertEqual(controls.layout, .classic, "Classic is the default")
        for layout in Controls.Layout.allCases {
            let codes = layout.bindings.values.map(\.code)
            XCTAssertEqual(layout.bindings.count, Controls.Action.allCases.count, "\(layout) binds every action")
            XCTAssertEqual(Set(codes).count, codes.count, "\(layout): no two actions share a key")
            XCTAssertFalse(codes.contains(Controls.escape), "\(layout): Esc stays free for going back")
        }
        controls.apply(.wasd)
        XCTAssertEqual(controls.action(for: 13), .up) // W
        XCTAssertEqual(controls.action(for: 37), .a) // L
        XCTAssertEqual(controls.action(for: 40), .b) // K
        XCTAssertNil(controls.action(for: 126), "the arrows are free in WASD")
        XCTAssertEqual(Controls(store: store).layout, .wasd, "saved")
        controls.apply(.mgba)
        XCTAssertEqual(controls.action(for: 0), .l) // A, like mGBA
        XCTAssertEqual(controls.action(for: 1), .r) // S
        controls.assign(Controls.Key(code: 6, name: "Z"), to: .a)
        XCTAssertNil(controls.layout, "changing a key by hand makes it custom")
        controls.reset()
        XCTAssertEqual(controls.layout, .classic)
    }

    func testDraggedOrderSticks() throws {
        let root = temp.appending(path: "Lib")
        let library = Library(root: root)
        let names = ["Alpha.gba", "Bravo.gba", "Charlie.gba", "Delta.gba"]
        library.importFiles(try names.map { try makeFile($0) })
        XCTAssertEqual(library.roms.map(\.lastPathComponent), names, "A–Z until you move something")
        library.move(library.roms[3], to: library.roms[0])
        XCTAssertEqual(library.roms.map(\.lastPathComponent), ["Delta.gba", "Alpha.gba", "Bravo.gba", "Charlie.gba"], "Delta to the front")
        library.move(library.roms[1], to: library.roms[3])
        let order = ["Delta.gba", "Bravo.gba", "Charlie.gba", "Alpha.gba"]
        XCTAssertEqual(library.roms.map(\.lastPathComponent), order, "Alpha into Charlie's spot")
        XCTAssertEqual(Library(root: root).roms.map(\.lastPathComponent), order, "remembered")
        library.importFiles([try makeFile("Aardvark.gba")])
        XCTAssertEqual(library.roms.last?.lastPathComponent, "Aardvark.gba", "new games go at the end")
    }

    @MainActor
    /// Holding and dragging a game moves it (and doesn't launch it); a plain click still plays.
    func testDraggingAGameInTheWindow() throws {
        let store = defaults()
        store.set(true, forKey: "MenuBarEmulator.onboarded")
        let library = Library(root: temp.appending(path: "Lib"))
        library.importFiles(try ["Alpha.gba", "Bravo.gba", "Charlie.gba", "Delta.gba"].map { try makeFile($0) })
        let m = makeModel(library: library, store: store)
        let size = CGSize(width: 460, height: 620)
        let hosting = NSHostingView(rootView: RootView(model: m, window: nil))
        hosting.sizingOptions = []
        let panel = EmulatorPanel(contentRect: NSRect(origin: CGPoint(x: 80, y: 80), size: size),
                                  styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.contentView = hosting
        panel.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint) {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: p.x, y: size.height - p.y), modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            panel.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        let a = CGPoint(x: 84, y: 250), c = CGPoint(x: 376, y: 250)
        mouse(.leftMouseDown, a)
        for t in 1...12 { mouse(.leftMouseDragged, CGPoint(x: a.x + (c.x - a.x) * CGFloat(t) / 12, y: a.y + CGFloat(t))) }
        mouse(.leftMouseUp, CGPoint(x: c.x, y: a.y + 12))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(library.roms.map(\.lastPathComponent), ["Bravo.gba", "Charlie.gba", "Alpha.gba", "Delta.gba"])
        XCTAssertNil(m.toast, "dropping it doesn't launch the game")
        XCTAssertEqual(m.screen, .library)
        mouse(.leftMouseDown, a)
        mouse(.leftMouseUp, a)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNotNil(m.toast, "a plain click still plays (these fake games can't start, so it says so)")
        panel.orderOut(nil)
    }
}

final class LofiTests: EmulatorTestCase {
    func testTapeIsHalfAnHourOfOriginalMusic() {
        let score = LofiScore()
        XCTAssertEqual(Double(score.length) / LofiScore.sampleRate / 60, 30, accuracy: 1, "a 30-minute tape")
        XCTAssertEqual(score.trackStarts.count, 12)
        XCTAssertEqual(score.events.map(\.time), score.events.map(\.time).sorted())
        let notes = score.events.filter { ![.kick, .snare, .hat, .openHat, .track].contains($0.kind) }
        XCTAssertTrue(notes.allSatisfy { (24...100).contains($0.note) && $0.length > 0 && $0.velocity > 0 })
        XCTAssertGreaterThan(notes.filter { $0.kind == .lead }.count, 500, "plenty of tune")
        XCTAssertEqual(LofiScore().events.count, score.events.count, "the same tape every time")
    }

    func testFadesInSlowlyOutQuicklyAndNeverClips() {
        let synth = LofiSynth(score: LofiScore(), start: 13 * Int(LofiScore.sampleRate))
        let second = Int(LofiScore.sampleRate)
        var left = [Float](repeating: 0, count: second), right = left
        var rendered = 0.0, busy = 0.0
        func play(_ seconds: Int) -> (peak: Float, rms: Float) {
            var peak: Float = 0, sum: Float = 0, finite = true
            for _ in 0..<seconds {
                let start = CFAbsoluteTimeGetCurrent()
                left.withUnsafeMutableBufferPointer { l in
                    right.withUnsafeMutableBufferPointer { r in
                        // Real-time sized chunks, like the audio thread asks for.
                        for offset in stride(from: 0, to: second, by: 512) {
                            synth.render(left: l.baseAddress! + offset, right: r.baseAddress! + offset, count: min(512, second - offset))
                        }
                    }
                }
                busy += CFAbsoluteTimeGetCurrent() - start
                rendered += 1
                for i in 0..<second {
                    finite = finite && left[i].isFinite && right[i].isFinite
                    peak = max(peak, abs(left[i]), abs(right[i]))
                    sum += left[i] * left[i]
                }
            }
            XCTAssertTrue(finite, "no NaNs")
            return (peak, (sum / Float(seconds * second)).squareRoot())
        }
        XCTAssertEqual(play(1).peak, 0, "silent until asked")
        XCTAssertEqual(synth.position, 13 * second, "and the tape doesn't move")
        synth.target = 0.8
        let first = play(1)
        _ = play(3)
        let later = play(4)
        XCTAssertLessThan(first.rms, later.rms * 0.2, "fades in slowly")
        XCTAssertGreaterThan(later.rms, 0.01, "actually plays")
        XCTAssertLessThan(later.peak, 1, "never clips")
        synth.target = 0
        _ = play(2)
        XCTAssertEqual(synth.fade, 0, "faded out within two seconds")
        let parked = synth.position
        XCTAssertEqual(play(1).peak, 0)
        XCTAssertEqual(synth.position, parked, "keeps its place for next time")
        print("Lo-fi renders \(Int(rendered / busy))× faster than real time; levels rms \(later.rms) peak \(later.peak)")
        XCTAssertGreaterThan(rendered / busy, 3, "fast enough to never stutter, even in a debug build")
    }

    func testPlaysWhenTheUserChose() throws {
        let model = makeModel()
        let emulator = model.emulator
        model.windowOnScreen = true
        XCTAssertFalse(model.prefs.lofiOn, "off until you turn it on")
        XCTAssertTrue(model.prefs.lofiSpedUp, "plays while fast-forwarding out of the box")
        XCTAssertEqual(model.lofiVolume, 0)
        model.toggleLofi()
        XCTAssertTrue(model.prefs.lofiOn)
        XCTAssertGreaterThan(model.lofiVolume, 0, "on: plays in the library")
        XCTAssertNotNil(model.toast, "the switch says what it did")
        model.windowOnScreen = false
        XCTAssertEqual(model.lofiVolume, 0, "window closed and no game: quiet")
        model.prefs.lofiInBackground = true
        XCTAssertGreaterThan(model.lofiVolume, 0, "unless it's set to keep playing in the background")
        model.prefs.lofiInBackground = false
        model.toggleLofi()

        emulator.windowVisible = true
        emulator.showingGame = true
        emulator.play(try testROM(Self.gba))
        XCTAssertTrue(emulator.isRunning)
        XCTAssertEqual(model.lofiVolume, 0, "music off at normal speed")
        emulator.fastForward = true
        XCTAssertGreaterThan(model.lofiVolume, 0, "sped up")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertGreaterThan(model.lofi.volume, 0, "the player follows along")
        model.toggleLofiSpedUp()
        XCTAssertEqual(model.lofiVolume, 0, "the ⏩ switch turns that off")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(model.lofi.volume, 0, "and it fades out")
        emulator.fastForward = false
        let sound = emulator.soundOn
        defer { emulator.soundOn = sound }
        emulator.soundOn = false
        model.prefs.lofiOn = true
        XCTAssertEqual(model.lofiVolume, 0, "mute silences everything, lo-fi included")
        emulator.soundOn = true
        XCTAssertGreaterThan(model.lofiVolume, 0, "music on plays in games too")
        model.toggleSilentGames()
        XCTAssertEqual(model.lofiVolume, 0, "No sound in games silences the lo-fi while a game's up")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(emulator.silenced, "and the game's own sound")
        model.windowOnScreen = true
        model.screen = .library
        emulator.showingGame = false
        XCTAssertGreaterThan(model.lofiVolume, 0, "back in the library the lo-fi plays again")
        model.toggleSilentGames()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(emulator.silenced)
        model.prefs.lofiOn = false
        emulator.stop()
    }
}

// MARK: - Release audit regressions

final class ReleaseRegressionTests: EmulatorTestCase {
    func testControllerNeverOpensAGameHiddenByTheFilter() throws {
        let library = Library(root: temp.appending(path: "Library"))
        for (path, name) in [(Self.gb, "Alpha.gb"), (Self.gba, "Bravo.gba")] {
            let copy = temp.appending(path: name)
            try Data(contentsOf: try testROM(path)).write(to: copy)
            library.importFiles([copy])
        }
        let store = defaults()
        store.set(true, forKey: "MenuBarEmulator.onboarded")
        let model = makeModel(library: library, store: store)
        model.selection = library.roms.first { $0.pathExtension == "gb" }
        model.filter = .system(.gba)

        model.padChanged([.a])
        model.padChanged([])
        XCTAssertEqual(model.emulator.game?.lastPathComponent, "Bravo.gba")
        model.emulator.stop()
    }

    func testSameNamedSystemsHaveIndependentFilesAndIgnoreAmbiguousLegacyData() throws {
        let library = Library(root: temp.appending(path: "Library"))
        for (path, name) in [(Self.gb, "Same.gb"), (Self.gba, "Same.gba")] {
            let copy = temp.appending(path: name)
            try Data(contentsOf: try testROM(path)).write(to: copy)
            library.importFiles([copy])
        }
        let gb = try XCTUnwrap(library.roms.first { $0.pathExtension == "gb" })
        let gba = try XCTUnwrap(library.roms.first { $0.pathExtension == "gba" })
        let emulator = makeEmulator(library)
        XCTAssertNotEqual(emulator.saveFile(for: gb), emulator.saveFile(for: gba))

        library.setCheats([Cheat(name: "GB only", code: "1234")], for: gb)
        XCTAssertEqual(library.cheats(for: gb).map(\.name), ["GB only"])
        XCTAssertTrue(library.cheats(for: gba).isEmpty)

        let states = library.root.appending(path: "States")
        try FileManager.default.createDirectory(at: states, withIntermediateDirectories: true)
        try Data("old shared state".utf8).write(to: states.appending(path: "Same.1.state"))
        emulator.play(gb)
        XCTAssertFalse(emulator.hasState("1"), "an extension-less state can't be assigned to either same-named game")
        emulator.stop()

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = temp.appending(path: "cover.png")
        try rep.representation(using: .png, properties: [:])!.write(to: png)
        let covers = Covers(library: library, store: defaults())
        XCTAssertTrue(covers.setCustom(png, for: gb))
        XCTAssertTrue(covers.hasCustom(gb))
        XCTAssertFalse(covers.hasCustom(gba))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.root.appending(path: "Covers/Same.gb.custom.png").path))
    }

    func testUnambiguousLegacyStatesAndSavesStillWork() throws {
        let library = Library(root: temp.appending(path: "Library"))
        let copy = temp.appending(path: "Legacy.gba")
        try Data(contentsOf: try testROM(Self.gba)).write(to: copy)
        library.importFiles([copy])
        let rom = try XCTUnwrap(library.roms.first)
        let emulator = makeEmulator(library)
        emulator.play(rom)
        let states = library.root.appending(path: "States")
        try FileManager.default.createDirectory(at: states, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: states.appending(path: "Legacy.1.state"))
        XCTAssertTrue(emulator.hasState("1"))
        emulator.stop()

        // With no current game, exporting an old save doesn't first write a new-format save over it.
        try FileManager.default.removeItem(at: emulator.saveFile(for: rom))
        let saves = library.root.appending(path: "Saves")
        let old = Data(repeating: 0x5A, count: 32)
        try old.write(to: saves.appending(path: "Legacy.srm"))
        let exported = temp.appending(path: "exported.sav")
        try emulator.exportSave(for: rom, to: exported)
        XCTAssertEqual(try Data(contentsOf: exported), old)
    }

    func testEmptyImportedSaveDoesNotCrashOnLaunch() throws {
        let library = Library(root: temp.appending(path: "Library"))
        let copy = temp.appending(path: "Empty.gba")
        try Data(contentsOf: try testROM(Self.gba)).write(to: copy)
        library.importFiles([copy])
        let rom = try XCTUnwrap(library.roms.first)
        let emulator = makeEmulator(library)
        try Data().write(to: emulator.saveFile(for: rom))
        emulator.play(rom)
        XCTAssertEqual(emulator.game, rom)
        emulator.stop()
    }

    @MainActor
    func testSwappedSeparateTouchScreenUsesTheTopHalf() {
        let size = CGSize(width: 256, height: 192)
        let top = ScreenView.normalizedTouch(CGPoint(x: 128, y: 48), in: size, crop: .top)
        let bottom = ScreenView.normalizedTouch(CGPoint(x: 128, y: 48), in: size, crop: .bottom)
        XCTAssertEqual(top.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(top.y, 0.125, accuracy: 0.001)
        XCTAssertEqual(bottom.y, 0.625, accuracy: 0.001)
        let view = ScreenView()
        view.crop = .top
        view.touchScreen = true
        XCTAssertFalse(view.mouseDownCanMoveWindow)
    }

    func testIPSFinalSizeCanExtendWithZeroes() throws {
        let patch = Data(Array("PATCHEOF".utf8) + [0, 0, 5])
        XCTAssertEqual(try Patcher.apply(patch, to: Data([1])), Data([1, 0, 0, 0, 0]))
    }

    func testOversizedPatchNumbersAreRejectedInsteadOfTrapping() throws {
        let patch = Data(Array("BPS1".utf8) + varint(UInt64(Int.max) + 1) + varint(0) + varint(0)
            + [UInt8](repeating: 0, count: 12))
        XCTAssertNil(Patcher.requiredSource(of: patch))
        XCTAssertThrowsError(try Patcher.apply(patch, to: Data())) { XCTAssertEqual($0 as? Patcher.PatchError, .corrupt) }
    }

    private func varint(_ value: UInt64) -> [UInt8] {
        var data = value, out: [UInt8] = []
        while true {
            let x = UInt8(data & 0x7F)
            data >>= 7
            if data == 0 { out.append(0x80 | x); return out }
            out.append(x)
            data -= 1
        }
    }
}

final class StylusTests: EmulatorTestCase {
    /// Tapping the DS touch screen shows a stylus dot right under the pointer, a trail while dragging, and fades on release.
    @MainActor
    func testTouchScreenShowsTheStylus() throws {
        let size = CGSize(width: 512, height: 384)
        let view = ScreenView(frame: NSRect(origin: .zero, size: size))
        view.touchScreen = true
        view.crop = .bottom
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 100, y: 100), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint) {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: p.x, y: size.height - p.y), modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }
        XCTAssertTrue(view.tip.isHidden, "nothing until you touch")
        mouse(.leftMouseDown, CGPoint(x: 100, y: 120))
        XCTAssertFalse(view.tip.isHidden)
        XCTAssertEqual(view.tip.position.x, 100, accuracy: 0.5)
        XCTAssertEqual(view.tip.position.y, 120, accuracy: 0.5, "right under the pointer (top-down, like the view)")
        let layers = view.layer?.sublayers?.count ?? 0
        for x in stride(from: 110, through: 200, by: 10) { mouse(.leftMouseDragged, CGPoint(x: CGFloat(x), y: 120)) }
        XCTAssertEqual(view.tip.position.x, 200, accuracy: 0.5, "follows the drag")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertGreaterThan(view.layer?.sublayers?.count ?? 0, layers, "leaves a trail")
        }
        mouse(.leftMouseUp, CGPoint(x: 200, y: 120))
        XCTAssertEqual(view.tip.opacity, 0, "fades away on release")
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        XCTAssertLessThanOrEqual(view.layer?.sublayers?.count ?? 0, 2, "the ripple and trail clean themselves up")

        // The release once never reached the view and the dot stayed. It goes once the button's actually up.
        mouse(.leftMouseDown, CGPoint(x: 300, y: 200))
        XCTAssertEqual(view.tip.opacity, 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(view.tip.opacity, 1, "a short pause with drags in between doesn't make it flicker")
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(view.tip.opacity, 0, "no stuck dot without a mouse-up")
        window.orderOut(nil)
    }
}

final class BadROMTests: EmulatorTestCase {
    /// Playing a game, closing it, then opening a broken GBA file used to crash inside mGBA (a double free).
    func testBrokenROMAfterARealGameDoesNotCrash() throws {
        let emulator = makeEmulator()
        emulator.windowVisible = true
        emulator.showingGame = true
        emulator.play(try testROM(Self.gba))
        XCTAssertTrue(emulator.isRunning)
        emulator.stop()
        emulator.play(try makeFile("Broken.gba", "not a game"))
        XCTAssertNotNil(emulator.error, "says it couldn't start")
        XCTAssertNil(emulator.game)
        emulator.play(try testROM(Self.gba))
        XCTAssertTrue(emulator.isRunning, "and a real game still starts after that")
        emulator.stop()
    }
}

final class FastForwardTests: EmulatorTestCase {
    func testOnlyAsksForFramesThatFitInARefresh() {
        XCTAssertEqual(Emulator.framesThatFit(budget: 0.0117, secondsPerFrame: 0.004), 2)
        XCTAssertEqual(Emulator.framesThatFit(budget: 0.0117, secondsPerFrame: 0.05), 1, "always at least one")
        XCTAssertGreaterThanOrEqual(Emulator.framesThatFit(budget: 0.0117, secondsPerFrame: 0.0005), 8, "a fast core still gets its full 8×")
    }

    /// A DS game at 8× used to stutter. Every refresh has to stay short so the picture stays smooth.
    func testDSAtEightTimesStaysSmooth() throws {
        let emulator = makeEmulator()
        emulator.windowVisible = true
        emulator.showingGame = true
        emulator.play(try testROM(Self.ds))
        XCTAssertTrue(emulator.isRunning)
        let speed = emulator.speed
        defer { emulator.speed = speed; emulator.stop() }
        emulator.speed = 8
        emulator.fastForward = true
        RunLoop.main.run(until: Date().addingTimeInterval(1)) // settle and learn the core's pace
        emulator.longestTick = 0
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        XCTAssertLessThan(emulator.longestTick, 0.008, "the window's refresh never waits on the core, so it doesn't stutter")
        emulator.showFPS = true
        defer { emulator.showFPS = false }
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertGreaterThan(emulator.measuredFPS, 60 * 6, "and it really runs several times faster")
    }
}

final class FastForwardBatchTests: EmulatorTestCase {
    /// Saving, loading and stopping in the middle of fast-forward must wait for the background batch.
    func testSaveLoadAndStopDuringFastForward() throws {
        let emulator = makeEmulator()
        emulator.windowVisible = true
        emulator.showingGame = true
        emulator.play(try testROM(Self.gba))
        let speed = emulator.speed
        defer { emulator.speed = speed }
        emulator.speed = 8
        emulator.fastForward = true
        for _ in 0..<15 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertTrue(emulator.saveState("1", announce: false))
            XCTAssertTrue(emulator.loadState("1", announce: false))
        }
        XCTAssertNil(emulator.error)
        emulator.stop()
        XCTAssertNil(emulator.game)
    }
}

final class AudioPlayerTests: XCTestCase {
    /// Simulates a game feeding sound frame by frame while the speakers pull it in 512-sample chunks.
    /// `late` delays every 40th frame (a busy moment), `drift` makes the game's clock run fast.
    private func play(seconds: Double, late: Double, drift: Double) -> (underruns: Int, skips: Int) {
        let rate = 32768.0
        let player = AudioPlayer()
        player.prepare(sampleRate: rate)
        let frame = [Int16](repeating: 800, count: 549 * 2) // one GBA frame of stereo
        let framePeriod = 549 / rate / (1 + drift), pull = 512 / rate
        var left = [Float](repeating: 0, count: 512), right = left
        var nextFrame = 0.0, nextPull = 0.0, frameIndex = 0
        var t = 0.0
        while t < seconds {
            while nextFrame + (frameIndex % 40 == 39 ? late : 0) <= t {
                frame.withUnsafeBufferPointer { player.push($0.baseAddress!, count: $0.count) }
                nextFrame += framePeriod
                frameIndex += 1
            }
            if nextPull <= t {
                left.withUnsafeMutableBufferPointer { l in
                    right.withUnsafeMutableBufferPointer { r in player.render(left: l.baseAddress!, right: r.baseAddress!, count: 512) }
                }
                nextPull += pull
            }
            t += 0.0005
        }
        return (player.underruns, player.skips)
    }

    func testBusyMomentsDontGlitch() {
        let result = play(seconds: 20, late: 0.03, drift: 0)
        XCTAssertEqual(result.underruns, 0, "a 30 ms hiccup never runs it dry")
        XCTAssertEqual(result.skips, 0)
    }

    func testClockDriftIsAbsorbed() {
        let fast = play(seconds: 60, late: 0, drift: 0.003)
        XCTAssertEqual(fast.skips, 0, "a game clock 0.3% fast never piles up into a skip")
        let slow = play(seconds: 60, late: 0, drift: -0.003)
        XCTAssertEqual(slow.underruns, 0, "or 0.3% slow into a gap")
    }
}

final class AudioRateTests: EmulatorTestCase {
    /// Pokémon switches the GBA's sound to a higher rate mid-game; the player has to follow.
    func testFollowsTheGamesSoundRate() throws {
        let emulator = makeEmulator()
        emulator.windowVisible = true
        emulator.showingGame = true
        emulator.play(try testROM(Self.gba))
        emulator.adoptTiming(fps: 59.7275, sampleRate: 65536)
        XCTAssertEqual(emulator.audioRate, 65536)
        XCTAssertTrue(emulator.isRunning)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(emulator.error)
        emulator.stop()
    }

    func testSpeedSnapsToTheSlider() {
        let emulator = makeEmulator()
        let saved = emulator.speed
        defer { emulator.speed = saved }
        emulator.speed = 16
        XCTAssertEqual(emulator.speed, 16)
        emulator.speed = 7.2
        XCTAssertTrue(Emulator.speeds.contains(emulator.speed), "lands on a slider stop")
        emulator.speed = 40
        XCTAssertEqual(emulator.speed, 16, "16× is the top")
    }
}

final class DSCursorTests: EmulatorTestCase {
    /// melonDS DS used to draw a little square where the stylus last touched and leave it there after letting go.
    func testTappingTheTouchScreenLeavesNoDotBehind() throws {
        let emulator = makeEmulator()
        emulator.windowVisible = true
        emulator.showingGame = true
        emulator.play(try testROM(Self.ds))
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let before = try XCTUnwrap(emulator.frame)
        let point = CGPoint(x: 0.7, y: 0.85) // on the bottom screen
        let center = CGPoint(x: point.x * CGFloat(before.width), y: point.y * CGFloat(before.height))
        emulator.touch(normalized: point, down: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let during = try XCTUnwrap(emulator.frame)
        emulator.touch(normalized: point, down: false)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let after = try XCTUnwrap(emulator.frame)
        XCTAssertEqual(Self.changedPixels(before, during, around: center, radius: 8), 0, "no square drawn under the stylus")
        XCTAssertEqual(Self.changedPixels(before, after, around: center, radius: 8), 0, "and nothing left behind after letting go")
        emulator.stop()
    }

    static func changedPixels(_ a: CGImage, _ b: CGImage, around center: CGPoint, radius: Int) -> Int {
        func pixels(_ image: CGImage) -> [UInt32] {
            var data = [UInt32](repeating: 0, count: image.width * image.height)
            let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return data
        }
        let pa = pixels(a), pb = pixels(b)
        var count = 0
        for y in max(0, Int(center.y) - radius)..<min(a.height, Int(center.y) + radius) {
            for x in max(0, Int(center.x) - radius)..<min(a.width, Int(center.x) + radius) where pa[y * a.width + x] != pb[y * a.width + x] {
                count += 1 // the bitmap's first row is the picture's top
            }
        }
        return count
    }
}
