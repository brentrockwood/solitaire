import AppKit
import SolitaireCore

/// Renders the app icon: a fanned ace of spades and king of hearts on a green rounded square.
@MainActor
enum IconRenderer {
    static func render(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                                      ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
        for (name, px) in sizes {
            let img = draw(px: px)
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("icon_\(name).png"))
        }
    }

    private static func draw(px: Int) -> CGImage {
        let s = CGFloat(px)
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let inset = s * 0.05
        let bg = CGPath(roundedRect: CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset), cornerWidth: s * 0.2, cornerHeight: s * 0.2, transform: nil)
        ctx.addPath(bg); ctx.clip()
        let colors = [NSColor(srgbRed: 0.10, green: 0.50, blue: 0.26, alpha: 1).cgColor, NSColor(srgbRed: 0.03, green: 0.28, blue: 0.13, alpha: 1).cgColor] as CFArray
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
        ctx.drawRadialGradient(grad, startCenter: CGPoint(x: s * 0.4, y: s * 0.6), startRadius: 0, endCenter: CGPoint(x: s * 0.5, y: s * 0.5), endRadius: s * 0.8, options: [])
        let cardW = s * 0.42
        let scale: CGFloat = 1
        let king = CardRenderer.shared.face(Card(rank: 13, suit: .hearts, faceUp: true), width: cardW, scale: scale)
        let ace = CardRenderer.shared.face(Card(rank: 1, suit: .spades, faceUp: true), width: cardW, scale: scale)
        let cardH = cardW * CardRenderer.aspect
        for (img, angle, dx) in [(king, 0.22, -s * 0.06), (ace, -0.12, s * 0.10)] {
            ctx.saveGState()
            ctx.translateBy(x: s / 2 + dx, y: s / 2 - s * 0.02)
            ctx.rotate(by: angle)
            ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.draw(img, in: CGRect(x: -cardW / 2, y: -cardH / 2, width: cardW, height: cardH))
            ctx.restoreGState()
        }
        return ctx.makeImage()!
    }
}
