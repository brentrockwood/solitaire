import AppKit
import QuartzCore
import SolitaireCore

/// The card table. Every card is a persistent CALayer; state changes re-lay them out with
/// implicit Core Animation, so nothing runs while the table is idle.
@MainActor
final class TableView: NSView {
    let controller: GameController

    private var cardLayers: [Int: CALayer] = [:]
    private var shownFaceUp: [Int: Bool] = [:]
    private var slotLayers: [Pile: CALayer] = [:]
    private let feltLayer = CAGradientLayer()
    private let scoreLabel = NSTextField(labelWithString: "")
    private let infoLabel = NSTextField(labelWithString: "")
    private let passesLabel = NSTextField(labelWithString: "")

    private struct Metrics {
        var cardW: CGFloat = 80, cardH: CGFloat = 112, gap: CGFloat = 10, margin: CGFloat = 16
        var topY: CGFloat = 40, tableauY: CGFloat = 170
        var columnX: [CGFloat] = Array(repeating: 0, count: 7)
        var stockCol = 0, wasteCol = 1, foundationCols = [3, 4, 5, 6]
        var faceDownOffset: CGFloat = 14, faceUpOffset: CGFloat = 30
        var maxColumnHeight: CGFloat = 400
    }
    private var m = Metrics()

    private struct Drag {
        let pile: Pile
        let index: Int
        let layers: [CALayer]
        let grabOffset: CGPoint
        let start: CGPoint
        var moved = false
    }
    private var drag: Drag?
    private var pressedCard: (pile: Pile, index: Int)?
    private var pressedStock = false
    private var winAnimation: WinAnimation?

    init(controller: GameController) {
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        feltLayer.type = .radial
        feltLayer.colors = [NSColor(srgbRed: 0.09, green: 0.47, blue: 0.24, alpha: 1).cgColor,
                            NSColor(srgbRed: 0.03, green: 0.30, blue: 0.14, alpha: 1).cgColor]
        feltLayer.startPoint = CGPoint(x: 0.5, y: 0.45)
        feltLayer.endPoint = CGPoint(x: 1.1, y: 1.2)
        feltLayer.zPosition = -2  // below the empty-slot outlines (-1); zPosition, not array order, decides stacking
        layer?.addSublayer(feltLayer)

        for label in [scoreLabel, infoLabel, passesLabel] {
            label.textColor = .white
            label.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
            label.shadow = {
                let s = NSShadow(); s.shadowColor = NSColor.black.withAlphaComponent(0.5); s.shadowBlurRadius = 2; s.shadowOffset = NSSize(width: 0, height: -1); return s
            }()
            label.isSelectable = false
            addSubview(label)
        }
        scoreLabel.alignment = .center
        infoLabel.alignment = .right
        passesLabel.alignment = .left
        passesLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        passesLabel.textColor = NSColor.white.withAlphaComponent(0.8)

        for card in Card.fullDeck() {
            let l = CALayer()
            l.contentsGravity = .resize
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = 0.25
            l.shadowRadius = 2
            l.shadowOffset = CGSize(width: 0, height: 1)
            l.actions = ["contents": NSNull(), "zPosition": NSNull()]
            layer?.addSublayer(l)
            cardLayers[card.id] = l
        }
        controller.onChange = { [weak self] game in self?.apply(game, animated: true) }
        controller.onTick = { [weak self] in self?.updateLabels() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Layout

    override func layout() {
        super.layout()
        recomputeMetrics()
        if !inLiveResize { CardRenderer.shared.evict(exceptWidth: m.cardW, scale: scale) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        feltLayer.frame = bounds
        rebuildSlots()
        apply(controller.game, animated: false)
        CATransaction.commit()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        needsLayout = true
    }

    private func cancelDrag() {
        guard let d = drag else { return }
        drag = nil
        pressedCard = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in d.layers { l.shadowOpacity = 0.25; l.shadowRadius = 2 }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    private func recomputeMetrics() {
        let W = bounds.width, H = bounds.height
        var mt = Metrics()
        mt.margin = max(12, min(W, H) * 0.025)
        let hud: CGFloat = 30
        let gapRatio: CGFloat = 0.13
        var cardW = (W - 2 * mt.margin) / (7 + 6 * gapRatio)
        let availableH = H - 2 * mt.margin - hud
        cardW = min(cardW, availableH / (CardRenderer.aspect * 2.9))
        cardW = max(30, cardW.rounded())
        mt.cardW = cardW
        mt.cardH = (cardW * CardRenderer.aspect).rounded()
        mt.gap = (cardW * gapRatio).rounded()
        let totalW = 7 * cardW + 6 * mt.gap
        let x0 = ((W - totalW) / 2).rounded()
        mt.columnX = (0..<7).map { x0 + CGFloat($0) * (cardW + mt.gap) }
        mt.topY = mt.margin + hud
        mt.tableauY = mt.topY + mt.cardH + mt.gap * 1.6
        mt.faceDownOffset = (mt.cardH * 0.13).rounded()
        mt.faceUpOffset = (mt.cardH * 0.27).rounded()
        mt.maxColumnHeight = H - mt.tableauY - mt.margin
        if controller.settings.leftHanded {
            mt.stockCol = 0; mt.wasteCol = 1; mt.foundationCols = [3, 4, 5, 6]
        } else {
            mt.stockCol = 6; mt.wasteCol = 5; mt.foundationCols = [0, 1, 2, 3]
        }
        m = mt
        scoreLabel.frame = NSRect(x: 0, y: mt.margin - 4, width: W, height: 24)
        infoLabel.frame = NSRect(x: W - 320 - mt.margin, y: mt.margin - 4, width: 320, height: 24)
        passesLabel.frame = NSRect(x: mt.margin, y: mt.margin - 2, width: 300, height: 20)
    }

    private func slotRect(_ pile: Pile) -> CGRect {
        switch pile {
        case .stock: return CGRect(x: m.columnX[m.stockCol], y: m.topY, width: m.cardW, height: m.cardH)
        case .waste: return CGRect(x: m.columnX[m.wasteCol], y: m.topY, width: m.cardW, height: m.cardH)
        case .foundation(let i): return CGRect(x: m.columnX[m.foundationCols[i]], y: m.topY, width: m.cardW, height: m.cardH)
        case .tableau(let i): return CGRect(x: m.columnX[i], y: m.tableauY, width: m.cardW, height: m.cardH)
        }
    }

    private func rebuildSlots() {
        let piles: [Pile] = [.stock, .waste] + (0..<4).map { .foundation($0) } + (0..<7).map { .tableau($0) }
        for pile in piles {
            let l = slotLayers[pile] ?? {
                let l = CALayer(); l.zPosition = -1; l.contentsGravity = .resize
                layer?.insertSublayer(l, above: feltLayer); slotLayers[pile] = l; return l
            }()
            l.frame = slotRect(pile)
            l.contentsScale = scale
            let glyph: String? = { if case .foundation = pile { return "A" } else if pile == .stock { return "↻" } else { return nil } }()
            l.contents = CardRenderer.shared.emptySlot(glyph: glyph, width: m.cardW, scale: scale)
        }
    }

    /// Frame of card `index` in `pile` for the given game.
    private func frame(for pile: Pile, index: Int, in game: Game) -> CGRect {
        let base = slotRect(pile)
        switch pile {
        case .stock, .foundation:
            return base
        case .waste:
            let count = game.waste.count
            let fan = game.drawThree ? min(3, count) : 1
            let positionInFan = index - (count - fan)
            let dx = positionInFan > 0 ? CGFloat(positionInFan) * m.cardW * 0.24 : 0
            return base.offsetBy(dx: dx, dy: 0)
        case .tableau(let col):
            let cards = game.tableau[col]
            var offsets: [CGFloat] = []
            var y: CGFloat = 0
            for c in cards { offsets.append(y); y += c.faceUp ? m.faceUpOffset : m.faceDownOffset }
            let needed = y - (cards.last.map { $0.faceUp ? m.faceUpOffset : m.faceDownOffset } ?? 0) + m.cardH
            let avail = m.maxColumnHeight
            let k = needed > avail ? max(0.25, (avail - m.cardH) / max(1, needed - m.cardH)) : 1
            return base.offsetBy(dx: 0, dy: (offsets[index] * k).rounded())
        }
    }

    private func zBase(_ pile: Pile) -> CGFloat {
        switch pile {
        case .stock: return 0
        case .waste: return 100
        case .foundation(let i): return 200 + CGFloat(i) * 20
        case .tableau(let i): return 300 + CGFloat(i) * 30
        }
    }

    private func allPiles() -> [Pile] { [.stock, .waste] + (0..<4).map { .foundation($0) } + (0..<7).map { .tableau($0) } }

    func apply(_ game: Game, animated: Bool) {
        if drag != nil { cancelDrag() }  // the model changed under a drag (menu shortcut); drop it
        if winAnimation != nil {
            if game.phase == .completed { return }
            stopWinAnimation()  // a new deal arrived mid-celebration
        }
        updateLabels()
        let render = !inLiveResize
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.22 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        if !animated { CATransaction.setDisableActions(true) }
        var raised: [CALayer] = []
        for pile in allPiles() {
            let cards = game.cards(in: pile)
            for (i, card) in cards.enumerated() {
                guard let l = cardLayers[card.id] else { continue }
                let target = frame(for: pile, index: i, in: game)
                let z = zBase(pile) + CGFloat(i)
                let moved = l.frame.origin != target.origin || l.frame.size != target.size
                if moved && animated { l.zPosition = 1000 + z; raised.append(l) } else { l.zPosition = z }
                l.frame = target
                l.contentsScale = scale
                if render { setFace(l, card: card, animated: animated) }
                // Only the exposed cards of a stack cast a shadow; 24 stacked shadows make a dark halo.
                let exposed: Bool = {
                    switch pile {
                    case .tableau: return true
                    case .waste: return i >= cards.count - (game.drawThree ? min(3, cards.count) : 1)
                    default: return i == cards.count - 1
                    }
                }()
                l.shadowOpacity = exposed ? 0.25 : 0
            }
        }
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let g = self.controller.game
            let dragged = Set((self.drag?.layers ?? []).map { ObjectIdentifier($0) })
            for pile in self.allPiles() {
                for (i, card) in g.cards(in: pile).enumerated() {
                    guard let l = self.cardLayers[card.id], !dragged.contains(ObjectIdentifier(l)) else { continue }
                    l.zPosition = self.zBase(pile) + CGFloat(i)
                }
            }
            CATransaction.commit()
            _ = raised
        }
        CATransaction.commit()
        if game.phase == .completed && winAnimation == nil && animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.winAnimation == nil, self.controller.game.phase == .completed else { return }
                self.startWinAnimation()
            }
        }
    }

    private func setFace(_ l: CALayer, card: Card, animated: Bool) {
        let image = card.faceUp ? CardRenderer.shared.face(card, width: m.cardW, scale: scale) : CardRenderer.shared.back(width: m.cardW, scale: scale)
        let wasUp = shownFaceUp[card.id]
        shownFaceUp[card.id] = card.faceUp
        if animated, let wasUp, wasUp != card.faceUp {
            let flip = CAKeyframeAnimation(keyPath: "transform.scale.x")
            flip.values = [1, 0, 0, 1]
            flip.keyTimes = [0, 0.5, 0.5, 1]
            flip.duration = 0.28
            l.add(flip, forKey: "flip")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { l.contents = image }
        } else {
            l.contents = image
        }
    }

    func updateLabels() {
        let game = controller.game
        let s = controller.settings
        if let text = s.scoreText(for: game) {
            scoreLabel.stringValue = "Score: " + text
            scoreLabel.isHidden = false
        } else {
            scoreLabel.isHidden = true
        }
        infoLabel.isHidden = !s.showTimeAndMoves
        infoLabel.stringValue = "Time: \(TimeFormat.string(game.elapsed))    Moves: \(game.moves)"
        if let limit = game.passLimit {
            passesLabel.stringValue = "Pass \(min(game.stockPasses + 1, limit)) of \(limit)"
            passesLabel.isHidden = false
        } else {
            passesLabel.isHidden = true
        }
    }

    /// Renders the layer tree (felt, slots, cards) plus the labels to a PNG. Used by `--screenshot`.
    func writeSnapshot(to path: String) {
        let sc = scale
        let px = CGSize(width: bounds.width * sc, height: bounds.height * sc)
        guard let ctx = CGContext(data: nil, width: Int(px.width), height: Int(px.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: sc, y: sc)
        // Flip so the view's top-down coordinates land upright in the bitmap.
        ctx.translateBy(x: 0, y: bounds.height); ctx.scaleBy(x: 1, y: -1)
        // `render(in:)` ignores zPosition and draws sublayers in array order, so reorder them to
        // match the on-screen stacking (zPosition, then original order) before rendering.
        if let subs = layer?.sublayers {
            layer?.sublayers = subs.enumerated().sorted { ($0.element.zPosition, $0.offset) < ($1.element.zPosition, $1.offset) }.map(\.element)
        }
        layer?.render(in: ctx)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        for label in [scoreLabel, infoLabel, passesLabel] where !label.isHidden {
            label.attributedStringValue.draw(in: label.frame)
        }
        NSGraphicsContext.restoreGraphicsState()
        if let img = ctx.makeImage() {
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: - Test hooks (used by UITest.swift)

    func frameOfCard(pile: Pile, index: Int) -> CGRect { frame(for: pile, index: index, in: controller.game) }
    func slotFrame(_ pile: Pile) -> CGRect { slotRect(pile) }
    func cardLayer(for card: Card) -> CALayer? { cardLayers[card.id] }
    var columnXs: [CGFloat] { m.columnX }
    var cardSize: CGSize { CGSize(width: m.cardW, height: m.cardH) }
    var isDragging: Bool { drag != nil }
    var isWinAnimating: Bool { winAnimation != nil }

    // MARK: - Hit testing

    private func pileHit(at p: CGPoint, game: Game) -> (Pile, Int)? {
        // Tableau: topmost card wins (later cards overlap earlier ones).
        for col in 0..<7 {
            let cards = game.tableau[col]
            for i in stride(from: cards.count - 1, through: 0, by: -1) where frame(for: .tableau(col), index: i, in: game).contains(p) {
                return (.tableau(col), i)
            }
        }
        if !game.waste.isEmpty, frame(for: .waste, index: game.waste.count - 1, in: game).contains(p) { return (.waste, game.waste.count - 1) }
        for f in 0..<4 where !game.foundations[f].isEmpty && slotRect(.foundation(f)).contains(p) { return (.foundation(f), game.foundations[f].count - 1) }
        return nil
    }

    private func dropTarget(for rect: CGRect, from: Pile, index: Int, game: Game) -> Pile? {
        var best: (Pile, CGFloat)?
        var candidates: [(Pile, CGRect)] = (0..<4).map { (.foundation($0), slotRect(.foundation($0))) }
        for col in 0..<7 {
            let top = slotRect(.tableau(col))
            let last = game.tableau[col].isEmpty ? top : frame(for: .tableau(col), index: game.tableau[col].count - 1, in: game)
            candidates.append((.tableau(col), top.union(last)))
        }
        for (pile, r) in candidates where pile != from {
            let inter = r.intersection(rect)
            guard !inter.isNull, inter.width * inter.height > 0 else { continue }
            let area = inter.width * inter.height
            if game.canMove(from: from, index: index, to: pile), area > (best?.1 ?? 0) { best = (pile, area) }
        }
        return best?.0
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard winAnimation == nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        let game = controller.game
        pressedCard = nil
        pressedStock = false
        if slotRect(.stock).contains(p) { pressedStock = true; return }
        guard let (pile, index) = pileHit(at: p, game: game) else { return }
        pressedCard = (pile, index)
        guard let start = game.draggableStart(in: pile, at: index), start == index else { return }
        let cards = Array(game.cards(in: pile)[index...])
        let layers = cards.compactMap { cardLayers[$0.id] }
        let first = frame(for: pile, index: index, in: game)
        drag = Drag(pile: pile, index: index, layers: layers, grabOffset: CGPoint(x: p.x - first.origin.x, y: p.y - first.origin.y), start: p)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, l) in layers.enumerated() { l.zPosition = 2000 + CGFloat(i); l.shadowOpacity = 0.45; l.shadowRadius = 6 }
        CATransaction.commit()
    }

    override func mouseDragged(with event: NSEvent) {
        guard var d = drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !d.moved, hypot(p.x - d.start.x, p.y - d.start.y) < 4 { return }
        d.moved = true
        drag = d
        let game = controller.game
        let origin = CGPoint(x: p.x - d.grabOffset.x, y: p.y - d.grabOffset.y)
        let base = frame(for: d.pile, index: d.index, in: game)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, l) in d.layers.enumerated() {
            let f = frame(for: d.pile, index: d.index + i, in: game)
            l.frame = CGRect(x: origin.x, y: origin.y + (f.origin.y - base.origin.y), width: f.width, height: f.height)
        }
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        guard winAnimation == nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        if pressedStock {
            pressedStock = false
            if slotRect(.stock).contains(p) { controller.draw() }
            return
        }
        let pressed = pressedCard  // cancelDrag() clears it, so read it first
        pressedCard = nil
        if let d = drag {
            cancelDrag()
            if d.moved {
                let rect = d.layers[0].frame
                if let target = dropTarget(for: rect, from: d.pile, index: d.index, game: controller.game),
                   controller.move(from: d.pile, index: d.index, to: target) {
                    return
                }
                apply(controller.game, animated: true)  // snap back
                return
            }
        }
        if let (pile, index) = pressed {
            let game = controller.game
            if let target = game.autoMoveTarget(from: pile, index: index) {
                controller.move(from: pile, index: index, to: target)
            } else {
                apply(game, animated: true)
            }
        }
    }

    // MARK: - Win animation

    /// Cards leap off the foundations and bounce along the bottom edge, then the table resets.
    private final class WinAnimation {
        struct Body { let layer: CALayer; var p: CGPoint; var v: CGPoint; var launched = false }
        var bodies: [Body] = []
        var link: CADisplayLink?
        var launchedCount = 0
        var lastTime: CFTimeInterval = 0
        var launchAccumulator: Double = 0
    }

    private func startWinAnimation() {
        let game = controller.game
        let anim = WinAnimation()
        var order: [CALayer] = []
        for i in stride(from: 12, through: 0, by: -1) {
            for f in 0..<4 where game.foundations[f].count > i { if let l = cardLayers[game.foundations[f][i].id] { order.append(l) } }
        }
        anim.bodies = order.map { WinAnimation.Body(layer: $0, p: $0.frame.origin, v: .zero) }
        winAnimation = anim
        let link = displayLink(target: self, selector: #selector(stepWin(_:)))
        anim.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func stepWin(_ link: CADisplayLink) {
        guard let anim = winAnimation else { link.invalidate(); return }
        let now = link.timestamp
        let dt = anim.lastTime == 0 ? 1.0 / 60 : min(now - anim.lastTime, 1.0 / 30)
        anim.lastTime = now
        anim.launchAccumulator += dt
        let floorY = bounds.height - m.cardH
        let gravity: CGFloat = 2600 * (m.cardH / 112)
        while anim.launchedCount < anim.bodies.count && anim.launchAccumulator > 0.09 {
            anim.launchAccumulator -= 0.09
            var b = anim.bodies[anim.launchedCount]
            b.launched = true
            b.v = CGPoint(x: CGFloat.random(in: 180...420) * (Bool.random() ? 1 : -1) * (m.cardW / 80), y: CGFloat.random(in: -700 ... -200) * (m.cardH / 112))
            b.layer.zPosition = 3000 + CGFloat(anim.launchedCount)
            anim.bodies[anim.launchedCount] = b
            anim.launchedCount += 1
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        var active = 0
        for i in anim.bodies.indices where anim.bodies[i].launched {
            var b = anim.bodies[i]
            b.v.y += gravity * dt
            b.p.x += b.v.x * dt
            b.p.y += b.v.y * dt
            if b.p.y > floorY { b.p.y = floorY; b.v.y = -b.v.y * 0.72 }
            if b.p.x > -m.cardW * 2 && b.p.x < bounds.width + m.cardW * 2 { active += 1 }
            b.layer.frame.origin = b.p
            anim.bodies[i] = b
        }
        CATransaction.commit()
        if anim.launchedCount == anim.bodies.count && active == 0 {
            stopWinAnimation()
            apply(controller.game, animated: false)
            if controller.game.phase == .completed { controller.onWin?() }
        }
    }

    private func stopWinAnimation() {
        winAnimation?.link?.invalidate()
        winAnimation = nil
    }
}
