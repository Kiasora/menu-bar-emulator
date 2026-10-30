import SwiftUI

/// Make (or edit) a theme: a name, a background color or gradient, and an accent. A live preview shows the result;
/// everything else (cards, text) is worked out so it stays readable.
struct ThemeEditor: View {
    let model: AppModel
    let editingID: String?
    @AppStorage(ThemeKind.storageKey) private var themeRaw = ThemeKind.dark.rawValue
    @Environment(\.theme) private var theme
    @State private var draft: CustomTheme

    static let backgrounds: [UInt32] = [0x0B1020, 0x1C1C1E, 0x262B3F, 0x1E2A4A, 0x14352E, 0x3A1C32,
                                        0x5B2A6E, 0x7A1F2B, 0xF5F5F7, 0xFDF2E9, 0xE7F1FB, 0xFFE6EC]
    static let accents: [UInt32] = [0x0A84FF, 0x5E5CE6, 0xBF5AF2, 0xFF375F, 0xFF453A, 0xFF9F0A,
                                    0xFFD60A, 0x30D158, 0x40C8E0, 0xFF7AB6, 0x8E8E93, 0xFFFFFF]

    init(model: AppModel, editingID: String?) {
        self.model = model
        self.editingID = editingID
        _draft = State(initialValue: editingID.flatMap { model.themes.customTheme(id: $0) }
            ?? CustomTheme(name: "My Theme", top: 0x1E2A4A, bottom: 0x5B2A6E, accent: 0xFF7AB6, diagonal: true))
    }

    var body: some View {
        SheetCard(title: editingID == nil ? "New Theme" : "Edit Theme", close: { model.sheet = nil }) {
            ThemePreview(theme: Theme(custom: draft))
                .frame(height: 110)
                .animation(.easeInOut(duration: 0.25), value: draft)

            TextField("Theme name", text: $draft.name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.board))

            labeled("Background") {
                SwatchRow(colors: Self.backgrounds, selection: $draft.top, padID: "bg-top")
            }
            ToggleRow(title: "Gradient", isOn: Binding {
                draft.bottom != nil
            } set: { on in
                draft.bottom = on ? Theme.mix(draft.top, draft.accent, 0.45) : nil
            }, padID: "gradient")
            if draft.bottom != nil {
                labeled("Gradient to") {
                    SwatchRow(colors: Self.backgrounds + Self.accents, selection: Binding { draft.bottom ?? draft.top } set: { draft.bottom = $0 },
                              padID: "bg-bottom")
                }
                ToggleRow(title: "Diagonal", isOn: $draft.diagonal, padID: "diagonal")
            }
            labeled("Accent") {
                SwatchRow(colors: Self.accents, selection: $draft.accent, padID: "accent")
            }

            HStack {
                if editingID != nil {
                    Button("Delete", role: .destructive, action: delete)
                        .buttonStyle(PillButtonStyle(kind: .quiet))
                        .focusable(false)
                        .padFocusable("theme-delete", cornerRadius: 15, action: delete)
                }
                Spacer()
                Button("Cancel") { model.sheet = nil }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                    .focusable(false)
                Button("Save Theme", action: save)
                    .buttonStyle(PillButtonStyle())
                    .focusable(false)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .padFocusable("theme-save", cornerRadius: 15, action: save)
            }
        }
        .onAppear { NSApp.activate() } // so the system color picker can come forward
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.subtext)
            content()
        }
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        model.themes.save(draft)
        withTransaction(Transaction(animation: nil)) { themeRaw = draft.id }
        model.sheet = nil
        model.show("Theme saved", "paintpalette.fill")
    }

    private func delete() {
        model.themes.delete(draft.id)
        if themeRaw == draft.id { themeRaw = ThemeKind.dark.rawValue }
        model.sheet = nil
    }
}

/// A row of color dots plus the system color picker for anything else. ← → step through the dots on a controller.
private struct SwatchRow: View {
    let colors: [UInt32]
    @Binding var selection: UInt32
    let padID: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(colors, id: \.self) { hex in
                        Button { selection = hex } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(theme.hairline, lineWidth: 1))
                                .padding(2)
                                .overlay(Circle().stroke(hex == selection ? theme.accent : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .accessibilityLabel(String(format: "Color #%06X", hex))
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            ColorPicker("More colors", selection: Binding { Color(hex: selection) } set: { selection = $0.hex }, supportsOpacity: false)
                .labelsHidden()
                .help("Any color")
        }
        .padFocusable(padID, cornerRadius: 14, adjust: step) { step(1) }
    }

    private func step(_ delta: Int) {
        let index = colors.firstIndex(of: selection) ?? -1
        selection = colors[(index + delta + colors.count) % colors.count]
    }
}

/// A tiny library mock in the theme's colors.
private struct ThemePreview: View {
    let theme: Theme

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let gradient = theme.gradient {
                    LinearGradient(colors: gradient, startPoint: theme.diagonal ? .topLeading : .top, endPoint: theme.diagonal ? .bottomTrailing : .bottom)
                } else {
                    theme.background
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Library").font(theme.display(16, .heavy)).foregroundStyle(theme.text)
                    Spacer()
                    Capsule().fill(theme.accent).frame(width: 46, height: 18)
                        .overlay(Text("Add").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.onAccent))
                }
                HStack(spacing: 8) {
                    ForEach([GameSystem.gb, .gba, .nds], id: \.self) { system in
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(theme.surface)
                            .overlay(ConsoleArt(system: system).padding(6))
                            .frame(width: 52, height: 52)
                    }
                    Spacer()
                }
            }
            .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.hairline, lineWidth: 1))
    }
}
