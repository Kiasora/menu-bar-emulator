import AVFoundation
import Observation
import Synchronization

// MARK: - Player

/// The lo-fi tape player. A volume above 0 fades it in slowly, 0 fades it out; it keeps its place in between, and its
/// audio engine only runs while it can be heard.
@Observable
final class LofiPlayer {
    /// What it was last told to play at (0: fading out, or silent).
    @ObservationIgnored private(set) var volume: Float = 0
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var synth: LofiSynth?
    @ObservationIgnored private var pauseLater: DispatchWorkItem?

    func setVolume(_ volume: Float) {
        self.volume = volume
        pauseLater?.cancel()
        if volume > 0 {
            start()?.target = volume
        } else if let synth {
            synth.target = 0
            // Once it's faded out, stop the engine so it costs nothing.
            let work = DispatchWorkItem { [weak self] in self?.engine?.pause() }
            pauseLater = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(LofiSynth.fadeOut) + 0.5, execute: work)
        }
    }

    private func start() -> LofiSynth? {
        if engine == nil {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: LofiScore.sampleRate, channels: 2) else { return nil }
            let synth = LofiSynth()
            let engine = AVAudioEngine()
            let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
                let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                guard buffers.count == 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                      let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                synth.render(left: left, right: right, count: Int(frameCount))
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            self.engine = engine
            self.synth = synth
            // Headphones in or out stops the engine; pick up again if it should be playing.
            nonisolated(unsafe) weak let player = self
            NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
                if let player, player.volume > 0 { player.setVolume(player.volume) }
            }
        }
        if let engine, !engine.isRunning {
            do { try engine.start() } catch { NSLog("Lo-fi couldn't start: \(error)") }
        }
        return synth
    }
}

// MARK: - The tape

/// The lo-fi tape: twelve original tracks, about 30 minutes, in the spirit of old handheld RPG town and route music.
/// Bright major-key tunes on a Game Boy-style pulse, an ocarina or a music box, over jazzy electric piano, soft swung
/// drums and vinyl crackle. Written out from a fixed seed, so it's the same tape every time.
struct LofiScore {
    static let sampleRate = 44100.0

    enum Kind: UInt8 { case keys, bass, lead, square, ocarina, bell, arp, kick, snare, hat, openHat, track }

    struct Event {
        /// Samples from the start of the tape.
        var time: Int
        var kind: Kind
        /// MIDI note. For `.track`, the echo time in samples.
        var note: Int
        var velocity: Float
        /// Samples until the note's let go.
        var length: Int
    }

    let events: [Event]
    /// In samples, the gaps between tracks included.
    let length: Int
    let trackStarts: [Int]
}

extension LofiScore {
    init(seed: UInt64 = 0x51CE_0F_10F1) {
        var rng = LofiRandom(state: seed)
        var events: [Event] = []
        var starts: [Int] = []
        var time = 0.0
        for index in Self.keys.indices {
            starts.append(Int(time))
            time = Self.track(index, at: time, rng: &rng, into: &events)
            time += 2.5 * Self.sampleRate // a moment of crackle between tracks
        }
        events.sort { $0.time < $1.time }
        self.init(events: events, length: Int(time), trackStarts: starts)
    }

    private struct Chord {
        /// Semitones above the key.
        var root: Int
        /// Semitones above the root.
        var tones: [Int]
    }

    /// A two-bar idea: its rhythm in 16ths, and how each note moves from the last (in steps through the chord's notes).
    private struct Motif {
        var rhythm: [(step: Int, length: Int)]
        var moves: [Int]
    }

    private static let maj7 = [0, 4, 7, 11], maj9 = [0, 4, 7, 11, 14], m7 = [0, 3, 7, 10], m9 = [0, 3, 7, 10, 14]
    private static let dom7 = [0, 4, 7, 10], dom9 = [0, 4, 7, 10, 14], m6 = [0, 3, 7, 9]

    private static func chord(_ root: Int, _ tones: [Int]) -> Chord { Chord(root: root, tones: tones) }

    /// Four bars each. A bar has one chord, or two for half a bar each.
    private static let progressions: [[[Chord]]] = [
        [[chord(0, maj7)], [chord(9, m7)], [chord(2, m7)], [chord(7, dom7)]],                    // I vi ii V
        [[chord(5, maj7)], [chord(7, dom7)], [chord(4, m7)], [chord(9, m7)]],                    // IV V iii vi
        [[chord(0, maj9)], [chord(4, dom7)], [chord(9, m9)], [chord(5, maj7)]],                  // I III7 vi IV
        [[chord(2, m9)], [chord(7, dom9)], [chord(0, maj9)], [chord(9, m9)]],                    // ii V I vi
        [[chord(5, maj7)], [chord(4, m7)], [chord(2, m7)], [chord(0, maj7)]],                    // IV iii ii I
        [[chord(0, maj7)], [chord(5, maj7)], [chord(8, maj7), chord(10, dom7)], [chord(0, maj9)]], // I IV bVI bVII I
        [[chord(9, m7)], [chord(5, maj7)], [chord(0, maj7)], [chord(7, dom7)]],                  // vi IV I V
        [[chord(0, maj7)], [chord(4, m7)], [chord(5, maj7)], [chord(5, m6)]],                    // I iii IV iv
    ]

    private static let rhythms: [[(step: Int, length: Int)]] = [
        [(0, 4), (4, 2), (6, 2), (8, 6), (14, 2), (16, 4), (20, 4), (24, 8)],
        [(0, 3), (3, 3), (6, 2), (8, 4), (12, 4), (16, 6), (22, 2), (24, 8)],
        [(2, 2), (4, 2), (6, 4), (10, 2), (12, 4), (18, 2), (20, 2), (22, 2), (24, 8)],
        [(0, 6), (6, 2), (8, 2), (10, 2), (12, 4), (16, 12)],
        [(0, 2), (2, 2), (4, 2), (6, 2), (8, 8), (16, 2), (18, 2), (20, 4), (24, 8)],
        [(0, 8), (8, 4), (12, 4), (16, 8), (24, 8)],
        [(0, 4), (6, 2), (8, 4), (12, 2), (14, 2), (16, 8), (26, 6)],
    ]

    private static let compings: [[(step: Int, length: Int)]] = [[(0, 16)], [(0, 7), (10, 6)], [(0, 3), (3, 7), (12, 4)], [(0, 6), (6, 2), (8, 8)]]
    private static let kicks = [[0, 10], [0, 7, 10], [0, 9], [0, 6, 10]]
    private static let keys = [5, 2, 7, 3, 0, 9, 10, 4, 8, 2, 5, 0] // F D G E♭ C A B♭ E A♭ D F C
    private static let tempos: [Double] = [78, 84, 74, 80, 76, 86, 72, 82, 75, 79, 70, 83]
    private static let leads: [Kind] = [.lead, .ocarina, .lead, .square, .bell, .lead, .ocarina, .lead, .square, .lead, .bell, .lead]

    private static func motif(_ rng: inout LofiRandom) -> Motif {
        let rhythm = rhythms[rng.int(rhythms.count)]
        var moves = [0], total = 0
        for _ in 1..<rhythm.count {
            // Mostly steps; after a leap, a step back the other way.
            let last = moves[moves.count - 1]
            var move = abs(last) >= 2 ? -last.signum() : [1, -1, 1, 2, -1, -2, 3, 1, -1][rng.int(9)]
            if abs(total + move) > 4 { move = -move }
            moves.append(move)
            total += move
        }
        return Motif(rhythm: rhythm, moves: moves)
    }

    /// The chord without its root (the bass has that) plus its 9th, kept around middle C.
    private static func voicing(_ chord: Chord, key: Int) -> [Int] {
        let root = 48 + (key + chord.root) % 12
        var notes = (Array(chord.tones.dropFirst().prefix(3)) + [14]).map { root + $0 }
        while notes[0] < 52 { notes = notes.map { $0 + 12 } }
        return notes
    }

    /// Writes one track (48 bars: intro, the tune, a bridge, the tune again, outro) and returns when it ends.
    private static func track(_ index: Int, at start: Double, rng: inout LofiRandom, into events: inout [Event]) -> Double {
        let key = keys[index]
        let beat = 60 / tempos[index] * sampleRate
        let sixteenth = beat / 4
        let swing = 0.12 + Double(rng.float()) * 0.12
        let verse = progressions[(index * 3) % progressions.count]
        let bridge = progressions[(index * 3 + 5) % progressions.count]
        let lead = leads[index]
        let counter: Kind = lead == .bell ? .lead : .bell
        let comping = compings[rng.int(compings.count)], bridgeComping = compings[rng.int(compings.count)]
        let kick = kicks[rng.int(kicks.count)]
        let bassStyle = rng.int(3)
        let main = motif(&rng), answer = motif(&rng), third = motif(&rng)

        func time(_ bar: Int, _ step: Int) -> Int {
            Int(start + (Double(bar * 16 + step) + (step % 2 == 1 ? swing : 0)) * sixteenth)
        }
        func add(_ kind: Kind, _ note: Int, _ velocity: Float, _ bar: Int, _ step: Int, steps: Double, nudge: Int = 0) {
            events.append(Event(time: max(0, time(bar, step) + nudge), kind: kind, note: note, velocity: velocity, length: Int(steps * sixteenth)))
        }
        func bars(_ bar: Int) -> [Chord] { ((20..<28).contains(bar) ? bridge : verse)[bar % 4] }
        func chord(_ bar: Int, _ step: Int) -> Chord {
            let chords = bars(bar)
            return chords[step < 8 ? 0 : chords.count - 1]
        }

        events.append(Event(time: Int(start), kind: .track, note: Int(beat * 0.75), velocity: 0, length: 0)) // dotted-8th echo

        // Electric piano, rolled like a lazy hand.
        for bar in 0..<48 {
            let pattern = bars(bar).count > 1 ? [(step: 0, length: 8), (step: 8, length: 8)]
                : bar < 4 || bar >= 44 ? [(step: 0, length: 16)]
                : (20..<28).contains(bar) ? bridgeComping : comping
            for hit in pattern {
                let velocity = (hit.step == 0 ? 0.62 : 0.5) + rng.float() * 0.08
                for (i, note) in voicing(chord(bar, hit.step), key: key).enumerated() {
                    add(.keys, note, velocity, bar, hit.step, steps: Double(hit.length) - 0.3, nudge: i * 530)
                }
            }
        }

        // Bass.
        for bar in 2..<48 {
            let styles: [[(step: Int, length: Int, interval: Int)]] = [
                [(0, 7, 0), (10, 4, 0), (14, 2, 7)],
                [(0, 12, 0), (12, 4, 7)],
                [(0, 6, 0), (6, 2, 12), (8, 6, 7), (14, 2, 0)],
            ]
            let pattern = bar == 47 ? [(step: 0, length: 16, interval: 0)]
                : bars(bar).count > 1 ? [(step: 0, length: 8, interval: 0), (step: 8, length: 8, interval: 0)]
                : styles[bassStyle]
            for hit in pattern {
                let root = 36 + (key + chord(bar, hit.step).root) % 12
                add(.bass, root + hit.interval, 0.75 + rng.float() * 0.1, bar, hit.step, steps: Double(hit.length) - 0.4)
            }
        }

        // Drums: swung hats, a lazy kick, snare on 2 and 4. Just hats in the intro and outro, a breather in the bridge.
        for bar in 2..<46 {
            let full = (4..<44).contains(bar)
            for step in stride(from: 0, to: 16, by: 2) where full || step % 4 == 0 {
                let open = full && bar % 8 == 7 && step == 14
                let velocity = (step % 4 == 0 ? 0.5 : 0.32) * (full ? 1 : 0.7) + rng.float() * 0.08
                add(open ? .openHat : .hat, 0, velocity, bar, step, steps: 1, nudge: rng.int(160) - 80)
            }
            guard full else { continue }
            if bar % 2 == 1 { add(.hat, 0, 0.22, bar, 15, steps: 1) }
            let breather = (20..<22).contains(bar)
            for step in breather ? [0] : kick { add(.kick, 0, step == 0 ? 0.9 : 0.7, bar, step, steps: 1) }
            guard !breather else { continue }
            add(.snare, 0, 0.75 + rng.float() * 0.08, bar, 4, steps: 1, nudge: rng.int(120))
            add(.snare, 0, 0.78 + rng.float() * 0.08, bar, 12, steps: 1, nudge: rng.int(120))
            if bar % 4 == 3 { add(.snare, 0, 0.22, bar, 15, steps: 1) }
        }

        // The tune. Each note comes from the chord under it (chord tones on the strong beats, color notes between), so
        // a motif repeated over new chords turns into a sequence. `ending`: true lands home on the key's root, false
        // anywhere else (a question the next phrase answers). Returns the last note so the next idea carries on.
        func melody(_ motif: Motif, _ kind: Kind, _ bar: Int, from pitch: Int, range: ClosedRange<Int>,
                    velocity: Float = 1, ending: Bool? = nil) -> Int {
            var pitch = pitch
            for (i, note) in motif.rhythm.enumerated() {
                let b = bar + note.step / 16, s = note.step % 16
                let c = chord(b, s)
                let strong = s % 8 == 0 || note.length >= 6
                var allowed = Set(c.tones.map { (key + c.root + $0) % 12 })
                if !strong { allowed.formUnion([2, c.tones.contains(4) ? 9 : 5].map { (key + c.root + $0) % 12 }) }
                var move = motif.moves[i]
                if i == motif.rhythm.count - 1, let home = ending {
                    let tonic = key % 12
                    if home { allowed = [allowed.contains(tonic) ? tonic : (key + c.root) % 12] } else if allowed.count > 1 { allowed.remove(tonic) }
                    move = 0
                }
                let notes = range.filter { allowed.contains($0 % 12) }
                guard let nearest = notes.indices.min(by: { abs(notes[$0] - pitch) < abs(notes[$1] - pitch) }) else { continue }
                pitch = notes[min(max(nearest + move, 0), notes.count - 1)]
                add(kind, pitch, velocity * ((strong ? 0.8 : 0.68) + rng.float() * 0.08), b, s, steps: Double(note.length) * 0.92)
            }
            return pitch
        }
        func phrase(_ kind: Kind, _ bar: Int, from pitch: Int, range: ClosedRange<Int>, velocity: Float = 1, home: Bool) -> Int {
            var p = melody(main, kind, bar, from: pitch, range: range, velocity: velocity)
            p = melody(main, kind, bar + 2, from: p, range: range, velocity: velocity)
            p = melody(answer, kind, bar + 4, from: p, range: range, velocity: velocity)
            return melody(main, kind, bar + 6, from: p, range: range, velocity: velocity, ending: home)
        }

        let anchor = 72 + key % 12
        let leadRange = lead == .bell ? 74...93 : 67...86
        let counterRange = counter == .bell ? 79...98 : 67...86
        // The tune twice: asking, then answering.
        var end = phrase(lead, 4, from: anchor, range: leadRange, home: false)
        _ = phrase(lead, 12, from: end, range: leadRange, home: true)
        // Bridge: the lead rests; another voice plays a new idea over Game Boy-style arpeggios.
        end = melody(third, counter, 20, from: counter == .bell ? anchor + 12 : anchor, range: counterRange, velocity: 0.8)
        _ = melody(third, counter, 24, from: end, range: counterRange, velocity: 0.8, ending: false)
        for bar in 20..<28 {
            for step in 0..<16 {
                let c = chord(bar, step)
                let tones = c.tones.prefix(4).map { 72 + (key + c.root + $0) % 12 }.sorted()
                let cycle = tones + Array(tones.reversed().dropFirst().dropLast())
                add(.arp, cycle[step % cycle.count], step % 4 == 0 ? 0.42 : 0.3, bar, step, steps: 0.7)
            }
        }
        // The tune again; the second time a music box doubles it an octave up.
        end = phrase(lead, 28, from: anchor, range: leadRange, home: false)
        _ = phrase(lead, 36, from: end, range: leadRange, home: true)
        if lead != .bell {
            let up = (leadRange.lowerBound + 12)...(leadRange.upperBound + 12)
            _ = phrase(.bell, 36, from: end + 12, range: up, velocity: 0.45, home: true)
        }
        // Outro: the first idea one last time, landing home.
        _ = melody(main, lead, 44, from: anchor, range: leadRange, velocity: 0.75, ending: true)

        return start + 48 * 16 * sixteenth
    }
}

/// SplitMix64: tiny, fast, and the same numbers for the same seed.
struct LofiRandom {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }

    /// 0..<1
    mutating func float() -> Float { Float(next() >> 40) / Float(1 << 24) }
}

// MARK: - Synth

private let sampleRate = Float(LofiScore.sampleRate)
private let twoPi = 2 * Float.pi

/// Per-sample multiplier that takes a level to about a third in `seconds`.
private func decayFactor(_ seconds: Float) -> Float { exp(-1 / (seconds * sampleRate)) }

/// One-pole low-pass coefficient for a cutoff in hertz.
private func lowPassFactor(_ hertz: Float) -> Float { 1 - exp(-twoPi * hertz / sampleRate) }

@inline(__always) private func wrap(_ phase: Float) -> Float { phase >= 1 ? phase - 1 : phase }

/// Smooths a waveform's jump so the pulse doesn't alias (PolyBLEP).
@inline(__always) private func polyBLEP(_ t: Float, _ dt: Float) -> Float {
    if t < dt { let x = t / dt; return x + x - x * x - 1 }
    if t > 1 - dt { let x = (t - 1) / dt; return x * x + x + x + 1 }
    return 0
}

/// White noise, -1…1 (xorshift).
@inline(__always) private func noise(_ state: inout UInt32) -> Float {
    state ^= state << 13
    state ^= state >> 17
    state ^= state << 5
    return Float(Int32(bitPattern: state)) / 2_147_483_648
}

/// Plays a `LofiScore`: electric piano, bass, the lead voices and drums, through a tape echo, a small room, a dark
/// lo-fi filter and vinyl crackle. `render` runs on the audio thread, so it never locks or allocates.
final class LofiSynth {
    static let fadeIn: Float = 5
    static let fadeOut: Float = 1.2
    private static let block = 64, capacity = 4096, voiceCount = 40, echoLength = 88_200

    let score: LofiScore
    /// Where the tape is, in samples.
    private(set) var position: Int
    /// 0…1, how far it's faded in.
    private(set) var fade: Float = 0
    private var next: Int
    private var volume: Float = 0
    private let targetBits = Atomic<UInt32>(0)

    /// The volume to fade to; 0 fades out. Safe to set from any thread.
    var target: Float {
        get { Float(bitPattern: targetBits.load(ordering: .relaxed)) }
        set { targetBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    private let voices = UnsafeMutablePointer<Voice>.allocate(capacity: LofiSynth.voiceCount)
    private var kick = Drum(), snare = Drum(), hat = Drum()
    /// Left, right, kick (never ducked), duck amount, room send, echo send.
    private let bus = UnsafeMutablePointer<Float>.allocate(capacity: LofiSynth.capacity * 6)
    private let echoL = UnsafeMutablePointer<Float>.allocate(capacity: LofiSynth.echoLength)
    private let echoR = UnsafeMutablePointer<Float>.allocate(capacity: LofiSynth.echoLength)
    private let room = Reverb()
    private var echoIndex = 0, echoDelay = 20_000
    private var echoTone: Float = 0, toneL1: Float = 0, toneL2: Float = 0, toneR1: Float = 0, toneR2: Float = 0
    private var hiss: Float = 0, crackle: Float = 0, crackleTone: Float = 0
    private var noiseState: UInt32 = 0x2545_F491
    private var wow: Float = 1, tremolo: Float = 0

    private let shimmerFall = decayFactor(0.06), kickSweep = decayFactor(0.03), kickClick = decayFactor(0.0015)
    private let snareBody = decayFactor(0.05), leadTone = lowPassFactor(2500), arpTone = lowPassFactor(3200)
    private let masterTone = lowPassFactor(5600)

    /// Starts at the beginning of a random track unless told where.
    init(score: LofiScore = LofiScore(), start: Int? = nil) {
        self.score = score
        let position = start ?? score.trackStarts.randomElement() ?? 0
        self.position = position
        next = score.events.firstIndex { $0.time >= position } ?? score.events.count
        voices.initialize(repeating: Voice(), count: Self.voiceCount)
        bus.initialize(repeating: 0, count: Self.capacity * 6)
        echoL.initialize(repeating: 0, count: Self.echoLength)
        echoR.initialize(repeating: 0, count: Self.echoLength)
    }

    deinit {
        voices.deallocate()
        bus.deallocate()
        echoL.deallocate()
        echoR.deallocate()
    }

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        let target = self.target
        guard target > 0 || fade > 0 else { // silent: the tape stays where it is
            left.update(repeating: 0, count: count)
            right.update(repeating: 0, count: count)
            return
        }
        var done = 0
        while done < count {
            let n = min(count - done, Self.capacity)
            renderChunk(left + done, right + done, n, target: target)
            done += n
        }
    }

    private func renderChunk(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ count: Int, target: Float) {
        for index in 0..<6 { (bus + index * Self.capacity).update(repeating: 0, count: count) }
        var offset = 0
        while offset < count {
            while next < score.events.count, score.events[next].time <= position {
                trigger(score.events[next])
                next += 1
            }
            let upcoming = next < score.events.count ? score.events[next].time : score.length
            let n = min(count - offset, Self.block, max(1, upcoming - position))
            // Tape wobble and the electric piano's auto-pan, updated every block.
            let seconds = Float(position) / sampleRate
            wow = 1 + 0.0018 * sin(twoPi * 0.27 * seconds) + 0.0004 * sin(twoPi * 5.1 * seconds)
            tremolo = 0.22 * sin(twoPi * 3.6 * seconds)
            renderVoices(offset, n)
            renderDrums(offset, n)
            position += n
            offset += n
            if position >= score.length { position = 0; next = 0 }
        }
        mix(left, right, count, target: target)
    }

    private func trigger(_ event: LofiScore.Event) {
        switch event.kind {
        case .track: echoDelay = min(max(event.note, 1), Self.echoLength - 1)
        case .kick: kick = Drum(velocity: event.velocity, decay: decayFactor(0.19))
        case .snare: snare = Drum(velocity: event.velocity, decay: decayFactor(0.13))
        case .hat, .openHat: hat = Drum(velocity: event.velocity, decay: decayFactor(event.kind == .hat ? 0.028 : 0.16))
        default: startVoice(event)
        }
    }

    private func startVoice(_ event: LofiScore.Event) {
        var slot = 0 // a free voice, else the quietest
        for index in 0..<Self.voiceCount {
            if !voices[index].active { slot = index; break }
            if voices[index].env < voices[slot].env { slot = index }
        }
        var voice = Voice()
        voice.kind = event.kind
        voice.active = true
        voice.velocity = event.velocity
        voice.hold = max(event.length, 1)
        voice.step = 440 * pow(2, Float(event.note - 69) / 12) / sampleRate
        switch event.kind {
        case .keys:
            voice.shape(attack: 0.004, decay: 1.8, sustain: 0, release: 0.22)
            voice.mod = 0.7 + 1.1 * event.velocity
            voice.modDecay = decayFactor(0.5)
            voice.shimmer = 0.2 * event.velocity
        case .bass: voice.shape(attack: 0.008, decay: 0.45, sustain: 0.4, release: 0.07)
        case .lead, .square: voice.shape(attack: 0.006, decay: 0.25, sustain: 0.6, release: 0.11)
        case .ocarina: voice.shape(attack: 0.04, decay: 0.4, sustain: 0.8, release: 0.15)
        case .bell:
            voice.shape(attack: 0.002, decay: 1.1, sustain: 0, release: 0.45)
            voice.mod = 1.4
            voice.modDecay = decayFactor(0.22)
            voice.pan = 0.3
        case .arp:
            voice.shape(attack: 0.002, decay: 0.12, sustain: 0, release: 0.05)
            voice.pan = -0.35
        default: return
        }
        voices[slot] = voice
    }

    private func renderVoices(_ offset: Int, _ count: Int) {
        let left = bus + offset, right = bus + Self.capacity + offset
        let roomSend = bus + Self.capacity * 4 + offset, echoSend = bus + Self.capacity * 5 + offset
        let wow = self.wow, tremolo = self.tremolo
        for index in 0..<Self.voiceCount where voices[index].active {
            var v = voices[index]
            switch v.kind {
            case .keys: // two-operator FM electric piano with a bell-like tine on top
                let gainL = 0.085 * (1 - tremolo), gainR = 0.085 * (1 + tremolo)
                for i in 0..<count {
                    guard v.advance() else { break }
                    let s = sin(twoPi * v.phase + v.mod * sin(twoPi * v.phase)) + v.shimmer * sin(twoPi * v.phase3)
                    let out = s * v.env * v.velocity
                    v.phase = wrap(v.phase + v.step * wow)
                    v.phase3 = wrap(v.phase3 + v.step * wow * 14)
                    v.mod *= v.modDecay
                    v.shimmer *= shimmerFall
                    left[i] += out * gainL
                    right[i] += out * gainR
                    roomSend[i] += out * 0.03
                }
            case .bass:
                for i in 0..<count {
                    guard v.advance() else { break }
                    let out = (sin(twoPi * v.phase) + 0.35 * sin(2 * twoPi * v.phase)) * v.env * v.velocity * 0.19
                    v.phase = wrap(v.phase + v.step * wow)
                    left[i] += out
                    right[i] += out
                }
            case .lead, .square, .arp: // band-limited pulse, like the Game Boy's square channels, softened
                let duty: Float = v.kind == .square ? 0.5 : v.kind == .arp ? 0.125 : 0.25
                let gain: Float = v.kind == .square ? 0.07 : v.kind == .arp ? 0.045 : 0.095
                let tone = v.kind == .arp ? arpTone : leadTone
                let vibratoDepth: Float = v.kind == .arp ? 0 : 0.0055
                let echo: Float = v.kind == .arp ? 0.15 : 0.5
                for i in 0..<count {
                    guard v.advance() else { break }
                    let dt = v.step * wow * (1 + v.vibrato(depth: vibratoDepth, rate: 5.2))
                    var y: Float = v.phase < duty ? 1 : -1
                    y += polyBLEP(v.phase, dt)
                    y -= polyBLEP(wrap(v.phase + 1 - duty), dt)
                    y -= 2 * duty - 1
                    v.phase = wrap(v.phase + dt)
                    v.low += tone * (y - v.low)
                    let out = v.low * v.env * v.velocity * gain
                    left[i] += out * (1 - v.pan)
                    right[i] += out * (1 + v.pan)
                    echoSend[i] += out * echo
                    roomSend[i] += out * 0.05
                }
            case .ocarina:
                for i in 0..<count {
                    guard v.advance() else { break }
                    v.phase = wrap(v.phase + v.step * wow * (1 + v.vibrato(depth: 0.006, rate: 4.8)))
                    let breath = noise(&noiseState) * 0.03
                    let out = (sin(twoPi * v.phase) + 0.12 * sin(2 * twoPi * v.phase) + breath) * v.env * v.velocity * 0.13
                    left[i] += out
                    right[i] += out
                    echoSend[i] += out * 0.35
                    roomSend[i] += out * 0.06
                }
            case .bell: // music box: FM with an off-ratio modulator
                for i in 0..<count {
                    guard v.advance() else { break }
                    let out = sin(twoPi * v.phase + v.mod * sin(twoPi * v.phase2)) * v.env * v.velocity * 0.085
                    v.phase = wrap(v.phase + v.step * wow)
                    v.phase2 = wrap(v.phase2 + v.step * wow * 3.5)
                    v.mod *= v.modDecay
                    left[i] += out * (1 - v.pan)
                    right[i] += out * (1 + v.pan)
                    echoSend[i] += out * 0.25
                    roomSend[i] += out * 0.08
                }
            default:
                v.active = false
            }
            voices[index] = v
        }
    }

    private func renderDrums(_ offset: Int, _ count: Int) {
        let left = bus + offset, right = bus + Self.capacity + offset
        let kickOut = bus + Self.capacity * 2 + offset, duck = bus + Self.capacity * 3 + offset
        let roomSend = bus + Self.capacity * 4 + offset
        var state = noiseState
        defer { noiseState = state }
        if kick.active {
            var k = kick
            for i in 0..<count {
                k.phase = wrap(k.phase + (54 + 90 * k.pitch) / sampleRate) // a thump that drops in pitch
                k.pitch *= kickSweep
                let s = sin(twoPi * k.phase) * k.env + noise(&state) * k.click * 0.25
                k.click *= kickClick
                kickOut[i] += s * k.velocity * 0.42
                duck[i] = max(duck[i], k.env * k.velocity)
                k.env *= k.decay
                if k.env < 0.0003 { k.active = false; break }
            }
            kick = k
        }
        if snare.active {
            var s = snare
            for i in 0..<count {
                let n = noise(&state)
                s.low += 0.35 * (n - s.low)
                let body = sin(twoPi * s.phase) * s.pitch
                s.phase = wrap(s.phase + 190 / sampleRate)
                s.pitch *= snareBody
                let out = (body * 0.5 + (n - s.low) * s.env * 0.8) * s.velocity * 0.16
                left[i] += out * 0.95
                right[i] += out * 1.05
                roomSend[i] += out * 0.25
                s.env *= s.decay
                if s.env < 0.0003 { s.active = false; break }
            }
            snare = s
        }
        if hat.active {
            var h = hat
            for i in 0..<count {
                let n = noise(&state)
                h.low += 0.55 * (n - h.low)
                let out = (n - h.low) * h.env * h.velocity * 0.065
                left[i] += out * 0.8
                right[i] += out * 1.2
                h.env *= h.decay
                if h.env < 0.0003 { h.active = false; break }
            }
            hat = h
        }
    }

    /// Echo, room, the kick's pump, the dark lo-fi tone, vinyl, a soft clip, then the fade.
    private func mix(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ count: Int, target: Float) {
        let busL = bus, busR = bus + Self.capacity, kickBus = bus + Self.capacity * 2, duck = bus + Self.capacity * 3
        let roomSend = bus + Self.capacity * 4, echoSend = bus + Self.capacity * 5
        let on = target > 0
        let fadeStep = on ? 1 / (Self.fadeIn * sampleRate) : -1 / (Self.fadeOut * sampleRate)
        var state = noiseState, echoIndex = self.echoIndex, echoTone = self.echoTone, fade = self.fade, volume = self.volume
        var toneL1 = self.toneL1, toneL2 = self.toneL2, toneR1 = self.toneR1, toneR2 = self.toneR2
        var hiss = self.hiss, crackle = self.crackle, crackleTone = self.crackleTone
        let tone = masterTone, delay = echoDelay
        for i in 0..<count {
            // Tape echo bouncing left and right, darker each time.
            let read = (echoIndex - delay + Self.echoLength) % Self.echoLength
            let echoedL = echoL[read], echoedR = echoR[read]
            echoTone += 0.3 * (echoedR - echoTone)
            echoL[echoIndex] = echoSend[i] + echoTone * 0.4
            echoR[echoIndex] = echoedL * 0.4
            echoIndex = echoIndex + 1 == Self.echoLength ? 0 : echoIndex + 1
            let (roomL, roomR) = room.process(roomSend[i] + (echoedL + echoedR) * 0.1)
            let pump = 1 - 0.22 * duck[i]
            var l = (busL[i] + echoedL * 0.3) * pump + roomL + kickBus[i]
            var r = (busR[i] + echoedR * 0.3) * pump + roomR + kickBus[i]
            toneL1 += tone * (l - toneL1)
            toneL2 += tone * (toneL1 - toneL2)
            toneR1 += tone * (r - toneR1)
            toneR2 += tone * (toneR1 - toneR2)
            // Vinyl: a soft hiss and the odd crackle.
            hiss += 0.25 * (noise(&state) - hiss)
            if noise(&state) > 0.9992 { crackle = noise(&state) * 0.12 }
            crackle *= 0.6
            crackleTone += 0.5 * (crackle - crackleTone)
            l = tanh((toneL2 + hiss * 0.006 + crackleTone) * 1.3) / 1.3
            r = tanh((toneR2 + hiss * 0.005 + crackleTone * 0.85) * 1.3) / 1.3
            fade = min(max(fade + fadeStep, 0), 1)
            if on { volume += (target - volume) * 0.0005 }
            let gain = volume * fade * fade
            left[i] = l * gain
            right[i] = r * gain
        }
        noiseState = state
        self.echoIndex = echoIndex
        self.echoTone = echoTone
        self.fade = fade
        self.volume = volume
        self.toneL1 = toneL1
        self.toneL2 = toneL2
        self.toneR1 = toneR1
        self.toneR2 = toneR2
        self.hiss = hiss
        self.crackle = crackle
        self.crackleTone = crackleTone
    }
}

private struct Voice {
    var kind: LofiScore.Kind = .keys
    var active = false
    /// Cycles per sample at the note's pitch.
    var step: Float = 0
    var phase: Float = 0, phase2: Float = 0, phase3: Float = 0
    var age = 0, hold = 0, attack = 1
    var env: Float = 0, sustain: Float = 0, decay: Float = 0, release: Float = 0
    /// FM depth (electric piano, music box) and how fast it mellows.
    var mod: Float = 0, modDecay: Float = 1
    var shimmer: Float = 0
    var velocity: Float = 0
    var low: Float = 0
    var pan: Float = 0

    mutating func shape(attack: Float, decay: Float, sustain: Float, release: Float) {
        self.attack = max(1, Int(attack * sampleRate))
        self.decay = decayFactor(decay)
        self.sustain = sustain
        self.release = decayFactor(release)
    }

    /// One sample of the envelope; false once the note has died away.
    mutating func advance() -> Bool {
        age += 1
        if age <= attack {
            env = Float(age) / Float(attack)
        } else if age < hold {
            env = sustain + (env - sustain) * decay
        } else {
            env *= release
        }
        if env < 0.0003, age > attack, age >= hold || sustain == 0 { active = false }
        return active
    }

    /// Pitch wobble that eases in after the note starts, like a singer's.
    func vibrato(depth: Float, rate: Float) -> Float {
        guard depth > 0 else { return 0 }
        let ease = min(1, max(0, Float(age) - 0.18 * sampleRate) / (0.35 * sampleRate))
        return depth * ease * sin(twoPi * rate * Float(age) / sampleRate)
    }
}

private struct Drum {
    var active = false
    var velocity: Float = 0
    var env: Float = 0
    var decay: Float = 0
    var phase: Float = 0
    /// The kick's pitch drop, or the snare's body.
    var pitch: Float = 0
    var click: Float = 0
    var low: Float = 0

    init() {}

    init(velocity: Float, decay: Float) {
        active = true
        self.velocity = velocity
        env = 1
        self.decay = decay
        pitch = 1
        click = 1
    }
}

/// A small Freeverb-style room: four combs and two allpasses a side.
private final class Reverb {
    private static let lengths = [1116, 1188, 1277, 1356, 1139, 1211, 1300, 1379, 556, 441, 579, 464]
    private let lines = UnsafeMutablePointer<DelayLine>.allocate(capacity: Reverb.lengths.count)

    init() {
        for (index, length) in Self.lengths.enumerated() { (lines + index).initialize(to: DelayLine(length)) }
    }

    deinit {
        for index in Self.lengths.indices { lines[index].buffer.deallocate() }
        lines.deallocate()
    }

    func process(_ input: Float) -> (Float, Float) {
        let x = input * 0.2
        var l: Float = 0, r: Float = 0
        for index in 0..<4 { l += lines[index].comb(x) }
        for index in 4..<8 { r += lines[index].comb(x) }
        l = lines[9].allpass(lines[8].allpass(l))
        r = lines[11].allpass(lines[10].allpass(r))
        return (l * 0.5, r * 0.5)
    }
}

private struct DelayLine {
    let buffer: UnsafeMutablePointer<Float>
    let length: Int
    var index = 0
    var damped: Float = 0

    init(_ length: Int) {
        self.length = length
        buffer = .allocate(capacity: length)
        buffer.initialize(repeating: 0, count: length)
    }

    mutating func comb(_ input: Float) -> Float {
        let out = buffer[index]
        damped = out * 0.7 + damped * 0.3
        buffer[index] = input + damped * 0.8
        index = index + 1 == length ? 0 : index + 1
        return out
    }

    mutating func allpass(_ input: Float) -> Float {
        let delayed = buffer[index]
        buffer[index] = input + delayed * 0.5
        index = index + 1 == length ? 0 : index + 1
        return delayed - input
    }
}
