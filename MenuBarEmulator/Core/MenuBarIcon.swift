import AppKit
import CryptoKit

/// What sits in the menu bar. The controller is free; the rest, and your own picture, unlock with a supporter code
/// that comes with a tip on Ko-fi. Everyone can see them all, so they know what a tip gets them.
enum MenuBarIcon: String, CaseIterable, Identifiable {
    case controller, pokeball, handheld, dpad, arcade, bolt, flame, leaf, drop, moon, sparkles, crown, heart, star, paw
    /// The supporter's own picture (Application Support/MenuBarEmulator/menu-bar-icon.png).
    case custom

    var id: String { rawValue }

    static let choices = allCases.filter { $0 != .custom }

    var isFree: Bool { self == .controller }

    var title: String {
        switch self {
        case .controller: "Controller"
        case .pokeball: "Poké Ball"
        case .handheld: "Handheld"
        case .dpad: "D-pad"
        case .arcade: "Arcade Stick"
        case .bolt: "Electric"
        case .flame: "Fire"
        case .leaf: "Grass"
        case .drop: "Water"
        case .moon: "Night"
        case .sparkles: "Shiny"
        case .crown: "Champion"
        case .heart: "Heart"
        case .star: "Star"
        case .paw: "Paw"
        case .custom: "Your Picture"
        }
    }

    /// SF Symbol for the ones macOS already draws; nil for the hand-drawn ones.
    private var symbol: String? {
        switch self {
        case .controller: "gamecontroller.fill"
        case .arcade: "arcade.stick"
        case .bolt: "bolt.fill"
        case .flame: "flame.fill"
        case .leaf: "leaf.fill"
        case .drop: "drop.fill"
        case .moon: "moon.stars.fill"
        case .sparkles: "sparkles"
        case .crown: "crown.fill"
        case .heart: "heart.fill"
        case .star: "star.fill"
        case .paw: "pawprint.fill"
        case .pokeball, .handheld, .dpad, .custom: nil
        }
    }

    /// The menu bar image: a template (black and clear, so macOS tints it like every other icon), except your own picture.
    func image(customFile: URL) -> NSImage? {
        if self == .custom {
            guard let picture = NSImage(contentsOf: customFile) else { return nil }
            let height: CGFloat = 18
            let width = min(height * 1.6, height * picture.size.width / max(picture.size.height, 1))
            let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
                picture.draw(in: rect)
                return true
            }
            return image
        }
        let image: NSImage?
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: AppInfo.name)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        } else {
            image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                NSColor.black.set()
                draw(in: rect.insetBy(dx: 1.5, dy: 1.5))
                return true
            }
        }
        image?.isTemplate = true
        return image
    }

    private func draw(in r: NSRect) {
        switch self {
        case .pokeball:
            // Solid top half, outlined bottom half, a ring for the button: reads as a Poké Ball at 15 points.
            let center = NSPoint(x: r.midX, y: r.midY), radius = r.width / 2, hole: CGFloat = 4
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            ring.stroke()
            let top = NSBezierPath() // the upper half, from points so its direction can't flip
            for step in 0...24 {
                let angle = Double(step) / 24 * .pi
                let point = NSPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                if step == 0 { top.move(to: point) } else { top.line(to: point) }
            }
            top.close()
            top.fill()
            NSBezierPath(rect: NSRect(x: r.minX, y: center.y - 0.75, width: r.width, height: 1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: center.x - hole, y: center.y - hole, width: hole * 2, height: hole * 2)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            let button = NSBezierPath(ovalIn: NSRect(x: center.x - 2.4, y: center.y - 2.4, width: 4.8, height: 4.8))
            button.lineWidth = 1.2
            button.stroke()
        case .handheld:
            let body = NSBezierPath(roundedRect: NSRect(x: r.minX + 2.5, y: r.minY, width: r.width - 5, height: r.height), xRadius: 2, yRadius: 2)
            body.fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(rect: NSRect(x: r.minX + 4.5, y: r.midY + 0.5, width: r.width - 9, height: r.height / 2 - 2.5)).fill()
            NSBezierPath(rect: NSRect(x: r.minX + 5, y: r.minY + 3.5, width: 4, height: 1.3)).fill() // d-pad
            NSBezierPath(rect: NSRect(x: r.minX + 6.35, y: r.minY + 2.15, width: 1.3, height: 4)).fill()
            NSBezierPath(ovalIn: NSRect(x: r.maxX - 7, y: r.minY + 4.2, width: 2.2, height: 2.2)).fill() // A and B
            NSBezierPath(ovalIn: NSRect(x: r.maxX - 9.4, y: r.minY + 2.4, width: 2.2, height: 2.2)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        case .dpad:
            let arm = r.width / 3
            NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.midY - arm / 2, width: r.width, height: arm), xRadius: 1.5, yRadius: 1.5).fill()
            NSBezierPath(roundedRect: NSRect(x: r.midX - arm / 2, y: r.minY, width: arm, height: r.height), xRadius: 1.5, yRadius: 1.5).fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: r.midX - 1.6, y: r.midY - 1.6, width: 3.2, height: 3.2)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        default:
            break
        }
    }
}

/// The code people get for tipping. Only its hash is here. The source is public, so anyone determined can get around
/// this; it's a thank-you, not copy protection.
enum SupporterCode {
    private static let hash = "d1f962539097669782422374de11b246a9be913fb0cae874504c7e51801bf735"

    static func isValid(_ code: String) -> Bool {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() == hash
    }
}
