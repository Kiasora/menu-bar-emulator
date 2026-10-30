import SwiftUI

/// Flat vector illustration of each handheld, drawn in a 100×100 box and scaled to the view.
struct ConsoleArt: View {
    let system: GameSystem

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height) / 100
            let origin = CGPoint(x: (size.width - unit * 100) / 2, y: (size.height - unit * 100) / 2)
            let art = Art(context: context, unit: unit, origin: origin)
            switch system {
            case .gb: art.gameBoy(body: 0xCBC8C3, bezel: 0x6A6D78, screen: [0x9BBC0F, 0x7E9E0E], buttons: 0xA2215F, color: false)
            case .gbc: art.gameBoy(body: 0x7B4BB8, bezel: 0x2C2B33, screen: [0x6FD3E8, 0xF2A6C8], buttons: 0x3A3942, color: true)
            case .gba: art.advance()
            case .nds: art.ds()
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(system.title)
    }
}

private struct Art {
    let context: GraphicsContext
    let unit: CGFloat
    let origin: CGPoint

    init(context: GraphicsContext, unit: CGFloat, origin: CGPoint) {
        self.context = context
        self.unit = unit
        self.origin = origin
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: origin.x + x * unit, y: origin.y + y * unit, width: w * unit, height: h * unit)
    }

    private func color(_ hex: UInt32, _ alpha: Double = 1) -> GraphicsContext.Shading { .color(Color(hex: hex, alpha: alpha)) }

    private func fill(_ r: CGRect, _ shading: GraphicsContext.Shading, radius: CGFloat = 0, bottomTrailing: CGFloat? = nil) {
        let radii = RectangleCornerRadii(topLeading: radius * unit, bottomLeading: radius * unit,
                                         bottomTrailing: (bottomTrailing ?? radius) * unit, topTrailing: radius * unit)
        context.fill(Path(roundedRect: r, cornerRadii: radii, style: .continuous), with: shading)
    }

    private func gradient(_ r: CGRect, _ top: UInt32, _ bottom: UInt32) -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: [Color(hex: top), Color(hex: bottom)]),
                        startPoint: CGPoint(x: r.minX, y: r.minY), endPoint: CGPoint(x: r.maxX, y: r.maxY))
    }

    private func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ shading: GraphicsContext.Shading) {
        context.fill(Path(ellipseIn: rect(cx - r, cy - r, r * 2, r * 2)), with: shading)
    }

    private func dpad(_ cx: CGFloat, _ cy: CGFloat, _ arm: CGFloat, _ hex: UInt32) {
        let t = arm * 0.36
        fill(rect(cx - arm, cy - t, arm * 2, t * 2), color(hex), radius: t * 0.35)
        fill(rect(cx - t, cy - arm, t * 2, arm * 2), color(hex), radius: t * 0.35)
    }

    private func pill(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ hex: UInt32) {
        fill(rect(cx - w / 2, cy - 1.1, w, 2.2), color(hex), radius: 1.1)
    }

    /// Body shadow: a soft, slightly offset copy under the shape.
    private func shadow(_ r: CGRect, radius: CGFloat, bottomTrailing: CGFloat? = nil) {
        var c = context
        c.addFilter(.blur(radius: 2.5 * unit))
        let radii = RectangleCornerRadii(topLeading: radius * unit, bottomLeading: radius * unit,
                                         bottomTrailing: (bottomTrailing ?? radius) * unit, topTrailing: radius * unit)
        c.fill(Path(roundedRect: r.offsetBy(dx: 0, dy: 2 * unit), cornerRadii: radii, style: .continuous), with: .color(.black.opacity(0.25)))
    }

    /// Original Game Boy and Game Boy Color share a shape; the Color is smaller and rounder.
    func gameBoy(body: UInt32, bezel: UInt32, screen: [UInt32], buttons: UInt32, color isColor: Bool) {
        let b = isColor ? rect(23, 5, 54, 90) : rect(21, 4, 58, 92)
        let corner: CGFloat = isColor ? 7 : 4
        let tail: CGFloat = isColor ? 14 : 20
        shadow(b, radius: corner, bottomTrailing: tail)
        fill(b, gradient(b, body, Art.darken(body)), radius: corner, bottomTrailing: tail)

        let bz = isColor ? rect(28, 11, 44, 35) : rect(26, 10, 48, 38)
        fill(bz, color(bezel), radius: 3, bottomTrailing: isColor ? 3 : 9)
        let sc = isColor ? rect(34, 15, 32, 27) : rect(33, 15, 34, 28)
        fill(sc, gradient(sc, screen[0], screen[1]), radius: 1)
        if !isColor { circle(29.5, 24, 1, color(0xD0312D)) } // power LED

        let padY: CGFloat = isColor ? 63 : 64
        dpad(isColor ? 35 : 34, padY, 6.5, 0x2A2A2E)
        circle(isColor ? 65 : 66, padY - 3, 4.2, self.color(buttons))
        circle(isColor ? 57 : 57, padY + 2, 4.2, self.color(buttons))
        pill(45, 80, 6, isColor ? 0x2A2A2E : 0x8E8B92)
        pill(54, 80, 6, isColor ? 0x2A2A2E : 0x8E8B92)
        for i in 0..<5 { // speaker grille
            let x = CGFloat(isColor ? 62 : 63) + CGFloat(i) * 2.6
            fill(rect(x, isColor ? 82 : 82, 1.2, 8), self.color(0x000000, 0.18), radius: 0.6)
        }
    }

    func advance() {
        let b = rect(4, 27, 92, 50)
        shadow(b, radius: 22)
        fill(rect(10, 25, 18, 6), color(0x2F3290), radius: 3) // shoulder buttons
        fill(rect(72, 25, 18, 6), color(0x2F3290), radius: 3)
        fill(b, gradient(b, 0x5B5FD6, 0x3A3DA6), radius: 22)

        let bz = rect(30, 33, 40, 31)
        fill(bz, color(0x1D1D26), radius: 4)
        let sc = rect(34, 36.5, 32, 22)
        fill(sc, gradient(sc, 0x7FC8F8, 0xF7D26B), radius: 1)
        fill(rect(34, 51, 32, 7.5), color(0x5DBB63)) // a little landscape
        circle(60, 41.5, 2.2, color(0xFFF4C2))

        dpad(17, 49, 6.5, 0x23233A)
        circle(85, 45, 4, color(0xD9D9F0))
        circle(77, 52, 4, color(0xD9D9F0))
        circle(44, 69, 1.2, color(0x23233A))
        circle(56, 69, 1.2, color(0x23233A))
    }

    func ds() {
        let top = rect(17, 4, 66, 44)
        let bottom = rect(17, 52, 66, 44)
        shadow(top, radius: 5)
        shadow(bottom, radius: 5)
        fill(top, gradient(top, 0xF4F5F8, 0xD9DBE2), radius: 5)
        fill(rect(19, 47, 62, 6), color(0xB9BCC6), radius: 2) // hinge
        fill(bottom, gradient(bottom, 0xF4F5F8, 0xD3D6DE), radius: 5)

        let ts = rect(28, 10, 44, 33)
        fill(ts, color(0x22232B), radius: 2.5)
        let tsi = ts.insetBy(dx: 2.2 * unit, dy: 2.2 * unit)
        fill(tsi, gradient(tsi, 0x8EC5FF, 0xC8A6FF), radius: 1)

        let bs = rect(34, 58, 32, 26)
        fill(bs, color(0x22232B), radius: 2)
        let bsi = bs.insetBy(dx: 1.8 * unit, dy: 1.8 * unit)
        fill(bsi, gradient(bsi, 0xFFE3A3, 0xFFB3C1), radius: 0.8)

        dpad(25.5, 68, 4.6, 0x3A3C46)
        circle(75, 64, 2.1, color(0x3A3C46)) // X
        circle(75, 72, 2.1, color(0x3A3C46)) // B
        circle(71, 68, 2.1, color(0x3A3C46)) // Y
        circle(79, 68, 2.1, color(0x3A3C46)) // A
        circle(77, 82, 1.1, color(0x3A3C46))
        circle(77, 86, 1.1, color(0x3A3C46))
    }

    static func darken(_ hex: UInt32) -> UInt32 {
        let r = (hex >> 16) & 0xFF, g = (hex >> 8) & 0xFF, b = hex & 0xFF
        return (r * 85 / 100) << 16 | (g * 85 / 100) << 8 | (b * 85 / 100)
    }
}
