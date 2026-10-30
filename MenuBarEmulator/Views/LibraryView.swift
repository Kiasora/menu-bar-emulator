import SwiftUI

/// Home: support links, title + toolbar, filters, "Jump back in" (open games, showing where you left off), then every
/// game as box art, your own picture, or its console. Arrow keys / a controller move the highlight, Return / A plays.
struct LibraryView: View {
    @Bindable var model: AppModel
    @Environment(\.theme) private var theme
    @FocusState private var searchFocused: Bool
    @State private var drag: GameDrag?
    /// Where each card on screen sits in the grid, for working out which game you're dragging over.
    @State private var cardFrames: [URL: CGRect] = [:]

    /// A game being dragged to a new spot: the card follows the pointer, held where it was grabbed.
    private struct GameDrag {
        let rom: URL
        let grab: CGSize
        let size: CGSize
        var location: CGPoint
        var lifted = true
    }

    var body: some View {
        VStack(spacing: 0) {
            topStrip
            header
            if let update = model.updates.available {
                UpdateBanner(updates: model.updates, update: update)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if model.library.roms.isEmpty {
                EmptyLibrary(model: model)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if model.filters.count > 1 { filterBar }
                            if !model.openGames.isEmpty && model.filter == .all && model.search.isEmpty {
                                JumpBackIn(model: model)
                            }
                            grid
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 18)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: model.selection) {
                        guard let selection = model.selection else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(selection) }
                    }
                }
            }
        }
        .onChange(of: model.isSearching, initial: true) { searchFocused = model.isSearching }
    }

    // MARK: Header

    /// Early-build badge, the lo-fi switches and the two support links, right at the top where people see them.
    private var topStrip: some View {
        HStack(spacing: 10) {
            if AppInfo.isEarlyBuild { EarlyBadge().fixedSize() }
            LofiToggles(model: model).fixedSize()
            Spacer(minLength: 0)
            // The longest labels that fit, so nothing gets cut off in a narrow window.
            ViewThatFits(in: .horizontal) {
                supportLinks(feedback: "Send Feedback", tip: "Leave a Tip")
                supportLinks(feedback: "Feedback", tip: "Leave a Tip")
                supportLinks(feedback: "Feedback", tip: "Tip")
            }
            .layoutPriority(1)
        }
        .font(.system(size: 11.5, weight: .semibold))
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .frame(height: 34)
        .background(WindowDragArea())
    }

    private func supportLinks(feedback: String, tip: String) -> some View {
        HStack(spacing: 10) {
            Button { model.sheet = .feedback } label: { Label(feedback, systemImage: "bubble.left.fill") }
                .buttonStyle(PillButtonStyle(kind: .quiet))
                .focusable(false)
            Button { model.sheet = .tip } label: { Label(tip, systemImage: "heart.fill") }
                .buttonStyle(PillButtonStyle(kind: .quiet))
                .focusable(false)
                .tint(Color(hex: 0xFF5A7A))
        }
        .fixedSize()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            if model.isSearching {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.subtext)
                    TextField("Search games", text: $model.search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($searchFocused)
                        .onSubmit { if let first = model.visibleROMs.first { model.play(first) } }
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Capsule().fill(theme.surface))
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .leading)))
                Button("Cancel") {
                    model.search = ""
                    model.isSearching = false
                }
                .buttonStyle(PillButtonStyle(kind: .quiet))
                .focusable(false)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Library").font(theme.display(30, .heavy))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(theme.subtext)
                }
                .transition(.opacity)
                Spacer(minLength: 6)
                Button { model.importFiles() } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle())
                    .focusable(false)
                    .help("Add games, BIOS files or mod patches (⌘O)")
                ToolbarPill {
                    if !model.library.roms.isEmpty {
                        ToolbarIcon(symbol: "magnifyingglass", label: "Search (⌘F, or just start typing)") { model.isSearching = true }
                    }
                    ToolbarIcon(symbol: model.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                label: model.isFullScreen ? "Exit Full Screen (⌃⌘F)" : "Full Screen (⌃⌘F)") { model.toggleFullScreen() }
                    ToolbarIcon(symbol: "gearshape", label: "Settings (⌘,)") { model.openSettings() }
                    ToolbarIcon(symbol: "minus", label: "Minimize (\(model.prefs.popOutShortcut?.display ?? "menu bar icon") brings it back)") { model.hideWindow() }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .background(WindowDragArea())
        .animation(.snappy(duration: 0.25), value: model.isSearching)
    }

    private var subtitle: String {
        let games = model.library.roms.count
        var parts = [games == 0 ? "No games yet" : "\(games) game\(games == 1 ? "" : "s")"]
        if let time = model.library.totalPlaytime.playtimeLabel { parts.append("\(time) played") }
        return parts.joined(separator: " · ")
    }

    /// Stretches across the whole width, however many systems you have.
    private var filterBar: some View {
        StretchFilter(options: model.filters.map { filter in
            switch filter {
            case .all: ("All", nil, filter)
            case .favorites: ("Favorites", "star.fill", filter)
            case .system(let system): (system.shortName, nil, filter)
            }
        }, selection: model.filter) { model.filter = $0 }
        .help("Controller: L / R to switch")
    }

    // MARK: Grid

    private var grid: some View {
        let roms = model.visibleROMs
        return VStack(alignment: .leading, spacing: 10) {
            if !model.openGames.isEmpty && model.filter == .all && model.search.isEmpty {
                SectionTitle(text: "All games")
            }
            if roms.isEmpty {
                Text(model.search.isEmpty ? "Nothing here yet." : "No games match “\(model.search)”.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.subtext)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116, maximum: 170), spacing: 14, alignment: .top)], alignment: .leading, spacing: 18) {
                ForEach(roms, id: \.self) { rom in
                    GameCard(model: model, rom: rom, selected: model.selection == rom)
                        .opacity(drag?.rom == rom ? 0.25 : 1) // its spot, while the lifted copy follows the pointer
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("grid")) } action: { cardFrames[rom] = $0 }
                        .onDisappear { cardFrames[rom] = nil }
                        // Hold and drag to move a game. A plain click still plays it (the drag needs a few points).
                        .highPriorityGesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("grid"))
                            .onChanged { dragChanged(rom, $0) }
                            .onEnded { _ in dragEnded() })
                        .id(rom)
                }
            }
            .onGeometryChange(for: Int.self) { proxy in max(1, Int((proxy.size.width + 14) / (116 + 14))) } action: { model.libraryColumns = $0 }
            .animation(.snappy(duration: 0.3), value: roms)
            .overlay(alignment: .topLeading) {
                if let drag {
                    GameCard(model: model, rom: drag.rom, selected: false)
                        .frame(width: drag.size.width, height: drag.size.height)
                        .scaleEffect(drag.lifted ? 1.06 : 1)
                        .shadow(color: .black.opacity(drag.lifted ? 0.35 : 0), radius: 18, y: 12)
                        .offset(x: drag.location.x - drag.grab.width, y: drag.location.y - drag.grab.height)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(.named("grid"))
        }
    }

    private func dragChanged(_ rom: URL, _ value: DragGesture.Value) {
        if drag == nil, let frame = cardFrames[rom] {
            let grab = CGSize(width: value.startLocation.x - frame.minX, height: value.startLocation.y - frame.minY)
            withAnimation(.snappy(duration: 0.2)) { drag = GameDrag(rom: rom, grab: grab, size: frame.size, location: value.location) }
        }
        drag?.location = value.location
        // Take the spot of the game under the pointer. Only a card's middle counts, so it can't flip back and forth on an edge.
        let target = cardFrames.first { other, frame in
            other != rom && frame.insetBy(dx: frame.width * 0.15, dy: frame.height * 0.15).contains(value.location)
        }
        if let target { model.library.move(rom, to: target.key) }
    }

    /// Settles the card into its new spot, then puts the real one back.
    private func dragEnded() {
        guard let current = drag, let spot = cardFrames[current.rom] else { drag = nil; return }
        withAnimation(.snappy(duration: 0.22)) {
            drag?.location = CGPoint(x: spot.minX + current.grab.width, y: spot.minY + current.grab.height)
            drag?.lifted = false
        } completion: {
            if drag?.rom == current.rom { drag = nil }
        }
    }
}

private struct SectionTitle: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text).font(theme.display(15, .bold))
    }
}

// MARK: - Update banner

/// "Version 1.1 is out", with Kian's message from update.json and a button to get it.
private struct UpdateBanner: View {
    let updates: UpdateChecker
    let update: UpdateChecker.Update
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Version \(update.version) is out").font(.system(size: 13, weight: .semibold))
                if let message = update.message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.subtext)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            Button("Get it") { NSWorkspace.shared.open(updates.link) }
                .buttonStyle(PillButtonStyle())
                .focusable(false)
                .padFocusable("update-get", cornerRadius: 15) { NSWorkspace.shared.open(updates.link) }
            Button { withAnimation(.snappy) { updates.dismiss() } } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.subtext)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Hide until the next version")
            .accessibilityLabel("Hide update")
        }
        .padding(12)
        .card(14)
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }
}

// MARK: - Jump back in

private struct JumpBackIn: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Jump back in")
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(model.openGames, id: \.self) { rom in
                        ResumeCard(model: model, rom: rom)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
        }
    }
}

private struct ResumeCard: View {
    let model: AppModel
    let rom: URL
    @Environment(\.theme) private var theme
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        Button { model.play(rom) } label: {
            ZStack(alignment: .bottomLeading) {
                Color.black
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().interpolation(.none).aspectRatio(contentMode: .fill)
                } else if let system = GameSystem(rom: rom) {
                    CoverFallback(system: system)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: UnitPoint(x: 0.5, y: 0.3), endPoint: .bottom)
                VStack(alignment: .leading, spacing: 1) {
                    Text(rom.gameTitle).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
                    Text(detail).font(.system(size: 10.5, weight: .medium)).opacity(0.75).lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(10)
            }
            .frame(width: 196, height: 124)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if hovering {
                    GlassButton(symbol: "xmark", label: "Close \(rom.gameTitle)", size: 22) { model.closeGame(rom) }
                        .padding(7)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topLeading) {
                if model.emulator.game == rom {
                    Label("Paused", systemImage: "pause.fill")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(Capsule().fill(theme.accent))
                        .padding(8)
                }
            }
            .scaleEffect(hovering ? 1.025 : 1)
            .shadow(color: .black.opacity(hovering ? 0.3 : 0.15), radius: hovering ? 10 : 5, y: 4)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hover in withAnimation(.easeOut(duration: 0.15)) { hovering = hover } }
        .task(id: model.emulator.stateVersion) {
            thumbnail = model.emulator.game == rom
                ? model.emulator.snapshot.map { NSImage(cgImage: $0, size: .zero) } ?? model.emulator.resumeThumbnail(for: rom)
                : model.emulator.resumeThumbnail(for: rom)
        }
        .accessibilityLabel("Continue \(rom.gameTitle)")
    }

    private var detail: String {
        var parts = [GameSystem(rom: rom)?.shortName ?? ""]
        if let time = model.library.meta(for: rom).playtime.playtimeLabel { parts.append(time) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Game card

private struct GameCard: View {
    let model: AppModel
    let rom: URL
    let selected: Bool
    @Environment(\.theme) private var theme
    @State private var hovering = false
    @State private var dropping = false

    private var system: GameSystem? { GameSystem(rom: rom) }
    private var meta: Library.GameMeta { model.library.meta(for: rom) }

    var body: some View {
        Button { model.play(rom) } label: {
            VStack(alignment: .leading, spacing: 8) {
                cover
                VStack(alignment: .leading, spacing: 2) {
                    Text(rom.gameTitle)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.subtext)
                        .lineLimit(1)
                }
                .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hover in withAnimation(.easeOut(duration: 0.15)) { hovering = hover } }
        // Drop an image on a game to make it its picture (anything else still gets imported).
        .dropDestination(for: URL.self) { urls, _ in
            if let image = urls.first(where: { Covers.imageExtensions.contains($0.pathExtension.lowercased()) }) {
                return model.setPicture(image, for: rom)
            }
            return model.importURLs(urls)
        } isTargeted: { dropping = $0 }
        .contextMenu {
            Button("Play") { model.play(rom) }
            Button(meta.favorite ? "Remove from Favorites" : "Add to Favorites") { model.library.toggleFavorite(rom) }
            Divider()
            Button("Choose Picture…") { model.choosePicture(for: rom) }
            if model.covers.hasCustom(rom) { Button("Use Default Picture") { model.covers.removeCustom(rom) } }
            Button("Apply Mod Patch…") { model.applyPatch(to: rom) }
            Divider()
            Button("Export Save File…") { model.exportSave(for: rom) }
            Button("Import Save File…") { model.importSave(for: rom) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([rom]) }
            Divider()
            Button("Remove from Library", role: .destructive) { model.remove(rom) }
        }
        .task { await model.covers.load(rom) }
        .accessibilityLabel("\(rom.gameTitle), \(system?.title ?? "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var cover: some View {
        ZStack {
            if let image = model.covers.image(for: rom) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).blur(radius: 18).opacity(0.7)
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                    .padding(8)
            } else if let system {
                CoverFallback(system: system)
            }
            if dropping {
                Color.black.opacity(0.45)
                Label("Use as picture", systemImage: "photo.badge.plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .background(theme.board)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(selected && !hovering ? theme.accent : .clear, lineWidth: 2.5)
        }
        .overlay(alignment: .topTrailing) {
            if meta.favorite || hovering {
                Button { model.library.toggleFavorite(rom) } label: {
                    Image(systemName: meta.favorite ? "star.fill" : "star")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(meta.favorite ? Color(hex: 0xFFC83D) : .white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.black.opacity(0.45)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .padding(6)
                .help(meta.favorite ? "Remove from Favorites" : "Add to Favorites")
                .accessibilityLabel(meta.favorite ? "Remove from Favorites" : "Add to Favorites")
                .transition(.opacity)
            }
        }
        .scaleEffect(hovering ? 1.04 : 1)
        .shadow(color: .black.opacity(hovering ? 0.28 : theme.isDark ? 0.2 : 0.1), radius: hovering ? 12 : 5, y: hovering ? 6 : 3)
    }

    private var detail: String {
        var parts = [system?.shortName ?? ""]
        if let time = meta.playtime.playtimeLabel { parts.append(time) }
        return parts.joined(separator: " · ")
    }
}

/// Console drawing on a soft gradient in the console's color, for games without box art.
struct CoverFallback: View {
    let system: GameSystem

    var body: some View {
        let tint = Color(hex: system.color)
        ZStack {
            LinearGradient(colors: [tint.mix(with: .white, by: 0.18), tint.mix(with: .black, by: 0.28)], startPoint: .topLeading, endPoint: .bottomTrailing)
            ConsoleArt(system: system)
                .padding(16)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 4)
        }
    }
}

// MARK: - Empty library

private struct EmptyLibrary: View {
    let model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 10)
            FloatingConsoles(size: 70)
            VStack(spacing: 7) {
                Text("Your games live here").font(theme.display(22, .heavy))
                Text("Add Game Boy, Game Boy Color, Game Boy Advance\nand DS games. Drop files or a folder anywhere.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.subtext)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            Button { model.importFiles() } label: { Label("Add Games", systemImage: "plus") }
                .buttonStyle(PillButtonStyle(large: true))
                .focusable(false)
            if !model.library.bios.isEmpty {
                Label("BIOS files ready", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.good)
            }
            Spacer(minLength: 10)
            Spacer(minLength: 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
}

/// The four consoles, gently bobbing out of step. Driven by Core Animation, so it's as smooth as the display
/// (still with Reduce Motion).
struct FloatingConsoles: View {
    var size: CGFloat = 70
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var floating = false

    var body: some View {
        HStack(spacing: size * 0.08) {
            ForEach(Array(GameSystem.allCases.enumerated()), id: \.element) { index, system in
                ConsoleArt(system: system)
                    .frame(width: size, height: size)
                    .offset(y: floating ? -size * 0.06 : size * 0.06)
                    .rotationEffect(.degrees(floating ? 2.5 : -2.5))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.7 + Double(index) * 0.17)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.21), value: floating)
            }
        }
        .drawingGroup()
        .onAppear { floating = !reduceMotion }
        .accessibilityHidden(true)
    }
}
