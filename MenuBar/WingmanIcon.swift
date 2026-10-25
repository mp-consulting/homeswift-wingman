import AppKit

/// The approved winged house, drawn as vectors for crisp menu-bar and Retina rendering.
@MainActor
enum WingmanIcon {
    static func mark(in rect: NSRect, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: rect.width / 500, y: -rect.height / 320)
        context.setFillColor(color.cgColor)
        context.setStrokeColor(color.cgColor)
        // Each wing grows out of its corresponding roof slope.
        for mirrored in [false, true] {
            context.saveGState()
            if mirrored { context.translateBy(x: 500, y: 0); context.scaleBy(x: -1, y: 1) }
            let wing = CGMutablePath()
            wing.move(to: CGPoint(x: 8, y: 12))
            wing.addCurve(to: CGPoint(x: 180, y: 110), control1: CGPoint(x: 65, y: 48), control2: CGPoint(x: 155, y: 88))
            wing.addCurve(to: CGPoint(x: 195, y: 148), control1: CGPoint(x: 198, y: 121), control2: CGPoint(x: 204, y: 136))
            wing.addLine(to: CGPoint(x: 165, y: 177))
            wing.addCurve(to: CGPoint(x: 149, y: 121), control1: CGPoint(x: 180, y: 144), control2: CGPoint(x: 170, y: 131))
            wing.addCurve(to: CGPoint(x: 8, y: 12), control1: CGPoint(x: 47, y: 95), control2: CGPoint(x: 6, y: 88))
            wing.closeSubpath()
            context.addPath(wing); context.fillPath()
            let middle = CGMutablePath()
            middle.move(to: CGPoint(x: 36, y: 112))
            middle.addLine(to: CGPoint(x: 150, y: 152))
            middle.addLine(to: CGPoint(x: 132, y: 177))
            middle.addCurve(to: CGPoint(x: 36, y: 112), control1: CGPoint(x: 64, y: 163), control2: CGPoint(x: 42, y: 161))
            middle.closeSubpath()
            context.addPath(middle); context.fillPath()
            let lower = CGMutablePath()
            lower.move(to: CGPoint(x: 58, y: 177))
            lower.addLine(to: CGPoint(x: 121, y: 193))
            lower.addLine(to: CGPoint(x: 109, y: 221))
            lower.addCurve(to: CGPoint(x: 58, y: 177), control1: CGPoint(x: 77, y: 220), control2: CGPoint(x: 63, y: 203))
            lower.closeSubpath()
            context.addPath(lower); context.fillPath()
            context.restoreGState()
        }
        context.setLineWidth(29)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.beginPath()
        context.move(to: CGPoint(x: 136, y: 220))
        context.addLine(to: CGPoint(x: 250, y: 104))
        context.addLine(to: CGPoint(x: 364, y: 220))
        context.move(to: CGPoint(x: 153, y: 205))
        context.addLine(to: CGPoint(x: 153, y: 305))
        context.addLine(to: CGPoint(x: 347, y: 305))
        context.addLine(to: CGPoint(x: 347, y: 205))
        context.strokePath()
        context.restoreGState()
    }

    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 25, height: 16), flipped: false) { rect in
            mark(in: rect, color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Homeswift Wingman"
        return image
    }

    static func badge(in rect: NSRect, rounded: Bool = true) {
        let outline = NSBezierPath(roundedRect: rect, xRadius: rounded ? rect.width * 0.22 : 0,
                                  yRadius: rounded ? rect.height * 0.22 : 0)
        NSGradient(starting: NSColor(srgbRed: 1, green: 0.627, blue: 0.110, alpha: 1),
                   ending: NSColor(srgbRed: 0.941, green: 0.267, blue: 0.180, alpha: 1))!
            .draw(in: outline, angle: -45)
        mark(in: NSRect(x: rect.minX + rect.width * 0.075, y: rect.minY + rect.height * 0.205,
                       width: rect.width * 0.85, height: rect.height * 0.544), color: .white)
    }
}
