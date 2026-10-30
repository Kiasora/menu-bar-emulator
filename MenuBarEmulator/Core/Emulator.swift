import AppKit
import AVFoundation
import Accelerate
import Observation

/// Hosts one libretro core at a time (mGBA for GB/GBC/GBA, melonDS DS for DS): loads the game, runs frames paced by
/// real time, and turns the core's video/audio/input callbacks into pictures, sound and buttons.
/// Also: save states (the `auto` slot resumes where you left off), rewind, cheats, screenshots and play time.
@Observable
final class Emulator {
    private(set) var game: URL?
    private(set) var error: String?
    private(set) var isRunning = false
    /// The picture's size in pixels. Changes only when the size does, so the window can follow it cheaply.
    private(set) var frameSize: CGSize?
    /// The picture from when the game last paused. Live frames go to frame observers, never through SwiftUI.
    private(set) var snapshot: CGImage?
    /// Bumped whenever a save state is written, so state lists refresh.
    private(set) var stateVersion = 0
    private(set) var isRewinding = false
    private(set) var cheatsSupported = false

    /// The game only runs while all three hold: the window is on screen, the game screen is showing with nothing
    /// over it, and it isn't paused.
    var windowVisible = false { didSet { sync() } }
    var showingGame = false { didSet { sync() } }
    var userPaused = false { didSet { sync() } }

    /// Fast-forward from the key (toggles) or a controller's right trigger (hold). Sound mutes while it's on.
    var fastForward = false
    var holdingFastForward = false
    var speed = UserDefaults.standard.object(forKey: "MenuBarEmulator.speed") as? Double ?? 2 {
        didSet {
            if !Self.speeds.contains(speed) { speed = Self.nearestSpeed(speed) }
            UserDefaults.standard.set(speed, forKey: "MenuBarEmulator.speed")
        }
    }
    /// The fast-forward slider's stops, up to 16×.
    static let speeds: [Double] = [1.5, 2, 3, 4, 5, 6, 8, 10, 12, 16]
    static func nearestSpeed(_ value: Double) -> Double { speeds.min { abs($0 - value) < abs($1 - value) } ?? 2 }
    /// How fast it's really going while fast-forwarding (a heavy DS game can't always reach the speed asked for).
    private(set) var actualSpeed = 1.0

    var soundOn = UserDefaults.standard.object(forKey: "MenuBarEmulator.soundOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(soundOn, forKey: "MenuBarEmulator.soundOn"); applyVolume() }
    }
    var volume = UserDefaults.standard.object(forKey: "MenuBarEmulator.volume") as? Double ?? 0.8 {
        didSet { UserDefaults.standard.set(volume, forKey: "MenuBarEmulator.volume"); applyVolume() }
    }
    var rewindEnabled = UserDefaults.standard.object(forKey: "MenuBarEmulator.rewind") as? Bool ?? true {
        didSet { UserDefaults.standard.set(rewindEnabled, forKey: "MenuBarEmulator.rewind"); configureRewind() }
    }
    /// Half speed, toggled with its key (sound mutes while it's on).
    var slowMotion = false
    /// GBA/GBC color correction: the washed-out, warmer colors of the real screens.
    var colorCorrection = UserDefaults.standard.bool(forKey: "MenuBarEmulator.colorCorrection") {
        didSet { UserDefaults.standard.set(colorCorrection, forKey: "MenuBarEmulator.colorCorrection") }
    }
    /// LCD ghosting: mixes each frame with the last one, like the real screens (some games use it for transparency).
    var frameBlending = UserDefaults.standard.bool(forKey: "MenuBarEmulator.frameBlending") {
        didSet { UserDefaults.standard.set(frameBlending, forKey: "MenuBarEmulator.frameBlending"); previousPixels = nil }
    }
    /// Colors for original (non-Color) Game Boy games.
    var gbPalette = UserDefaults.standard.string(forKey: "MenuBarEmulator.gbPalette") ?? "Grayscale" {
        didSet { UserDefaults.standard.set(gbPalette, forKey: "MenuBarEmulator.gbPalette"); optionsChanged = true }
    }
    static let gbPalettes = ["Grayscale", "DMG Green", "GB Pocket", "GB Light"]
    var showFPS = UserDefaults.standard.bool(forKey: "MenuBarEmulator.showFPS") {
        didSet { UserDefaults.standard.set(showFPS, forKey: "MenuBarEmulator.showFPS") }
    }
    /// Frames per second actually emulated, updated twice a second while Show FPS is on.
    private(set) var measuredFPS = 0.0
    /// The last Load can be taken back (Undo Load).
    private(set) var canUndoLoad = false

    let library: Library
    let controls: Controls
    /// Keys that aren't game buttons or emulator actions (Swap Screens, Show Controls) go to the app.
    @ObservationIgnored var onAppAction: ((Controls.Action) -> Void)?
    @ObservationIgnored var onToast: ((String, String) -> Void)?
    /// Latest picture (thumbnails, screenshots).
    @ObservationIgnored private(set) var frame: CGImage?
    /// Controller buttons, set by the app from GamepadInput.
    @ObservationIgnored var padButtons = Set<UInt32>()

    @ObservationIgnored private var frameObservers: [UUID: (CGImage) -> Void] = [:]
    @ObservationIgnored private var core: Core?
    @ObservationIgnored private var cores: [String: Core] = [:] // dlopen'd once and kept, cores don't like being unloaded
    @ObservationIgnored private var gameData: Data?
    @ObservationIgnored private var fps = 60.0
    @ObservationIgnored private var sampleRate = 32768.0
    @ObservationIgnored private var pixelFormat = RETRO_PIXEL_FORMAT_0RGB1555.rawValue
    @ObservationIgnored private var keyButtons = Set<UInt32>()
    @ObservationIgnored private var pressed = Set<UInt32>()
    @ObservationIgnored private var pointer: (x: Int16, y: Int16, down: Bool) = (0, 0, false)
    @ObservationIgnored private let audio = AudioPlayer()
    @ObservationIgnored private let biosDir: UnsafeMutablePointer<CChar>
    @ObservationIgnored private let saveDir: UnsafeMutablePointer<CChar>
    @ObservationIgnored private var frameDebt = 0.0
    /// How long the core takes per frame (smoothed), so fast-forward only asks for what fits in a refresh.
    @ObservationIgnored private(set) var secondsPerFrame = 0.004
    /// Times the sound ran dry or had to jump ahead, for checking it plays cleanly.
    var audioGlitches: (underruns: Int, skips: Int) { (audio.underruns, audio.skips) }
    /// The sound rate the player is using (it follows the game when the game changes it).
    var audioRate: Double { sampleRate }
    @ObservationIgnored var shownFrames = 0
    /// The longest tick lately (main-thread work), for checking that fast-forward stays smooth.
    @ObservationIgnored var longestTick: CFTimeInterval = 0
    /// Fast-forward runs its frames here, off the main thread, so the window stays smooth while the core uses a whole
    /// CPU core. Everything else that touches the core waits for the batch first (`finishBatch`).
    @ObservationIgnored private let batchQueue = DispatchQueue(label: "MenuBarEmulator.fastForward", qos: .userInteractive)
    @ObservationIgnored private var batchRunning = false
    @ObservationIgnored private var batchGeneration = 0
    /// While a batch runs, the core reads this instead of the live input the main thread keeps changing.
    @ObservationIgnored private var batchInput: (buttons: Set<UInt32>, turbo: Set<UInt32>, pointer: (x: Int16, y: Int16, down: Bool))?
    /// A batch's last picture, handed to the main thread when the batch ends.
    @ObservationIgnored private var batchImage: (image: CGImage, size: CGSize)?
    @ObservationIgnored private var lastTick: CFTimeInterval = 0
    @ObservationIgnored private var drawThisFrame = true
    @ObservationIgnored private var runningSince: CFTimeInterval?
    @ObservationIgnored private var rewindStates: [Data] = []
    @ObservationIgnored private var rewindStateSize = 0
    @ObservationIgnored private var rewindCapacity = 0
    @ObservationIgnored private var framesSinceCapture = 0
    @ObservationIgnored private var rewindDebt = 0.0
    @ObservationIgnored private var holdingRewindKey = false
    @ObservationIgnored private var holdingRewindPad = false
    @ObservationIgnored private var rewindWarned = false
    @ObservationIgnored private var clock: AnyObject? // CADisplayLink (or a Timer if there's no screen)
    @ObservationIgnored private var turboHeld = Set<UInt32>()
    @ObservationIgnored private var frameCounter = 0
    @ObservationIgnored private var previousPixels: Data?
    @ObservationIgnored private var optionsChanged = false
    @ObservationIgnored private var fpsFrames = 0
    @ObservationIgnored private var fpsSince: CFTimeInterval = 0
    @ObservationIgnored private var lastSRAMSave: CFTimeInterval = 0
    @ObservationIgnored private var lastSRAM: Data?
    @ObservationIgnored private var undoState: Data?
    @ObservationIgnored private var cStrings: [String: UnsafeMutablePointer<CChar>] = [:]

    /// Frames between rewind snapshots, and how fast rewind plays back.
    static let rewindInterval = 6
    static let rewindSpeed = 2.0

    init(library: Library, controls: Controls) {
        self.library = library
        self.controls = controls
        let bios = library.root.appending(path: "BIOS"), saves = library.root.appending(path: "Saves")
        for dir in [bios, saves] { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        biosDir = strdup(bios.path)
        saveDir = strdup(saves.path)
    }

    // MARK: Playing

    func play(_ rom: URL) {
        stop()
        error = nil
        let name = GameSystem(rom: rom) == .nds ? "melondsds" : "mgba"
        guard let core = loadCore(name) else { return fail("Couldn't load the \(name) emulator.") }
        // Memory-mapped: big DS ROMs open without copying the whole file first.
        guard let data = try? Data(contentsOf: rom, options: .alwaysMapped) else { return fail("Couldn't read \(rom.lastPathComponent).") }

        activeEmulator = self
        keyButtons = []
        turboHeld = []
        pressed = []
        previousPixels = nil
        undoState = nil
        canUndoLoad = false
        optionsChanged = false
        core.setEnvironment(environmentCallback) // must come before retro_init
        core.setVideoRefresh(videoCallback)
        core.setAudioSample(audioSampleCallback)
        core.setAudioSampleBatch(audioBatchCallback)
        core.setInputPoll(inputPollCallback)
        core.setInputState(inputStateCallback)
        core.initialize()

        let loaded = rom.path.withCString { path in
            data.withUnsafeBytes { bytes in
                var info = retro_game_info(path: path, data: bytes.baseAddress, size: bytes.count, meta: nil)
                return core.loadGame(&info)
            }
        }
        guard loaded else {
            // mGBA's retro_deinit frees a picture buffer that only a successful load creates, and never clears the
            // pointer, so after a failed load it frees the last game's buffer again and crashes. Its retro_init
            // allocates nothing, so skipping the deinit is safe; the next play calls retro_init again.
            if name != "mgba" { core.deinitialize() }
            return fail("The emulator couldn't start \(rom.gameTitle).")
        }

        var av = retro_system_av_info()
        core.getAVInfo(&av)
        fps = av.timing.fps > 0 ? av.timing.fps : 60
        sampleRate = av.timing.sample_rate > 0 ? av.timing.sample_rate : 32768
        gameData = data
        self.core = core
        game = rom
        cheatsSupported = core.cheatReset != nil && core.cheatSet != nil
        loadSRAM()
        if hasState(Self.autoSlot) { loadState(Self.autoSlot, announce: false) } // pick up exactly where you left off
        applyCheats(library.cheats(for: rom))
        configureRewind()
        fastForward = false
        holdingFastForward = false
        slowMotion = false
        lastSRAM = nil
        userPaused = false
        sync()
    }

    /// Saves everything (in-game save, resume point, play time) and unloads the game.
    func stop() {
        finishBatch()
        batchGeneration += 1
        batchRunning = false
        batchInput = nil
        batchImage = nil
        saveSRAM()
        saveState(Self.autoSlot, announce: false)
        recordPlaytime()
        if let core {
            core.unloadGame()
            core.deinitialize()
        }
        core = nil
        sync()
        game = nil
        frame = nil
        frameSize = nil
        snapshot = nil
        gameData = nil
        rewindStates = []
        cheatsSupported = false
    }

    /// Starts or stops the frame timer to match `windowVisible`, `showingGame` and `userPaused`. Every stop saves.
    private func sync() {
        let shouldRun = core != nil && windowVisible && showingGame && !userPaused
        guard shouldRun != isRunning else { return }
        isRunning = shouldRun
        if shouldRun {
            audio.start(sampleRate: sampleRate)
            applyVolume()
            lastTick = CACurrentMediaTime()
            runningSince = lastTick
            lastSRAMSave = lastTick
            fpsSince = lastTick
            fpsFrames = 0
            frameDebt = 0
            startClock()
        } else {
            stopClock()
            audio.stop()
            keyButtons = []
            pointer.down = false
            holdingRewindKey = false
            updateRewind()
            recordPlaytime()
            snapshot = frame
            saveSRAM()
            saveState(Self.autoSlot, announce: false)
        }
    }

    private func tick() {
        guard let core, !batchRunning else { return } // a fast-forward batch is still going; it picks up from there
        let now = CACurrentMediaTime()
        let elapsed = now - lastTick
        lastTick = now
        if isRewinding {
            rewindTick(core, elapsed: elapsed)
            return
        }
        let frames = Self.framesToRun(elapsed: elapsed, fps: fps, speed: currentSpeed, debt: &frameDebt)
        if currentSpeed > 1 {
            if frames > 0 { startBatch(core, owed: frames) }
        } else {
            for i in 0..<frames {
                drawThisFrame = i == frames - 1 // only the last frame of a tick is ever seen
                core.run()
                captureRewindIfDue(core)
            }
            drawThisFrame = true
            fpsFrames += frames
        }
        longestTick = max(longestTick, CACurrentMediaTime() - now)
        housekeeping(now)
    }

    /// Runs about one refresh's worth of fast-forward frames off the main thread, then shows the last one.
    private func startBatch(_ core: Core, owed: Int) {
        let frames = min(owed, Self.framesThatFit(budget: 1.0 / 60, secondsPerFrame: secondsPerFrame))
        batchInput = (keyButtons.union(padButtons), turboHeld, pointer)
        batchRunning = true
        let generation = batchGeneration
        nonisolated(unsafe) let emulator = self // the batch and the main thread never touch the core at the same time
        nonisolated(unsafe) let core = core
        batchQueue.async {
            let started = CACurrentMediaTime()
            for i in 0..<frames {
                emulator.drawThisFrame = i == frames - 1
                core.run()
            }
            emulator.drawThisFrame = true
            let took = CACurrentMediaTime() - started
            DispatchQueue.main.async { emulator.batchEnded(generation: generation, frames: frames, took: took) }
        }
    }

    private func batchEnded(generation: Int, frames: Int, took: Double) {
        guard generation == batchGeneration else { return } // the game stopped meanwhile
        batchRunning = false
        batchInput = nil
        secondsPerFrame = secondsPerFrame * 0.8 + took / Double(frames) * 0.2
        if let shown = batchImage {
            batchImage = nil
            publish(shown.image, size: shown.size)
        }
        fpsFrames += frames
        guard let core else { return }
        captureRewindIfDue(core)
        let now = CACurrentMediaTime()
        housekeeping(now)
        // A heavy game goes straight into the next batch so the core never sits idle; a light one waits for the next
        // refresh instead of drawing pictures the screen can't show.
        guard isRunning, currentSpeed > 1, !isRewinding, took > 1.0 / 120 else { return }
        let owed = Self.framesToRun(elapsed: now - lastTick, fps: fps, speed: currentSpeed, debt: &frameDebt)
        lastTick = now
        if owed > 0 { startBatch(core, owed: owed) }
    }

    /// Waits for a running fast-forward batch, so nothing else touches the core at the same time.
    private func finishBatch() {
        if batchRunning { batchQueue.sync {} }
    }

    private func housekeeping(_ now: CFTimeInterval) {
        if now - fpsSince >= 0.5 {
            let measured = Double(fpsFrames) / (now - fpsSince)
            if showFPS { measuredFPS = measured }
            let speedNow = currentSpeed > 1 ? (measured / fps * 10).rounded() / 10 : 1
            if abs(speedNow - actualSpeed) >= 0.1 { actualSpeed = speedNow }
            fpsFrames = 0
            fpsSince = now
        }
        if now - lastSRAMSave > 30 { // in-game saves reach the disk even if the app is force-quit
            lastSRAMSave = now
            saveSRAM()
        }
    }

    /// 1 normally; the fast-forward speed; 0.5 in slow motion.
    var currentSpeed: Double { fastForward || holdingFastForward ? speed : slowMotion ? 0.5 : 1 }

    /// Runs `tick` on every display refresh, so frames line up with the screen (less judder, less delay).
    private func startClock() {
        stopClock()
        let target = ClockTarget { [weak self] in self?.tick() }
        if let link = NSScreen.main?.displayLink(target: target, selector: #selector(ClockTarget.fire)) {
            link.add(to: .main, forMode: .common)
            clock = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in target.fire() }
            RunLoop.main.add(timer, forMode: .common)
            clock = timer
        }
    }

    private func stopClock() {
        (clock as? CADisplayLink)?.invalidate()
        (clock as? Timer)?.invalidate()
        clock = nil
    }

    /// How many frames fit in `budget` seconds at the core's pace; always at least one.
    static func framesThatFit(budget: Double, secondsPerFrame: Double) -> Int {
        max(1, Int(budget / max(secondsPerFrame, 0.0002)))
    }

    /// Frames owed for `elapsed` seconds at `speed`; the fraction carries over. Capped so a stall never snowballs.
    static func framesToRun(elapsed: Double, fps: Double, speed: Double, debt: inout Double) -> Int {
        debt += min(max(elapsed, 0), 0.1) * fps * speed
        let frames = Int(debt)
        debt -= Double(frames)
        return min(frames, Int(speed.rounded(.up)) * 2 + 1)
    }

    /// Everything on or off: the game and the lo-fi.
    func toggleSound() {
        soundOn.toggle()
        show(soundOn ? "Sound on" : "Muted", soundOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
    }

    func toggleFastForward() {
        fastForward.toggle()
        let key = controls.key(for: .fastForward)?.name
        show(fastForward ? "Fast-forward \(speed.speedLabel)" + (key.map { " · \($0) to stop" } ?? "") : "Normal speed",
             fastForward ? "forward.fill" : "play.fill")
    }

    /// Set by the app when "No sound in games" is on; wins over Sound and Volume.
    var silenced = false { didSet { applyVolume() } }

    private func applyVolume() {
        audio.volume = Float(soundOn && !silenced ? volume : 0)
    }

    private func recordPlaytime() {
        guard let start = runningSince, let game else { return }
        library.addPlaytime(CACurrentMediaTime() - start, to: game)
        runningSince = nil
    }

    private func fail(_ message: String) {
        error = message
        NSLog(message)
    }

    private func loadCore(_ name: String) -> Core? {
        if let core = cores[name] { return core }
        guard let url = Bundle.main.url(forResource: name, withExtension: "libretro"), let core = Core(url: url) else { return nil }
        cores[name] = core
        return core
    }

    func addFrameObserver(_ observer: @escaping (CGImage) -> Void) -> UUID {
        let id = UUID()
        frameObservers[id] = observer
        if let frame { observer(frame) }
        return id
    }

    func removeFrameObserver(_ id: UUID) {
        frameObservers[id] = nil
    }

    func show(_ text: String, _ symbol: String) {
        onToast?(text, symbol)
    }

    // MARK: In-game saves

    private var sramURL: URL? { game.map { saveFile(for: $0) } }

    private func legacySaveFile(for rom: URL) -> URL {
        library.root.appending(path: "Saves").appending(path: rom.deletingPathExtension().lastPathComponent + ".srm")
    }

    /// Reads old extension-less saves when their owner is unambiguous; all new writes use the full ROM filename.
    private func existingSaveFile(for rom: URL) -> URL {
        let current = saveFile(for: rom), legacy = legacySaveFile(for: rom), fm = FileManager.default
        if !fm.fileExists(atPath: current.path), !library.hasLegacyNameCollision(for: rom), fm.fileExists(atPath: legacy.path) { return legacy }
        return current
    }

    private func loadSRAM() {
        finishBatch()
        guard let core, let game, let ptr = core.memoryData(UInt32(RETRO_MEMORY_SAVE_RAM)) else { return }
        let url = existingSaveFile(for: game)
        guard let saved = try? Data(contentsOf: url) else { return }
        let size = core.memorySize(UInt32(RETRO_MEMORY_SAVE_RAM))
        saved.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            ptr.copyMemory(from: base, byteCount: min(size, raw.count))
        }
    }

    private func saveSRAM() {
        finishBatch()
        guard let core, let url = sramURL, let ptr = core.memoryData(UInt32(RETRO_MEMORY_SAVE_RAM)) else { return }
        let size = core.memorySize(UInt32(RETRO_MEMORY_SAVE_RAM))
        guard size > 0 else { return }
        let bytes = Data(bytes: ptr, count: size)
        guard bytes != lastSRAM else { return }
        do {
            try bytes.write(to: url, options: .atomic)
            lastSRAM = bytes
        } catch {
            NSLog("Saving \(url.path) failed: \(error)")
        }
    }

    // MARK: Save states

    /// Written every time the game pauses or closes and loaded when it opens again.
    static let autoSlot = "auto"
    /// Slots shown in the States panel, Quick first (the Quick Save / Quick Load keys use it).
    static let slots = ["quick", "1", "2", "3"]

    static func slotTitle(_ slot: String) -> String {
        switch slot {
        case autoSlot: "Last Played"
        case "quick": "Quick Save"
        default: "Slot \(slot)"
        }
    }

    private func stateURL(_ slot: String, ext: String = "state", for rom: URL? = nil, legacy: Bool = false) -> URL? {
        (rom ?? game).map {
            let name = legacy ? $0.deletingPathExtension().lastPathComponent : $0.lastPathComponent
            return library.root.appending(path: "States").appending(path: "\(name).\(slot).\(ext)")
        }
    }

    private func existingStateURL(_ slot: String, ext: String = "state", for rom: URL? = nil) -> URL? {
        guard let rom = rom ?? game, let current = stateURL(slot, ext: ext, for: rom) else { return nil }
        let fm = FileManager.default
        if fm.fileExists(atPath: current.path) { return current }
        if !library.hasLegacyNameCollision(for: rom), let legacy = stateURL(slot, ext: ext, for: rom, legacy: true),
           fm.fileExists(atPath: legacy.path) { return legacy }
        return nil
    }

    func hasState(_ slot: String) -> Bool { existingStateURL(slot) != nil }

    /// When the slot was saved and the picture at that moment.
    func stateInfo(_ slot: String) -> (date: Date, thumbnail: NSImage?)? {
        guard let url = existingStateURL(slot),
              let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
        return (date, existingStateURL(slot, ext: "png").flatMap { NSImage(contentsOf: $0) })
    }

    /// The picture from where any game was left off, loaded or not (open games, Jump Back In).
    func resumeThumbnail(for rom: URL) -> NSImage? {
        existingStateURL(Self.autoSlot, ext: "png", for: rom).flatMap { NSImage(contentsOf: $0) }
    }

    @discardableResult
    func saveState(_ slot: String, announce: Bool = true) -> Bool {
        finishBatch()
        guard let core, let url = stateURL(slot) else { return false }
        let size = core.serializeSize()
        guard size > 0 else { return false }
        var data = Data(count: size)
        guard data.withUnsafeMutableBytes({ core.serialize($0.baseAddress, size) }) else {
            if announce { show("Couldn't save", "exclamationmark.triangle.fill") }
            return false
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            if let frame, let thumb = stateURL(slot, ext: "png"),
               let png = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:]) {
                try? png.write(to: thumb, options: .atomic)
            }
        } catch {
            NSLog("Saving state \(url.path) failed: \(error)")
            return false
        }
        stateVersion += 1
        if announce { show("Saved to \(Self.slotTitle(slot))", "square.and.arrow.down.fill") }
        return true
    }

    @discardableResult
    func loadState(_ slot: String, announce: Bool = true) -> Bool {
        finishBatch()
        guard let core, let url = existingStateURL(slot), let data = try? Data(contentsOf: url) else { return false }
        if slot != Self.autoSlot { // remember where you were, so a wrong Load can be undone
            let size = core.serializeSize()
            var current = Data(count: size)
            if size > 0, current.withUnsafeMutableBytes({ core.serialize($0.baseAddress, size) }) {
                undoState = current
                canUndoLoad = true
            }
        }
        let ok = data.withUnsafeBytes { core.unserialize($0.baseAddress, data.count) }
        guard ok else {
            if announce { show("Couldn't load", "exclamationmark.triangle.fill") }
            return false
        }
        rewindStates = []
        if !isRunning { // draw the loaded moment even while paused
            drawThisFrame = true
            core.run()
            snapshot = frame
        }
        if announce { show("Loaded \(Self.slotTitle(slot))", "arrow.counterclockwise") }
        return true
    }

    /// Goes back to just before the last Load.
    func undoLoad() {
        finishBatch()
        guard let core, let state = undoState else { return }
        _ = state.withUnsafeBytes { core.unserialize($0.baseAddress, state.count) }
        undoState = nil
        canUndoLoad = false
        rewindStates = []
        if !isRunning {
            drawThisFrame = true
            core.run()
            snapshot = frame
        }
        show("Load undone", "arrow.uturn.backward")
    }

    // MARK: Save files

    /// The game's in-game save (battery save), the same raw format other emulators use (.sav/.srm).
    func saveFile(for rom: URL) -> URL {
        library.root.appending(path: "Saves").appending(path: rom.lastPathComponent + ".srm")
    }

    /// Copies the in-game save out, e.g. to use it in another emulator or on real hardware.
    func exportSave(for rom: URL, to destination: URL) throws {
        if rom == game { saveSRAM() }
        let file = existingSaveFile(for: rom)
        guard FileManager.default.fileExists(atPath: file.path) else { throw CocoaError(.fileReadNoSuchFile) }
        try Data(contentsOf: file).write(to: destination, options: .atomic)
    }

    /// Replaces the in-game save with one from elsewhere. The resume point is dropped so the game boots from the
    /// imported save (the current save is kept as a backup next to it).
    func importSave(from source: URL, for rom: URL) throws {
        let data = try Data(contentsOf: source)
        let wasPlaying = rom == game
        if wasPlaying { stop() }
        let file = saveFile(for: rom)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: file.path) {
            let backup = file.deletingPathExtension().appendingPathExtension("backup.srm")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: file, to: backup)
        }
        try data.write(to: file, options: .atomic)
        for legacy in [false, true] {
            for ext in ["state", "png"] {
                if let auto = stateURL(Self.autoSlot, ext: ext, for: rom, legacy: legacy) { try? FileManager.default.removeItem(at: auto) }
            }
        }
        if wasPlaying { play(rom) }
    }

    /// Starts the game over from the beginning (save files stay).
    func restart() {
        finishBatch()
        core?.reset()
        rewindStates = []
        show("Restarted", "arrow.clockwise")
    }

    // MARK: Rewind

    private func configureRewind() {
        finishBatch()
        rewindStates = []
        rewindStateSize = core?.serializeSize() ?? 0
        // DS states are too big to keep many of; GB/GBA states are small.
        rewindCapacity = rewindEnabled && (1...3_000_000).contains(rewindStateSize) ? min(150, 96_000_000 / rewindStateSize) : 0
    }

    var canRewind: Bool { rewindCapacity > 0 }

    private func updateRewind() {
        let wants = holdingRewindKey || holdingRewindPad
        if wants && !canRewind && !rewindWarned {
            show(rewindEnabled ? "Rewind works in Game Boy and GBA games" : "Rewind is off in Settings", "backward.fill")
            rewindWarned = true
        }
        if !wants { rewindWarned = false }
        let rewinding = wants && canRewind && core != nil
        if rewinding != isRewinding {
            isRewinding = rewinding
            rewindDebt = 0
        }
    }

    private func captureRewindIfDue(_ core: Core) {
        finishBatch()
        guard rewindCapacity > 0 else { return }
        framesSinceCapture += 1
        guard framesSinceCapture >= Self.rewindInterval else { return }
        framesSinceCapture = 0
        var data = Data(count: rewindStateSize)
        guard data.withUnsafeMutableBytes({ core.serialize($0.baseAddress, rewindStateSize) }) else { return }
        rewindStates.append(data)
        if rewindStates.count > rewindCapacity { rewindStates.removeFirst(rewindStates.count - rewindCapacity) }
    }

    /// Steps back through the snapshots at `rewindSpeed`× real time. Out of snapshots = holds on the oldest moment.
    private func rewindTick(_ core: Core, elapsed: Double) {
        finishBatch()
        rewindDebt += min(max(elapsed, 0), 0.1) * fps * Self.rewindSpeed / Double(Self.rewindInterval)
        let steps = Int(rewindDebt)
        rewindDebt -= Double(steps)
        var state: Data?
        for _ in 0..<steps { if let previous = rewindStates.popLast() { state = previous } }
        guard let state else { return }
        _ = state.withUnsafeBytes { core.unserialize($0.baseAddress, state.count) }
        drawThisFrame = true
        core.run()
    }

    /// How many seconds of rewind are stored right now.
    var rewindSeconds: Double { Double(rewindStates.count * Self.rewindInterval) / fps }

    // MARK: Cheats

    /// Turns on the enabled cheats (codes one per line; the cores work out GameShark/Action Replay/… themselves).
    func applyCheats(_ cheats: [Cheat]) {
        finishBatch()
        guard let core, let reset = core.cheatReset, let set = core.cheatSet else { return }
        reset()
        for (index, cheat) in cheats.filter(\.enabled).enumerated() {
            let code = cheat.code.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "+")
            code.withCString { set(UInt32(index), true, $0) }
        }
    }

    // MARK: Screenshots

    /// Saves the current picture, scaled up with sharp pixels, to ~/Pictures/Menu Bar Emulator.
    @discardableResult
    func screenshot() -> URL? {
        guard let frame, let game else { return nil }
        let scale = frame.width < 300 ? 4 : 2
        let w = frame.width * scale, h = frame.height * scale
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Pictures/Menu Bar Emulator")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = folder.appending(path: "\(game.gameTitle) \(formatter.string(from: Date())).png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
        } catch {
            show("Couldn't save the screenshot", "exclamationmark.triangle.fill")
            return nil
        }
        show("Screenshot saved to Pictures", "camera.fill")
        return url
    }

    // MARK: Input

    /// Handles a key while the game screen is up. Returns true when the key is bound, so the caller can swallow it.
    func handleKey(_ keyCode: UInt16, down: Bool, isRepeat: Bool = false) -> Bool {
        guard game != nil, showingGame, let action = controls.action(for: keyCode) else { return false }
        if let button = action.joypadID {
            if down { keyButtons.insert(button) } else { keyButtons.remove(button) }
            return true
        }
        if action == .rewind {
            if !isRepeat {
                holdingRewindKey = down
                updateRewind()
            }
            return true
        }
        if action == .turboA || action == .turboB {
            let button = UInt32(action == .turboA ? RETRO_DEVICE_ID_JOYPAD_A : RETRO_DEVICE_ID_JOYPAD_B)
            if down { turboHeld.insert(button) } else { turboHeld.remove(button) }
            return true
        }
        guard down, !isRepeat else { return true }
        switch action {
        case .fastForward: toggleFastForward()
        case .pause: userPaused.toggle()
        case .quickSave: saveState("quick")
        case .quickLoad: if !loadState("quick") { show("No Quick Save yet", "tray") }
        case .screenshot: screenshot()
        case .slowMotion:
            slowMotion.toggle()
            show(slowMotion ? "Slow motion" : "Normal speed", slowMotion ? "tortoise.fill" : "play.fill")
        case .mute: toggleSound()
        default: onAppAction?(action)
        }
        return true
    }

    /// Controller state: game buttons, right trigger = hold fast-forward, left trigger = hold rewind.
    func setPad(_ buttons: Set<GamepadInput.Button>) {
        let map: [GamepadInput.Button: Int32] = [
            .up: RETRO_DEVICE_ID_JOYPAD_UP, .down: RETRO_DEVICE_ID_JOYPAD_DOWN, .left: RETRO_DEVICE_ID_JOYPAD_LEFT,
            .right: RETRO_DEVICE_ID_JOYPAD_RIGHT, .a: RETRO_DEVICE_ID_JOYPAD_A, .b: RETRO_DEVICE_ID_JOYPAD_B,
            .x: RETRO_DEVICE_ID_JOYPAD_X, .y: RETRO_DEVICE_ID_JOYPAD_Y, .l: RETRO_DEVICE_ID_JOYPAD_L,
            .r: RETRO_DEVICE_ID_JOYPAD_R, .start: RETRO_DEVICE_ID_JOYPAD_START, .select: RETRO_DEVICE_ID_JOYPAD_SELECT,
        ]
        padButtons = Set(buttons.compactMap { map[$0].map(UInt32.init) })
        if holdingFastForward != buttons.contains(.r2) { holdingFastForward = buttons.contains(.r2) }
        if holdingRewindPad != buttons.contains(.l2) {
            holdingRewindPad = buttons.contains(.l2)
            updateRewind()
        }
    }

    /// Mouse on the game picture as the DS stylus: 0…1 across the core's whole output (both screens, top over bottom).
    func touch(normalized point: CGPoint, down: Bool) {
        func axis(_ v: CGFloat) -> Int16 { Int16(clamping: Int((min(max(v, 0), 1) * 2 - 1) * 0x7fff)) }
        pointer = (axis(point.x), axis(point.y), down)
    }

    // MARK: Core callbacks

    fileprivate func environment(_ cmd: UInt32, _ data: UnsafeMutableRawPointer?) -> Bool {
        guard let data else { return false }
        switch Int32(cmd) {
        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
            data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee = UnsafePointer(biosDir)
        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
            data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee = UnsafePointer(saveDir)
        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
            let format = data.load(as: UInt32.self)
            guard format == RETRO_PIXEL_FORMAT_XRGB8888.rawValue || format == RETRO_PIXEL_FORMAT_RGB565.rawValue else { return false }
            pixelFormat = format
        case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
            data.assumingMemoryBound(to: retro_log_callback.self).pointee.log = host_log_callback()
        case RETRO_ENVIRONMENT_GET_CAN_DUPE:
            data.assumingMemoryBound(to: Bool.self).pointee = true
        case RETRO_ENVIRONMENT_GET_VARIABLE:
            let variable = data.assumingMemoryBound(to: retro_variable.self)
            guard let key = variable.pointee.key.map({ String(cString: $0) }), let value = coreOption(key) else { return false }
            variable.pointee.value = UnsafePointer(cString(value))
        case RETRO_ENVIRONMENT_SET_VARIABLES:
            // melonDS DS only reads its settings at load if this registration works; refusing it left every DS setting
            // on built-in defaults (including a cursor square that stayed where the stylus last touched).
            break
        case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
            data.assumingMemoryBound(to: Bool.self).pointee = optionsChanged
            optionsChanged = false
        case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO:
            // GBA games can switch their sound to a higher rate mid-game (Pokémon does). Not following it played
            // the sound at the old rate and threw away half of it.
            let timing = data.assumingMemoryBound(to: retro_system_av_info.self).pointee.timing
            if Thread.isMainThread {
                adoptTiming(fps: timing.fps, sampleRate: timing.sample_rate)
            } else {
                nonisolated(unsafe) let emulator = self
                DispatchQueue.main.async { emulator.adoptTiming(fps: timing.fps, sampleRate: timing.sample_rate) }
            }
        default:
            return false // everything else (core options, hardware rendering, …) falls back to the core's defaults
        }
        return true
    }

    /// The core changed its frame or sound rate: keep up with it.
    func adoptTiming(fps newFPS: Double, sampleRate newRate: Double) {
        if newFPS > 0 { fps = newFPS }
        guard newRate > 0, newRate != sampleRate else { return }
        sampleRate = newRate
        if isRunning {
            audio.start(sampleRate: newRate)
            applyVolume()
        }
    }

    /// The core options we set; everything else keeps the core's default.
    private func coreOption(_ key: String) -> String? {
        switch key {
        case "mgba_gb_colors": gbPalette
        // melonDS DS otherwise draws its own square cursor where the stylus last was, and leaves it there after you let
        // go (unanswered, it falls back to "always"). The app shows its own stylus instead.
        case "melonds_show_cursor": "disabled"
        default: nil
        }
    }

    /// C strings handed to the core must outlive the call, so they're kept (one per distinct value).
    private func cString(_ value: String) -> UnsafeMutablePointer<CChar> {
        if let existing = cStrings[value] { return existing }
        let pointer = strdup(value)!
        cStrings[value] = pointer
        return pointer
    }

    fileprivate func video(_ data: UnsafeRawPointer?, _ width: Int, _ height: Int, _ pitch: Int) {
        guard drawThisFrame, let data, width > 0, height > 0 else { return } // nil data = same frame as last time
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { out in
            guard let base = out.baseAddress else { return }
            if pixelFormat == RETRO_PIXEL_FORMAT_RGB565.rawValue {
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: data), height: vImagePixelCount(height),
                                        width: vImagePixelCount(width), rowBytes: pitch)
                var dst = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow)
                vImageConvert_RGB565toBGRA8888(255, &src, &dst, vImage_Flags(kvImageNoFlags))
            } else {
                for y in 0..<height { (base + y * bytesPerRow).copyMemory(from: data + y * pitch, byteCount: bytesPerRow) }
            }
        }
        if frameBlending {
            let current = pixels
            if let previous = previousPixels, previous.count == pixels.count { Self.blend(&pixels, with: previous) }
            previousPixels = current
        }
        if colorCorrection, let system = game.flatMap(GameSystem.init(rom:)), system == .gba || system == .gbc {
            Self.correctColors(&pixels, width: width, height: height)
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmapInfo, provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
        let size = CGSize(width: width, height: height)
        if Thread.isMainThread { publish(image, size: size) } else { batchImage = (image, size) }
    }

    private func publish(_ image: CGImage, size: CGSize) {
        shownFrames += 1
        frame = image
        if frameSize != size { frameSize = size }
        for observer in frameObservers.values { observer(image) }
    }

    /// Averages two BGRA frames (LCD ghosting).
    static func blend(_ pixels: inout Data, with previous: Data) {
        pixels.withUnsafeMutableBytes { out in
            previous.withUnsafeBytes { prev in
                let a = out.bindMemory(to: UInt32.self), b = prev.bindMemory(to: UInt32.self)
                for i in 0..<min(a.count, b.count) { a[i] = ((a[i] >> 1) & 0x7F7F7F7F) &+ ((b[i] >> 1) & 0x7F7F7F7F) }
            }
        }
    }

    /// The real GBA/GBC screen's colors (a well-known LCD profile): slightly washed out, a little darker.
    /// Rows of the profile add up to 1, so white stays white before the darkening.
    static func correctColors(_ pixels: inout Data, width: Int, height: Int) {
        func k(_ x: Double) -> Int16 { Int16((x * 0.94 * 256).rounded()) }
        // vImage multiplies channels in memory order: B, G, R, A. matrix[input * 4 + output].
        let matrix: [Int16] = [
            k(0.65), k(0.225), k(-0.075), 0,   // from blue
            k(0.155), k(0.64), k(0.275), 0,    // from green
            k(0.195), k(0.135), k(0.80), 0,    // from red
            0, 0, 0, 256,                      // alpha
        ]
        pixels.withUnsafeMutableBytes { raw in
            var buffer = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
            vImageMatrixMultiply_ARGB8888(&buffer, &buffer, matrix, 256, nil, nil, vImage_Flags(kvImageNoFlags))
        }
    }

    fileprivate func audio(_ samples: UnsafePointer<Int16>, frames: Int) {
        guard !fastForward, !holdingFastForward, !isRewinding, !slowMotion else { return }
        audio.push(samples, count: frames * 2)
    }

    fileprivate func poll() {
        frameCounter &+= 1
        // Turbo buttons press and release every 3 frames (10 presses a second).
        let held = batchInput?.buttons ?? keyButtons.union(padButtons)
        let turbo = (frameCounter / 3) % 2 == 0 ? (batchInput?.turbo ?? turboHeld) : []
        pressed = held.union(turbo)
    }

    fileprivate func inputState(port: UInt32, device: UInt32, id: UInt32) -> Int16 {
        guard port == 0 else { return 0 }
        switch Int32(device) {
        case RETRO_DEVICE_JOYPAD:
            if id == RETRO_DEVICE_ID_JOYPAD_MASK { return Int16(truncatingIfNeeded: pressed.reduce(0) { $0 | 1 << $1 }) }
            return pressed.contains(id) ? 1 : 0
        case RETRO_DEVICE_POINTER:
            let pointer = batchInput?.pointer ?? pointer
            switch Int32(id) {
            case RETRO_DEVICE_ID_POINTER_X: return pointer.x
            case RETRO_DEVICE_ID_POINTER_Y: return pointer.y
            case RETRO_DEVICE_ID_POINTER_PRESSED: return pointer.down ? 1 : 0
            default: return 0
            }
        default:
            return 0
        }
    }
}

extension Double {
    /// 2 → "2×", 1.5 → "1.5×"
    var speedLabel: String {
        (self == rounded() ? String(Int(self)) : String(self)) + "×"
    }
}

// libretro callbacks are plain C function pointers and can't capture, so they reach the emulator through this global.
private var activeEmulator: Emulator?

private let environmentCallback: retro_environment_t = { cmd, data in activeEmulator?.environment(cmd, data) ?? false }
private let videoCallback: retro_video_refresh_t = { data, w, h, pitch in activeEmulator?.video(data, Int(w), Int(h), pitch) }
private let audioSampleCallback: retro_audio_sample_t = { left, right in
    var pair = [left, right]
    activeEmulator?.audio(&pair, frames: 1)
}
private let audioBatchCallback: retro_audio_sample_batch_t = { data, frames in
    if let data { activeEmulator?.audio(data, frames: frames) }
    return frames
}
private let inputPollCallback: retro_input_poll_t = { activeEmulator?.poll() }
private let inputStateCallback: retro_input_state_t = { port, device, _, id in
    activeEmulator?.inputState(port: port, device: device, id: id) ?? 0
}

/// The libretro functions of one core dylib, looked up with dlsym.
private final class Core {
    let setEnvironment: @convention(c) (retro_environment_t?) -> Void
    let setVideoRefresh: @convention(c) (retro_video_refresh_t?) -> Void
    let setAudioSample: @convention(c) (retro_audio_sample_t?) -> Void
    let setAudioSampleBatch: @convention(c) (retro_audio_sample_batch_t?) -> Void
    let setInputPoll: @convention(c) (retro_input_poll_t?) -> Void
    let setInputState: @convention(c) (retro_input_state_t?) -> Void
    let initialize: @convention(c) () -> Void
    let deinitialize: @convention(c) () -> Void
    let getAVInfo: @convention(c) (UnsafeMutablePointer<retro_system_av_info>?) -> Void
    let loadGame: @convention(c) (UnsafePointer<retro_game_info>?) -> Bool
    let unloadGame: @convention(c) () -> Void
    let run: @convention(c) () -> Void
    let reset: @convention(c) () -> Void
    let memoryData: @convention(c) (UInt32) -> UnsafeMutableRawPointer?
    let memorySize: @convention(c) (UInt32) -> Int
    let serializeSize: @convention(c) () -> Int
    let serialize: @convention(c) (UnsafeMutableRawPointer?, Int) -> Bool
    let unserialize: @convention(c) (UnsafeRawPointer?, Int) -> Bool
    let cheatReset: (@convention(c) () -> Void)?
    let cheatSet: (@convention(c) (UInt32, Bool, UnsafePointer<CChar>?) -> Void)?

    init?(url: URL) {
        guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            NSLog("dlopen \(url.lastPathComponent): \(String(cString: dlerror()))")
            return nil
        }
        func sym<T>(_ name: String) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }
        guard let setEnvironment: @convention(c) (retro_environment_t?) -> Void = sym("retro_set_environment"),
              let setVideoRefresh: @convention(c) (retro_video_refresh_t?) -> Void = sym("retro_set_video_refresh"),
              let setAudioSample: @convention(c) (retro_audio_sample_t?) -> Void = sym("retro_set_audio_sample"),
              let setAudioSampleBatch: @convention(c) (retro_audio_sample_batch_t?) -> Void = sym("retro_set_audio_sample_batch"),
              let setInputPoll: @convention(c) (retro_input_poll_t?) -> Void = sym("retro_set_input_poll"),
              let setInputState: @convention(c) (retro_input_state_t?) -> Void = sym("retro_set_input_state"),
              let initialize: @convention(c) () -> Void = sym("retro_init"),
              let deinitialize: @convention(c) () -> Void = sym("retro_deinit"),
              let getAVInfo: @convention(c) (UnsafeMutablePointer<retro_system_av_info>?) -> Void = sym("retro_get_system_av_info"),
              let loadGame: @convention(c) (UnsafePointer<retro_game_info>?) -> Bool = sym("retro_load_game"),
              let unloadGame: @convention(c) () -> Void = sym("retro_unload_game"),
              let run: @convention(c) () -> Void = sym("retro_run"),
              let reset: @convention(c) () -> Void = sym("retro_reset"),
              let memoryData: @convention(c) (UInt32) -> UnsafeMutableRawPointer? = sym("retro_get_memory_data"),
              let memorySize: @convention(c) (UInt32) -> Int = sym("retro_get_memory_size"),
              let serializeSize: @convention(c) () -> Int = sym("retro_serialize_size"),
              let serialize: @convention(c) (UnsafeMutableRawPointer?, Int) -> Bool = sym("retro_serialize"),
              let unserialize: @convention(c) (UnsafeRawPointer?, Int) -> Bool = sym("retro_unserialize")
        else {
            NSLog("\(url.lastPathComponent) is missing libretro functions")
            return nil
        }
        (self.setEnvironment, self.setVideoRefresh, self.setAudioSample, self.setAudioSampleBatch) = (setEnvironment, setVideoRefresh, setAudioSample, setAudioSampleBatch)
        (self.setInputPoll, self.setInputState, self.initialize, self.deinitialize) = (setInputPoll, setInputState, initialize, deinitialize)
        (self.getAVInfo, self.loadGame, self.unloadGame, self.run, self.reset) = (getAVInfo, loadGame, unloadGame, run, reset)
        (self.memoryData, self.memorySize) = (memoryData, memorySize)
        (self.serializeSize, self.serialize, self.unserialize) = (serializeSize, serialize, unserialize)
        cheatReset = sym("retro_cheat_reset")
        cheatSet = sym("retro_cheat_set")
    }
}

/// CADisplayLink needs an Objective-C target; this one just calls a closure.
private final class ClockTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

/// Plays the core's 16-bit stereo through AVAudioEngine. A cushion of about 60 ms sits between the game and the
/// speakers, and playback runs up to half a percent fast or slow to hold it there (the way RetroArch does it): no
/// skips, no gaps, no pitch change you can hear. If the game stops feeding it, it fades out instead of clicking.
/// The engine pauses (not stops) between sessions so resuming is instant.
final class AudioPlayer {
    private static let capacity = 1 << 16 // stereo frames: about two seconds
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private var rate = 0.0
    private let left = UnsafeMutablePointer<Float>.allocate(capacity: AudioPlayer.capacity)
    private let right = UnsafeMutablePointer<Float>.allocate(capacity: AudioPlayer.capacity)
    private var written = 0
    private var position = 0.0
    private var target = 1500.0, limit = 5000.0, fadeStep: Float = 0.006
    private var playing = false, played = false
    private var gain: Float = 0, lastLeft: Float = 0, lastRight: Float = 0
    private let lock = NSLock()
    /// Times it ran dry, or had to jump ahead because it fell far behind.
    private(set) var underruns = 0, skips = 0

    init() {
        left.initialize(repeating: 0, count: Self.capacity)
        right.initialize(repeating: 0, count: Self.capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    var volume: Float = 1 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }

    func start(sampleRate: Double) {
        if node == nil || rate != sampleRate { build(sampleRate: sampleRate) }
        clear()
        guard !engine.isRunning else { return }
        do { try engine.start() } catch { NSLog("Audio failed to start: \(error)") }
    }

    func stop() {
        engine.pause()
        clear()
    }

    /// Sets the rate without an engine, for tests that drive `render` directly.
    func prepare(sampleRate: Double) {
        rate = sampleRate
        // 60 ms: room for a frame's worth of sound (17 ms) plus a 30 ms hiccup on the main thread.
        target = sampleRate * 0.06
        limit = sampleRate * 0.2
        fadeStep = Float(1 / (sampleRate * 0.005))
        clear()
    }

    private func build(sampleRate: Double) {
        engine.stop()
        if let node { engine.detach(node) }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        prepare(sampleRate: sampleRate)
        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count == 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            render(left: left, right: right, count: Int(frameCount))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = volume
        self.node = node
    }

    private func clear() {
        lock.lock()
        written = 0
        position = 0
        playing = false
        played = false
        gain = 0
        lock.unlock()
    }

    /// Fills the speakers' buffer (called on the audio thread).
    func render(left out: UnsafeMutablePointer<Float>, right outRight: UnsafeMutablePointer<Float>, count: Int) {
        lock.lock()
        let mask = Self.capacity - 1
        var available = Double(written) - position
        if !playing, available >= target { playing = true }
        // Hold the cushion: a little faster when it's too full, a little slower when it's low (the full half percent
        // once it's off by half).
        let ratio = 1 + min(max((available - target) / (target * 0.5), -1), 1) * 0.005
        for i in 0..<count {
            if playing, available >= 2 {
                let index = Int(position)
                let t = Float(position - Double(index))
                let a = index & mask, b = (index + 1) & mask
                lastLeft = left[a] + (left[b] - left[a]) * t
                lastRight = right[a] + (right[b] - right[a]) * t
                position += ratio
                available -= ratio
                gain = min(1, gain + fadeStep)
                played = true
            } else {
                if playing, played { underruns += 1 }
                playing = false // wait for the cushion to build again
                gain = max(0, gain - fadeStep)
            }
            out[i] = lastLeft * gain
            outRight[i] = lastRight * gain
        }
        lock.unlock()
    }

    /// Takes the core's interleaved 16-bit stereo (`count` samples, two per frame).
    func push(_ samples: UnsafePointer<Int16>, count: Int) {
        lock.lock()
        let mask = Self.capacity - 1
        for frame in 0..<count / 2 {
            left[written & mask] = Float(samples[frame * 2]) / 32768
            right[written & mask] = Float(samples[frame * 2 + 1]) / 32768
            written += 1
        }
        // Far too far ahead (after a long stall): drop back to the cushion so the sound doesn't lag the picture.
        if Double(written) - position > limit {
            position = Double(written) - target
            skips += 1
        }
        lock.unlock()
    }
}
