import AppKit
import SolitaireCore

/// Draws card faces and backs with Core Graphics. Images are cached per size.
@MainActor
final class CardRenderer {
    static let shared = CardRenderer()
    static let aspect: CGFloat = 1.4  // height / width

    private var faceCache: [String: CGImage] = [:]
    private var backCache: [Int: CGImage] = [:]
    private var emptyCache: [String: CGImage] = [:]

    let red = NSColor(srgbRed: 0.84, green: 0.13, blue: 0.16, alpha: 1)
    let black = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1)
    let backBlue = NSColor(srgbRed: 0.10, green: 0.22, blue: 0.62, alpha: 1)

    /// Drop every cached image except those for the given card width, so live resizing doesn't pile up bitmaps.
    func evict(exceptWidth width: CGFloat, scale: CGFloat) {
        let keep = "-\(Int(width * scale))"
        faceCache = faceCache.filter { $0.key.hasSuffix(keep) }
        emptyCache = emptyCache.filter { $0.key.hasSuffix(keep) }
        backCache = backCache.filter { $0.key == Int(width * scale) }
    }

    func face(_ card: Card, width: CGFloat, scale: CGFloat) -> CGImage {
        let key = "\(card.id)-\(Int(width * scale))"
        if let img = faceCache[key] { return img }
        let img = render(width: width, scale: scale) { ctx, size in self.drawFace(card, in: ctx, size: size) }
        faceCache[key] = img
        return img
    }

    func back(width: CGFloat, scale: CGFloat) -> CGImage {
        let key = Int(width * scale)
        if let img = backCache[key] { return img }
        let img = render(width: width, scale: scale) { ctx, size in self.drawBack(in: ctx, size: size) }
        backCache[key] = img
        return img
    }

    /// Placeholder for an empty pile: a translucent outline, optionally with a glyph.
    func emptySlot(glyph: String?, width: CGFloat, scale: CGFloat) -> CGImage {
        let key = "\(glyph ?? "")-\(Int(width * scale))"
        if let img = emptyCache[key] { return img }
        let img = render(width: width, scale: scale) { ctx, size in
            let r = self.cardRect(size).insetBy(dx: 1, dy: 1)
            let path = CGPath(roundedRect: r, cornerWidth: size.width * 0.07, cornerHeight: size.width * 0.07, transform: nil)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.10).cgColor)
            ctx.setLineWidth(2)
            ctx.addPath(path); ctx.drawPath(using: .fillStroke)
            if let glyph {
                self.drawText(glyph, in: ctx, at: CGPoint(x: size.width / 2, y: size.height / 2),
                              font: NSFont.systemFont(ofSize: size.width * 0.5, weight: .semibold),
                              color: NSColor.white.withAlphaComponent(0.30), centered: true)
            }
        }
        emptyCache[key] = img
        return img
    }

    // MARK: - Drawing

    private func render(width: CGFloat, scale: CGFloat, _ body: (CGContext, CGSize) -> Void) -> CGImage {
        let size = CGSize(width: width, height: (width * Self.aspect).rounded())
        let px = CGSize(width: size.width * scale, height: size.height * scale)
        let ctx = CGContext(data: nil, width: Int(px.width), height: Int(px.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        body(ctx, size)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    private func cardRect(_ size: CGSize) -> CGRect { CGRect(origin: .zero, size: size) }

    private func cardPath(_ size: CGSize, inset: CGFloat = 0.5) -> CGPath {
        let r = cardRect(size).insetBy(dx: inset, dy: inset)
        let radius = size.width * 0.07
        return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private func drawFace(_ card: Card, in ctx: CGContext, size: CGSize) {
        let w = size.width, h = size.height
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor(white: 0.70, alpha: 1).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(cardPath(size)); ctx.drawPath(using: .fillStroke)

        let color = card.isRed ? red : black
        let suit = card.suit.symbol
        let indexFont = NSFont.systemFont(ofSize: w * 0.19, weight: .semibold)
        let indexSuitFont = suitFont(size: w * 0.17)

        // Corner indices: top-left upright, bottom-right rotated.
        let margin = w * 0.06
        drawText(card.rankLabel, in: ctx, at: CGPoint(x: margin, y: h - margin - w * 0.20), font: indexFont, color: color, centered: false)
        drawText(suit, in: ctx, at: CGPoint(x: margin, y: h - margin - w * 0.20 - w * 0.19), font: indexSuitFont, color: color, centered: false)
        ctx.saveGState()
        ctx.translateBy(x: w, y: h); ctx.rotate(by: .pi)
        drawText(card.rankLabel, in: ctx, at: CGPoint(x: margin, y: h - margin - w * 0.20), font: indexFont, color: color, centered: false)
        drawText(suit, in: ctx, at: CGPoint(x: margin, y: h - margin - w * 0.20 - w * 0.19), font: indexSuitFont, color: color, centered: false)
        ctx.restoreGState()

        // Body
        let body = CGRect(x: w * 0.20, y: h * 0.14, width: w * 0.60, height: h * 0.72)
        switch card.rank {
        case 1:
            drawText(suit, in: ctx, at: CGPoint(x: w / 2, y: h / 2), font: suitFont(size: w * 0.55), color: color, centered: true)
        case 2...10:
            let pipFont = suitFont(size: w * 0.24)
            for (x, y) in Self.pipLayout[card.rank]! {
                let p = CGPoint(x: body.minX + body.width * x, y: body.maxY - body.height * y)
                if y > 0.5 {
                    ctx.saveGState(); ctx.translateBy(x: p.x, y: p.y); ctx.rotate(by: .pi)
                    drawText(suit, in: ctx, at: .zero, font: pipFont, color: color, centered: true)
                    ctx.restoreGState()
                } else {
                    drawText(suit, in: ctx, at: p, font: pipFont, color: color, centered: true)
                }
            }
        default:
            // Court cards: framed panel with a large letter and two suit marks.
            let frame = body.insetBy(dx: w * 0.02, dy: h * 0.02)
            let framePath = CGPath(roundedRect: frame, cornerWidth: w * 0.04, cornerHeight: w * 0.04, transform: nil)
            ctx.setFillColor(color.withAlphaComponent(0.07).cgColor)
            ctx.setStrokeColor(color.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(w * 0.018)
            ctx.addPath(framePath); ctx.drawPath(using: .fillStroke)
            let inner = frame.insetBy(dx: w * 0.045, dy: w * 0.045)
            ctx.setLineWidth(w * 0.008)
            ctx.addPath(CGPath(roundedRect: inner, cornerWidth: w * 0.03, cornerHeight: w * 0.03, transform: nil)); ctx.strokePath()
            let letterFont = NSFont(name: "Georgia-Bold", size: w * 0.42) ?? NSFont.systemFont(ofSize: w * 0.42, weight: .bold)
            drawText(card.rankLabel, in: ctx, at: CGPoint(x: w / 2, y: h / 2), font: letterFont, color: color, centered: true)
            let small = suitFont(size: w * 0.16)
            drawText(suit, in: ctx, at: CGPoint(x: inner.minX + w * 0.11, y: inner.maxY - w * 0.11), font: small, color: color, centered: true)
            ctx.saveGState(); ctx.translateBy(x: inner.maxX - w * 0.11, y: inner.minY + w * 0.11); ctx.rotate(by: .pi)
            drawText(suit, in: ctx, at: .zero, font: small, color: color, centered: true)
            ctx.restoreGState()
        }
    }

    private func drawBack(in ctx: CGContext, size: CGSize) {
        let w = size.width
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor(white: 0.70, alpha: 1).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(cardPath(size)); ctx.drawPath(using: .fillStroke)
        let inner = cardRect(size).insetBy(dx: w * 0.055, dy: w * 0.055)
        let innerPath = CGPath(roundedRect: inner, cornerWidth: w * 0.04, cornerHeight: w * 0.04, transform: nil)
        ctx.saveGState()
        ctx.addPath(innerPath); ctx.clip()
        ctx.setFillColor(backBlue.cgColor)
        ctx.fill(inner)
        // Diagonal lattice
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        ctx.setLineWidth(max(1, w * 0.012))
        let step = w * 0.11
        var x = inner.minX - inner.height
        while x < inner.maxX + inner.height {
            ctx.move(to: CGPoint(x: x, y: inner.minY)); ctx.addLine(to: CGPoint(x: x + inner.height, y: inner.maxY))
            ctx.move(to: CGPoint(x: x, y: inner.maxY)); ctx.addLine(to: CGPoint(x: x + inner.height, y: inner.minY))
            x += step
        }
        ctx.strokePath()
        // Center medallion
        let medallion = CGRect(x: inner.midX - w * 0.16, y: inner.midY - w * 0.16, width: w * 0.32, height: w * 0.32)
        ctx.setFillColor(backBlue.cgColor)
        ctx.fillEllipse(in: medallion.insetBy(dx: -w * 0.02, dy: -w * 0.02))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(w * 0.015)
        ctx.strokeEllipse(in: medallion)
        drawText("♠", in: ctx, at: CGPoint(x: inner.midX, y: inner.midY), font: suitFont(size: w * 0.2), color: NSColor.white.withAlphaComponent(0.85), centered: true)
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(w * 0.012)
        ctx.addPath(innerPath); ctx.strokePath()
    }

    private func suitFont(size: CGFloat) -> NSFont {
        NSFont(name: "AppleSymbols", size: size) ?? NSFont.systemFont(ofSize: size)
    }

    private func drawText(_ text: String, in ctx: CGContext, at point: CGPoint, font: NSFont, color: NSColor, centered: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let str = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(str)
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        var origin = point
        if centered {
            origin.x -= bounds.midX
            origin.y -= bounds.midY
        }
        ctx.saveGState()
        ctx.textPosition = origin
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// Pip positions as fractions of the body rect (x from left, y from top). y > 0.5 is drawn inverted.
    static let pipLayout: [Int: [(CGFloat, CGFloat)]] = {
        let l: CGFloat = 0.22, c: CGFloat = 0.5, r: CGFloat = 0.78
        let t: CGFloat = 0.08, b: CGFloat = 0.92
        var m: [Int: [(CGFloat, CGFloat)]] = [:]
        m[2] = [(c, t), (c, b)]
        m[3] = [(c, t), (c, 0.5), (c, b)]
        m[4] = [(l, t), (r, t), (l, b), (r, b)]
        m[5] = m[4]! + [(c, 0.5)]
        m[6] = m[4]! + [(l, 0.5), (r, 0.5)]
        m[7] = m[6]! + [(c, 0.29)]
        m[8] = m[6]! + [(c, 0.29), (c, 0.71)]
        m[9] = [(l, t), (r, t), (l, 0.36), (r, 0.36), (l, 0.64), (r, 0.64), (l, b), (r, b), (c, 0.5)]
        m[10] = [(l, t), (r, t), (l, 0.36), (r, 0.36), (l, 0.64), (r, 0.64), (l, b), (r, b), (c, 0.22), (c, 0.78)]
        return m
    }()
}
