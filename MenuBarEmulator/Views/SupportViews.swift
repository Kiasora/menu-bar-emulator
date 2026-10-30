import SwiftUI

/// A centered card over a dimmed window (feedback, tip, credits, theme editor). Controller focus stays inside it.
struct SheetCard<Content: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(theme.display(18))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.subtext)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(theme.board))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Close (Esc)")
                .accessibilityLabel("Close")
            }
            FittingScroll { VStack(alignment: .leading, spacing: 14) { content } }
        }
        .foregroundStyle(theme.text)
        .padding(18)
        .frame(maxWidth: 420)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(theme.background))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
        .padding(16)
        .environment(\.padScope, "sheet")
    }
}

/// Writes an email in Mail (nothing is sent until you hit Send there), or message on Ko-fi.
struct FeedbackSheet: View {
    let model: AppModel
    @Environment(\.theme) private var theme
    @State private var kind = "Idea"
    @State private var message = ""
    @State private var includeInfo = true

    var body: some View {
        SheetCard(title: "Send Feedback", close: { model.sheet = nil }) {
            if AppInfo.isEarlyBuild {
                Text("This is an early build, so every bug report and idea really helps.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.subtext)
            }
            SegmentedChoice(options: [("Bug", "Bug"), ("Idea", "Idea"), ("Love it", "Love it")], selection: kind, padID: "feedback-kind") { kind = $0 }
            ZStack(alignment: .topLeading) {
                if message.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.subtext.opacity(0.8))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $message)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
            }
            .frame(height: 120)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.board))
            ToggleRow(title: "Include app and macOS version", isOn: $includeInfo, padID: "feedback-info")
            HStack {
                Button("Message on Ko-fi") { NSWorkspace.shared.open(URL(string: AppInfo.tipURL)!) }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                    .focusable(false)
                Spacer()
                Button("Write Email", action: send)
                    .buttonStyle(PillButtonStyle())
                    .focusable(false)
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .padFocusable("feedback-send", cornerRadius: 15, action: send)
            }
        }
    }

    private var placeholder: String {
        switch kind {
        case "Bug": "What happened, and what did you expect?"
        case "Love it": "What do you like most?"
        default: "What would make it better?"
        }
    }

    private func send() {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let subject = "\(AppInfo.name): \(kind)"
        let body = message + (includeInfo ? "\n\n—\n\(AppInfo.systemInfo)" : "")
        if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [body]) {
            service.recipients = AppInfo.feedbackEmail.isEmpty ? [] : [AppInfo.feedbackEmail]
            service.subject = subject
            service.perform(withItems: [body])
        } else {
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = AppInfo.feedbackEmail
            components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
            if let url = components.url { NSWorkspace.shared.open(url) }
        }
        model.sheet = nil
        model.show("Opened in Mail", "envelope.fill")
    }
}

/// Tip jar on Ko-fi (you pick any amount there; these are just suggestions).
struct TipSheet: View {
    let model: AppModel
    @Environment(\.theme) private var theme
    @State private var amount = 5

    private let options: [(symbol: String, title: String, amount: Int)] = [
        ("cup.and.saucer.fill", "Coffee", 3), ("takeoutbag.and.cup.and.straw.fill", "Snack", 5), ("gamecontroller.fill", "A new game", 10),
    ]

    var body: some View {
        SheetCard(title: "Leave a Tip", close: { model.sheet = nil }) {
            VStack(spacing: 14) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color(hex: 0xFF5A7A))
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Color(hex: 0xFF5A7A).opacity(0.14)))
                    .symbolEffect(.bounce, value: amount)
                Text("No ads, no accounts. If it made a lecture or a commute a little better, a tip keeps it going.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.subtext)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    ForEach(options, id: \.amount) { option in
                        let selected = option.amount == amount
                        Button { amount = option.amount } label: {
                            VStack(spacing: 6) {
                                Image(systemName: option.symbol).font(.system(size: 18))
                                Text(option.title).font(.system(size: 11.5, weight: .medium))
                                Text("$\(option.amount)").font(theme.display(15, .bold))
                            }
                            .foregroundStyle(selected ? theme.onAccent : theme.text)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(selected ? theme.accent : theme.surface))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .padFocusable("tip-\(option.amount)", cornerRadius: 15) { amount = option.amount }
                    }
                }
                Button("Tip $\(amount) on Ko-fi", action: tip)
                    .buttonStyle(PillButtonStyle(large: true))
                    .focusable(false)
                    .padFocusable("tip-go", cornerRadius: 22, action: tip)
                Text("Opens ko-fi.com/kian, where you can change the amount.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.subtext)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func tip() {
        if let url = URL(string: AppInfo.tipURL) { NSWorkspace.shared.open(url) }
        model.sheet = nil
        model.show("Thank you!", "heart.fill")
    }
}

/// Confirms a factory reset. Settings always go; games and saves only if you tick the box (and then to the Trash).
struct ResetSheet: View {
    let model: AppModel
    @Environment(\.theme) private var theme
    @State private var eraseLibrary = false

    var body: some View {
        SheetCard(title: "Reset to Factory Settings", close: { model.sheet = nil }) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.bad)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(theme.bad.opacity(0.14)))
                Text("Puts \(AppInfo.name) back the way it was the first time you opened it: settings, controls, shortcuts, themes, window sizes, open games and the welcome tour. The app restarts.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ToggleRow(title: "Also remove my games and saves",
                      subtitle: "Games, BIOS files, in-game saves, save states, cheats and pictures go to the Trash, so you can still get them back.",
                      isOn: $eraseLibrary, padID: "reset-erase")
                .padding(10)
                .card(12)
            HStack {
                Spacer()
                Button("Cancel") { model.sheet = nil }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                    .focusable(false)
                    .keyboardShortcut(.cancelAction)
                Button(eraseLibrary ? "Erase and Reset" : "Reset", action: reset)
                    .buttonStyle(PillButtonStyle(kind: .destructive))
                    .focusable(false)
                    .padFocusable("reset-confirm", cornerRadius: 15, action: reset)
            }
        }
    }

    private func reset() { model.factoryReset(eraseLibrary: eraseLibrary) }
}

/// The open-source projects inside, their licenses, and where their source lives.
struct CreditsSheet: View {
    let model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        SheetCard(title: "Credits and Licenses", close: { model.sheet = nil }) {
            Text("\(AppInfo.name) \(AppInfo.versionLabel) is built on these open-source projects. Thank you to everyone who made them.")
                .font(.system(size: 12))
                .foregroundStyle(theme.subtext)
            ForEach(AppInfo.credits) { credit in
                Button { NSWorkspace.shared.open(URL(string: credit.url)!) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(credit.name).font(theme.display(13.5, .bold))
                            Spacer()
                            Text(credit.license).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(theme.accent)
                        }
                        Text(credit.detail).font(.system(size: 11.5)).foregroundStyle(theme.subtext).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .card(12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(credit.url)
                .padFocusable("credit-\(credit.name)", cornerRadius: 13) { NSWorkspace.shared.open(URL(string: credit.url)!) }
            }
            Text("Game Boy, Game Boy Advance and Nintendo DS are trademarks of Nintendo. This app isn't affiliated with Nintendo and comes with no games: only play games you own.")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.subtext)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
