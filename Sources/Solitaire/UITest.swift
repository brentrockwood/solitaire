import AppKit
import QuartzCore
import SolitaireCore

/// Hidden `--uitest <report.txt> <screenshot-dir>` mode. Drives the real TableView with
/// synthesized NSEvents from the main run loop, writes PASS/FAIL lines to the report after
/// every check, snapshots the layer tree after each major step, and terminates the app.
/// Nothing here runs on a normal launch.
@MainActor
final class UITest {
    private let reportPath: String
    private let shotDir: String
    private var controller: GameController!
    private var table: TableView!
    private var window: NSWindow!

    private var lines: [String] = []
    private var queue: [(delay: TimeInterval, body: () -> Void)] = []
    private var shotIndex = 0
    private var eventNumber = 0
    private var failures = 0

    init(reportPath: String, screenshotDir: String) {
        self.reportPath = reportPath
        self.shotDir = screenshotDir
    }

    func start(controller: GameController, table: TableView, window: NSWindow) {
        self.controller = controller
        self.table = table
        self.window = window
        try? FileManager.default.createDirectory(atPath: shotDir, withIntermediateDirectories: true)
        controller.persists = false  // never clobber the user's saved game / settings
        controller.settings.soundEnabled = false
        controller.settings.scoring = .standard
        controller.settings.drawThree = false
        controller.settings.leftHanded = true
        controller.settings.showTimeAndMoves = true
        lines.append("uitest started \(Date()) view \(table.bounds.size) scale \(window.backingScaleFactor)")
        buildScript()
        next()
    }

    // MARK: - Runner

    /// While a step body runs, steps it enqueues go right after it (so a drag's sub-steps run next).
    private var insertIndex: Int?

    private func step(_ delay: TimeInterval = 0.4, _ body: @escaping () -> Void) {
        if let i = insertIndex { queue.insert((delay, body), at: i); insertIndex = i + 1 } else { queue.append((delay, body)) }
    }

    private func next() {
        guard !queue.isEmpty else { return }
        let s = queue.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + s.delay) { [self] in
            insertIndex = 0
            s.body()
            insertIndex = nil
            next()
        }
    }

    /// Polls `cond` every `every` seconds until true or `timeout` elapses, then runs `then(satisfied)`.
    private func poll(every: TimeInterval = 0.25, timeout: TimeInterval, until cond: @escaping () -> Bool, then: @escaping (Bool) -> Void) {
        step(0) { [self] in
            let deadline = Date().addingTimeInterval(timeout)
            var attempt: (() -> Void)!
            attempt = { [self] in
                if cond() { then(true) }
                else if Date() > deadline { then(false) }
                else { step(every, attempt) }
            }
            step(every, attempt)
        }
    }

    // MARK: - Report

    private func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String) {
        if !ok { failures += 1 }
        lines.append("\(ok ? "PASS" : "FAIL") \(name): \(detail())")
        flush()
    }

    private func note(_ s: String) { lines.append("     " + s); flush() }

    private func flush() {
        try? (lines.joined(separator: "\n") + "\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
    }

    private func shot(_ name: String) {
        shotIndex += 1
        let path = shotDir + "/" + String(format: "%02d-%@.png", shotIndex, name)
        table.writeSnapshot(to: path)
        note("screenshot \(path)")
    }

    /// Renders the attached sheet's content view (an NSAlert) to a PNG via cacheDisplay, which needs no screen-recording permission.
    private func shotSheet(_ name: String) {
        guard let sheet = window.attachedSheet, let v = sheet.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else {
            note("no sheet to snapshot"); return
        }
        v.cacheDisplay(in: v.bounds, to: rep)
        shotIndex += 1
        let path = shotDir + "/" + String(format: "%02d-%@.png", shotIndex, name)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        note("sheet screenshot \(path) size \(v.bounds.size)")
        func dump(_ view: NSView, _ depth: Int) {
            let extra = (view as? NSTextField).map { " text=\"\($0.stringValue.replacingOccurrences(of: "\n", with: "|"))\"" } ?? ((view as? NSButton).map { " title=\"\($0.title)\"" } ?? ((view as? NSImageView).map { " image=\(String(describing: $0.image?.size))" } ?? ""))
            note(String(repeating: "  ", count: depth) + "\(type(of: view)) \(fmt(view.frame)) hidden=\(view.isHidden)\(extra)")
            for sub in view.subviews { dump(sub, depth + 1) }
        }
        dump(v, 0)
    }

    /// D. The win sheet's 🎉 label: present, inside the content view, in its top-right corner, clear of the title.
    private func checkWinSheetEmoji() {
        guard let sheet = window.attachedSheet, let content = sheet.contentView else { check("D1 win sheet content view", false, "no sheet attached"); return }
        func find(_ v: NSView, _ pred: (NSTextField) -> Bool) -> NSTextField? {
            if let t = v as? NSTextField, pred(t) { return t }
            for s in v.subviews { if let t = find(s, pred) { return t } }
            return nil
        }
        let party = find(content) { $0.stringValue == "🎉" }
        let title = find(content) { $0.stringValue == "You won!" }
        check("D1 🎉 label is a text field in the sheet", party != nil && title != nil, "party=\(party.map { fmt($0.frame) } ?? "missing") title=\(title.map { fmt($0.frame) } ?? "missing")")
        guard let party, let title else { return }
        let b = content.bounds
        let pf = content.convert(party.frame, from: party.superview)
        let tf = content.convert(title.frame, from: title.superview)
        let where_ = "party \(fmt(pf)) title \(fmt(tf)) bounds \(fmt(b)) flipped=\(content.isFlipped) directChild=\(party.superview === content)"
        check("D2 🎉 inside the content view", b.contains(pf) && !party.isHidden, where_)
        check("D3 🎉 in the top-right corner", pf.maxX >= b.maxX - 20 && pf.maxY >= b.maxY - 20, where_)
        check("D4 🎉 clear of the title", pf.minX > tf.minX + 100, where_)
    }

    // MARK: - Events

    private func event(_ type: NSEvent.EventType, at viewPoint: CGPoint, clickCount: Int = 1) -> NSEvent {
        let wp = table.convert(viewPoint, to: nil)  // view is flipped; AppKit converts
        eventNumber += 1
        return NSEvent.mouseEvent(with: type, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: clickCount, pressure: 1)!
    }

    private func press(_ p: CGPoint, clickCount: Int = 1) { table.mouseDown(with: event(.leftMouseDown, at: p, clickCount: clickCount)) }
    private func dragTo(_ p: CGPoint) { table.mouseDragged(with: event(.leftMouseDragged, at: p)) }
    private func release(_ p: CGPoint, clickCount: Int = 1) { table.mouseUp(with: event(.leftMouseUp, at: p, clickCount: clickCount)) }
    private func click(_ p: CGPoint) { press(p); release(p) }
    /// What AppKit delivers for a double-click: a complete single click, then a down/up pair with clickCount 2.
    private func doubleClick(_ p: CGPoint) { press(p); release(p); press(p, clickCount: 2); release(p, clickCount: 2) }

    /// Queues a full drag: down, four intermediate moves, up.
    private func drag(from a: CGPoint, to b: CGPoint, card: Card) {
        step { [self] in press(a); note("  press \(a) isDragging=\(table.isDragging) layer \(fmt(layerFrames(card).model))") }
        for k in 1...4 {
            let t = CGFloat(k) / 4
            step(0.12) { [self] in
                let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                dragTo(p)
                note("  drag \(p) isDragging=\(table.isDragging) layer \(fmt(layerFrames(card).model))")
            }
        }
        step(0.12) { [self] in release(b); note("  release \(b) layer \(fmt(layerFrames(card).model))") }
    }

    // MARK: - Helpers

    private var game: Game { controller.game }
    /// Why a sweep might be suppressed: the shimmer guard needs the window server to report the window visible.
    private func windowState() -> String {
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"].map { "\($0)" } ?? "nil"
        return "occlusion=\(window.occlusionState.rawValue) visible=\(window.occlusionState.contains(.visible)) isVisible=\(window.isVisible) key=\(window.isKeyWindow) active=\(NSApp.isActive) onActiveSpace=\(window.isOnActiveSpace) screen=\(window.screen.map { fmt($0.frame) } ?? "nil") frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil") screenLocked=\(locked)"
    }
    private func centre(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
    private func approx(_ a: CGRect, _ b: CGRect, tol: CGFloat = 1) -> Bool {
        abs(a.minX - b.minX) < tol && abs(a.minY - b.minY) < tol && abs(a.width - b.width) < tol && abs(a.height - b.height) < tol
    }
    private func fmt(_ r: CGRect) -> String { String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height) }
    /// Model frame and on-screen (presentation) frame of a card's layer.
    private func layerFrames(_ card: Card) -> (model: CGRect, shown: CGRect) {
        let l = table.cardLayer(for: card)!
        return (l.frame, l.presentation()?.frame ?? l.frame)
    }
    private func layerAt(_ card: Card, _ expected: CGRect) -> (Bool, String) {
        let f = layerFrames(card)
        let ok = approx(f.model, expected) && approx(f.shown, expected)
        return (ok, "\(card) layer model \(fmt(f.model)) shown \(fmt(f.shown)) expected \(fmt(expected))")
    }
    /// Pile contents, score and moves; excludes the clock so comparisons are stable.
    private func signature(_ g: Game) -> String {
        "S\(g.stock.map(\.description)) W\(g.waste.map(\.description)) F\(g.foundations.map { $0.map(\.description) }) T\(g.tableau.map { $0.map(\.description) }) score=\(g.score) moves=\(g.moves)"
    }

    /// Builds a game with an explicit layout via Codable; every card not placed goes face down into the stock.
    private func makeGame(scoring: ScoringMode = .standard, drawThree: Bool = false,
                          waste: [Card] = [], foundations: [[Card]] = [[], [], [], []], tableau: [[Card]]) -> Game {
        let g = Game(seed: 1, scoring: scoring, drawThree: drawThree)
        var json = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(g)) as! [String: Any]
        func enc(_ c: Card) -> [String: Any] { ["rank": c.rank, "suit": c.suit.rawValue, "faceUp": c.faceUp] }
        var t = tableau; while t.count < 7 { t.append([]) }
        let placed = Set((waste + foundations.flatMap { $0 } + t.flatMap { $0 }).map(\.id))
        let stock = Card.fullDeck().filter { !placed.contains($0.id) }
        json["stock"] = stock.map(enc); json["waste"] = waste.map(enc)
        json["foundations"] = foundations.map { $0.map(enc) }
        json["tableau"] = t.map { $0.map(enc) }
        return try! JSONDecoder().decode(Game.self, from: JSONSerialization.data(withJSONObject: json))
    }
    private func c(_ r: Int, _ s: Suit, up: Bool = true) -> Card { Card(rank: r, suit: s, faceUp: up) }

    /// A tableau→tableau move in `g`, preferring one that reveals a face-down card.
    private func tableauMove(in g: Game) -> (src: Int, idx: Int, dst: Int)? {
        var any: (Int, Int, Int)?
        for src in 0..<7 {
            for idx in 0..<g.tableau[src].count {
                for dst in 0..<7 where !g.tableau[dst].isEmpty && g.canMove(from: .tableau(src), index: idx, to: .tableau(dst)) {
                    if idx > 0 && !g.tableau[src][idx - 1].faceUp { return (src, idx, dst) }
                    if any == nil { any = (src, idx, dst) }
                }
            }
        }
        return any
    }

    /// First seed whose fresh deal has a revealing tableau→tableau move.
    private func seedWithTableauMove() -> UInt64 {
        for seed in UInt64(1)...5000 {
            let g = Game(seed: seed, scoring: .standard, drawThree: false)
            if let mv = tableauMove(in: g), mv.idx > 0 { return seed }
        }
        return 1
    }

    // MARK: - Script

    private func buildScript() {
        let seed = seedWithTableauMove()
        step(0.6) { [self] in
            controller.load(Game(seed: seed, scoring: .standard, drawThree: false))
            note("loaded seed \(seed); \(windowState())")
        }
        step { [self] in shot("loaded") }

        // 1. Stock clicks
        step { [self] in click(centre(table.slotFrame(.stock))) }
        step { [self] in
            check("1a stock click draws one", game.waste.count == 1 && game.stock.count == 23, "waste=\(game.waste.map(\.description)) stock=\(game.stock.count)")
            click(centre(table.slotFrame(.stock)))
        }
        step { [self] in click(centre(table.slotFrame(.stock))) }
        step { [self] in
            check("1b three stock clicks → waste 3", game.waste.count == 3, "waste=\(game.waste.map(\.description)) moves=\(game.moves)")
            if let top = game.waste.last {
                let (ok, d) = layerAt(top, table.frameOfCard(pile: .waste, index: 2))
                check("1c top waste card layer at waste slot", ok, d)
            }
            shot("drew-three")
        }

        // 2. Legal tableau→tableau drag
        var before = game
        var moved: (card: Card, src: Int, idx: Int, dst: Int, expectedDelta: Int, runCount: Int)?
        step { [self] in
            before = game
            guard let mv = tableauMove(in: game) else { check("2 find tableau move", false, "no legal tableau→tableau move in seed \(seed)"); return }
            let card = game.tableau[mv.src][mv.idx]
            let reveal = mv.idx > 0 && !game.tableau[mv.src][mv.idx - 1].faceUp
            moved = (card, mv.src, mv.idx, mv.dst, reveal ? 5 : 0, game.tableau[mv.src].count - mv.idx)
            let from = centre(table.frameOfCard(pile: .tableau(mv.src), index: mv.idx))
            let dstCount = game.tableau[mv.dst].count
            let to = centre(dstCount == 0 ? table.slotFrame(.tableau(mv.dst)) : table.frameOfCard(pile: .tableau(mv.dst), index: dstCount - 1))
            note("2 dragging \(card) from T\(mv.src)[\(mv.idx)] at \(from) to T\(mv.dst) at \(to); reveal=\(reveal)")
            drag(from: from, to: to, card: card)
        }
        step(0.6) { [self] in
            guard let mv = moved else { return }
            let g = game
            let landed = g.tableau[mv.dst].count == before.tableau[mv.dst].count + mv.runCount && g.tableau[mv.dst][before.tableau[mv.dst].count].id == mv.card.id
            check("2a drag moved the run in the model", landed, "T\(mv.dst)=\(g.tableau[mv.dst].map(\.description)) T\(mv.src)=\(g.tableau[mv.src].map(\.description))")
            check("2b score delta", g.score == before.score + mv.expectedDelta, "score \(before.score) → \(g.score), expected +\(mv.expectedDelta)")
            if landed && mv.expectedDelta > 0 {
                check("2c revealed card is face up", g.tableau[mv.src].last?.faceUp == true, "\(g.tableau[mv.src].last.map(String.init(describing:)) ?? "empty")")
            }
            if landed {
                let (ok, d) = layerAt(mv.card, table.frameOfCard(pile: .tableau(mv.dst), index: before.tableau[mv.dst].count))
                check("2d moved card layer at new position", ok, d)
            }
            check("2e drag state cleared", !table.isDragging, "isDragging=\(table.isDragging)")
            shot("after-tableau-drag")
        }

        // 3. Illegal drag onto empty felt below a short column → snap back
        var illegal: (card: Card, frame: CGRect, sig: String)?
        step { [self] in
            let g = game
            let H = table.bounds.height, cardH = table.cardSize.height
            // Column whose cards end highest: the felt below it is empty.
            let colBottom: (Int) -> CGFloat = { [self] c in g.tableau[c].isEmpty ? table.slotFrame(.tableau(c)).maxY : table.frameOfCard(pile: .tableau(c), index: g.tableau[c].count - 1).maxY }
            let dropCol = (0..<7).min { colBottom($0) < colBottom($1) }!
            guard let src = (0..<7).filter({ $0 != dropCol && !g.tableau[$0].isEmpty }).max(by: { g.tableau[$0].count < g.tableau[$1].count }) else { return }
            let idx = g.tableau[src].count - 1
            let card = g.tableau[src][idx]
            let frame = table.frameOfCard(pile: .tableau(src), index: idx)
            let to = CGPoint(x: table.slotFrame(.tableau(dropCol)).midX, y: H - cardH / 2)
            let clear = colBottom(dropCol) < H - cardH
            check("3 drop spot is empty felt", clear, "column \(dropCol) bottom \(colBottom(dropCol)) vs drop top \(H - cardH)")
            illegal = (card, frame, signature(g))
            note("3 dragging \(card) from T\(src)[\(idx)] \(fmt(frame)) to felt at \(to)")
            drag(from: centre(frame), to: to, card: card)
        }
        step(0.6) { [self] in
            guard let il = illegal else { return }
            check("3a model unchanged after illegal drop", signature(game) == il.sig, signature(game) == il.sig ? "unchanged" : "changed to \(signature(game))")
            let (ok, d) = layerAt(il.card, il.frame)
            check("3b layer snapped back", ok, d)
            shot("after-illegal-drag")
        }

        // 4. Single click sends an ace to the foundation
        let ace = c(1, .hearts)
        step { [self] in
            controller.load(makeGame(tableau: [[ace], [c(9, .clubs, up: false), c(8, .hearts)], [c(13, .spades, up: false), c(12, .hearts, up: false), c(5, .diamonds)]]))
        }
        step { [self] in
            note("4 clicking \(ace) at \(centre(table.frameOfCard(pile: .tableau(0), index: 0)))")
            click(centre(table.frameOfCard(pile: .tableau(0), index: 0)))
        }
        step(0.6) { [self] in
            let g = game
            let f = (0..<4).first { g.foundations[$0].last?.id == ace.id }
            check("4a click moved ace to a foundation", f != nil && g.tableau[0].isEmpty, "foundations=\(g.foundations.map { $0.map(\.description) }) T0=\(g.tableau[0])")
            check("4b score +10", g.score == 10, "score=\(g.score)")
            if let f {
                let (ok, d) = layerAt(ace, table.slotFrame(.foundation(f)))
                check("4c ace layer on foundation \(f)", ok, d)
            }
            shot("after-click-to-foundation")
        }

        // 5. Undo
        step { [self] in controller.undo() }
        step(0.6) { [self] in
            let g = game
            check("5a undo restored model", g.tableau[0].map(\.id) == [ace.id] && g.foundations.allSatisfy(\.isEmpty) && g.score == 0, "T0=\(g.tableau[0]) score=\(g.score) moves=\(g.moves)")
            let (ok, d) = layerAt(ace, table.frameOfCard(pile: .tableau(0), index: 0))
            check("5b ace layer back on tableau", ok, d)
            shot("after-undo")
        }

        // 7. Right-handed layout (run before the win so the window is still clean)
        step { [self] in
            let xs = table.columnXs
            check("7a left-handed baseline: stock at column 0", abs(table.slotFrame(.stock).minX - xs[0]) < 1, "stock x \(table.slotFrame(.stock).minX) cols \(xs)")
            controller.settings.leftHanded = false
            table.needsLayout = true
            table.layoutSubtreeIfNeeded()
        }
        step { [self] in
            let xs = table.columnXs
            let stockOK = abs(table.slotFrame(.stock).minX - xs[6]) < 1
            let wasteOK = abs(table.slotFrame(.waste).minX - xs[5]) < 1
            let fOK = (0..<4).allSatisfy { abs(table.slotFrame(.foundation($0)).minX - xs[$0]) < 1 }
            check("7b right-handed: stock rightmost, waste next, foundations in 4 left columns", stockOK && wasteOK && fOK,
                  "stock \(table.slotFrame(.stock).minX) waste \(table.slotFrame(.waste).minX) foundations \((0..<4).map { table.slotFrame(.foundation($0)).minX }) cols \(xs)")
            if let top = game.stock.last {
                let (ok, d) = layerAt(top, table.slotFrame(.stock))
                check("7c stock card layer followed the slot", ok, d)
            }
            shot("right-handed")
            controller.settings.leftHanded = true
            table.needsLayout = true
            table.layoutSubtreeIfNeeded()
        }

        // 8. Draw three
        step { [self] in controller.load(Game(seed: 7, scoring: .standard, drawThree: true)) }
        step { [self] in click(centre(table.slotFrame(.stock))) }
        var wasteTarget: Pile?
        var wasteTop: Card?
        step(0.6) { [self] in
            let g = game
            check("8a draw-three stock click → waste 3", g.waste.count == 3, "waste=\(g.waste.map(\.description))")
            guard g.waste.count == 3 else { return }
            let xs = g.waste.map { table.cardLayer(for: $0)!.frame.minX }
            let expected = (0..<3).map { table.frameOfCard(pile: .waste, index: $0) }
            let fanned = xs[0] < xs[1] && xs[1] < xs[2] && zip(g.waste, expected).allSatisfy { approx(table.cardLayer(for: $0)!.frame, $1) }
            check("8b waste layers fanned with distinct x", fanned, "x=\(xs) expected=\(expected.map(fmt))")
            check("8c only top waste card draggable", g.draggableStart(in: .waste, at: 1) == nil && g.draggableStart(in: .waste, at: 2) == 2,
                  "draggableStart(1)=\(String(describing: g.draggableStart(in: .waste, at: 1))) (2)=\(String(describing: g.draggableStart(in: .waste, at: 2)))")
            wasteTarget = g.autoMoveTarget(from: .waste, index: 2)
            wasteTop = g.waste.last
            shot("draw-three")
            // Press on the visible strip of the middle card: must not start a drag.
            let mid = table.frameOfCard(pile: .waste, index: 1)
            let p = CGPoint(x: mid.minX + table.cardSize.width * 0.1, y: mid.midY)
            press(p)
            check("8d press on buried waste card does not start a drag", !table.isDragging, "isDragging=\(table.isDragging) at \(p)")
            release(p)
        }
        step { [self] in
            let g = game
            check("8e buried waste click left model unchanged", g.waste.count == 3, "waste=\(g.waste.map(\.description))")
            let p = centre(table.frameOfCard(pile: .waste, index: 2))
            press(p)
            check("8f press on top waste card starts a drag", table.isDragging, "isDragging=\(table.isDragging) at \(p)")
            release(p)
        }
        step(0.6) { [self] in
            let g = game
            if let t = wasteTarget {
                check("8g top waste click auto-moved to \(t)", g.waste.count == 2 && g.cards(in: t).last?.id == wasteTop?.id, "waste=\(g.waste.map(\.description)) target=\(g.cards(in: t).map(\.description))")
            } else {
                check("8g top waste click with no target leaves waste", g.waste.count == 3 && !table.isDragging, "waste=\(g.waste.map(\.description))")
            }
            shot("after-waste-click")
        }

        // Fixtures for A–C: three cards short of a win. Column 0 is K♠ under Q♥, column 1 is K♥.
        // Q♥ can go straight to the hearts foundation (A–J), which reveals K♠; K♥ has no single-click target.
        let nearDone = [(1...13).map { c($0, .clubs) }, (1...13).map { c($0, .diamonds) }, (1...11).map { c($0, .hearts) }, (1...12).map { c($0, .spades) }]
        let hiddenKing = { [self] in makeGame(foundations: nearDone, tableau: [[c(13, .spades, up: false), c(12, .hearts)], [c(13, .hearts)]]) }
        let allFaceUp = { [self] in makeGame(foundations: nearDone, tableau: [[c(13, .spades), c(12, .hearts)], [c(13, .hearts)]]) }

        // A. Autocomplete shimmer hint
        step { [self] in controller.load(hiddenKing()) }
        step { [self] in
            check("A1 hint inactive while a tableau card is face down", !controller.canAutocomplete && !table.autocompleteHintActive && !table.isShimmering,
                  "canAutocomplete=\(controller.canAutocomplete) hintActive=\(table.autocompleteHintActive) shimmering=\(table.isShimmering)")
            let p = centre(table.frameOfCard(pile: .tableau(0), index: 1))
            note("A clicking Q♥ at \(p) to reveal K♠; \(windowState())")
            click(p)
        }
        step(0.3) { [self] in
            check("A2 revealing the last card makes the game finishable", controller.canAutocomplete && game.tableau[0].last?.faceUp == true,
                  "canAutocomplete=\(controller.canAutocomplete) T0=\(game.tableau[0]) F2=\(game.foundations[2].count)")
            // shimmer() only sweeps when the window server reports the window visible (not with a locked
            // screen, say). Assert that contract: the band is showing iff the window is visible.
            let visible = window.occlusionState.contains(.visible)
            check("A3 shimmer band visible within 0.3 s (iff the window is visible)", table.isShimmering == visible,
                  "isShimmering=\(table.isShimmering); \(visible ? "sweep ran" : "WINDOW NOT VISIBLE, sweep suppressed by the guard, not exercised"); \(windowState())")
            check("A4 hint timer started", table.autocompleteHintActive, "hintActive=\(table.autocompleteHintActive)")
            shot("shimmer")
        }
        step(0.9) { [self] in  // ~1.2 s after the click; the 0.9 s sweep has ended
            check("A5 shimmer band hidden after the sweep", !table.isShimmering, "isShimmering=\(table.isShimmering)")
            check("A6 hint timer still active between sweeps", table.autocompleteHintActive, "hintActive=\(table.autocompleteHintActive)")
            controller.undo()
        }
        step { [self] in
            check("A7 undo stops the hint timer", !controller.canAutocomplete && !table.autocompleteHintActive,
                  "canAutocomplete=\(controller.canAutocomplete) hintActive=\(table.autocompleteHintActive) T0=\(game.tableau[0])")
            click(centre(table.frameOfCard(pile: .tableau(0), index: 1)))  // finishable again
        }
        step(0.3) { [self] in
            let visible = window.occlusionState.contains(.visible)
            check("A8 hint restarts when the game becomes finishable again", controller.canAutocomplete && table.autocompleteHintActive && table.isShimmering == visible,
                  "canAutocomplete=\(controller.canAutocomplete) hintActive=\(table.autocompleteHintActive) shimmering=\(table.isShimmering) windowVisible=\(visible)")
            controller.load(hiddenKing())
        }
        step { [self] in
            check("A9 loading an unfinishable game stops the hint timer", !table.autocompleteHintActive, "hintActive=\(table.autocompleteHintActive) canAutocomplete=\(controller.canAutocomplete)")
        }

        // B. Double-click autocompletes
        var sigB = ""
        step { [self] in
            sigB = signature(game)
            let p = centre(table.frameOfCard(pile: .tableau(1), index: 0))  // K♥
            check("B1 setup: unfinishable, K♥ has no single-click target", !controller.canAutocomplete && game.autoMoveTarget(from: .tableau(1), index: 0) == nil,
                  "canAutocomplete=\(controller.canAutocomplete) target=\(String(describing: game.autoMoveTarget(from: .tableau(1), index: 0)))")
            doubleClick(p)
            check("B2 double-click when unfinishable starts no autocomplete", !controller.canAutocomplete && game.phase == .playing, "canAutocomplete=\(controller.canAutocomplete) phase=\(game.phase)")
        }
        step(0.5) { [self] in
            check("B3 model unchanged after that double-click", signature(game) == sigB && !table.isDragging, signature(game) == sigB ? "unchanged" : "changed to \(signature(game))")
            controller.load(allFaceUp())
        }
        step { [self] in
            // The exposed strip of K♠ (column 0, index 0) lies above Q♥'s frame, outside the bottom-card slack.
            let f0 = table.frameOfCard(pile: .tableau(0), index: 0), f1 = table.frameOfCard(pile: .tableau(0), index: 1)
            let p = CGPoint(x: f0.midX, y: (f0.minY + f1.minY) / 2)
            sigB = signature(game)
            check("B4 setup: finishable; point \(p) is on K♠ above Q♥ \(fmt(f1)); K♠ run has no single-click target",
                  controller.canAutocomplete && f0.contains(p) && !f1.contains(p) && game.autoMoveTarget(from: .tableau(0), index: 0) == nil,
                  "canAutocomplete=\(controller.canAutocomplete) target=\(String(describing: game.autoMoveTarget(from: .tableau(0), index: 0)))")
            doubleClick(p)
            check("B5 double-click on a non-bottom card starts no autocomplete", controller.canAutocomplete, "canAutocomplete=\(controller.canAutocomplete) (false while an autocomplete task runs)")
        }
        step(0.6) { [self] in
            check("B6 model unchanged after the non-bottom double-click", signature(game) == sigB && game.phase == .playing, signature(game) == sigB ? "unchanged" : "changed to \(signature(game))")
            let p = centre(table.frameOfCard(pile: .tableau(0), index: 1))  // Q♥, bottom of column 0
            check("B7 finishable before the double-click", controller.canAutocomplete, "canAutocomplete=\(controller.canAutocomplete)")
            doubleClick(p)
            note("B double-clicked Q♥ at \(p): T0=\(game.tableau[0]) F2=\(game.foundations[2].count) canAutocomplete=\(controller.canAutocomplete) (false once the task is queued)")
        }
        poll(timeout: 15, until: { [self] in game.phase == .completed }) { [self] done in
            check("B8 double-click on a bottom card autocompleted the game", done && game.isWon,
                  "phase=\(game.phase) foundations=\(game.foundations.map(\.count)) moves=\(game.moves)")
            shot("after-double-click-autocomplete")
        }

        // C. A click skips the win animation (the win sheet then appears; D checks its 🎉 label)
        let kingC = c(13, .spades)
        step { [self] in
            controller.load(makeGame(foundations: [(1...13).map { c($0, .clubs) }, (1...13).map { c($0, .diamonds) }, (1...13).map { c($0, .hearts) }, (1...12).map { c($0, .spades) }],
                                     tableau: [[kingC]]))
        }
        step { [self] in click(centre(table.frameOfCard(pile: .tableau(0), index: 0))) }
        step(1.5) { [self] in
            check("C1 win animation running 1.5 s after the winning click", game.phase == .completed && table.isWinAnimating, "phase=\(game.phase) isWinAnimating=\(table.isWinAnimating)")
            let p = CGPoint(x: table.bounds.midX, y: table.bounds.height - 12)  // bare felt below the tableau
            click(p)
            check("C2 felt click stopped the win animation at once", !table.isWinAnimating, "isWinAnimating=\(table.isWinAnimating) after click at \(p)")
            var wrong: [String] = []
            for f in 0..<4 { for card in game.foundations[f] where !approx(table.cardLayer(for: card)!.frame, table.slotFrame(.foundation(f))) { wrong.append("\(card)@\(fmt(table.cardLayer(for: card)!.frame))") } }
            check("C3 all cards back on foundations right after the click", wrong.isEmpty, wrong.isEmpty ? "52 cards on their foundation slots" : wrong.joined(separator: " "))
            shot("after-skip-click")
        }
        step(1.5) { [self] in
            check("C4 win animation did not restart", !table.isWinAnimating, "isWinAnimating=\(table.isWinAnimating)")
            check("C5 win sheet shown after the skip", window.attachedSheet != nil, "sheet=\(String(describing: window.attachedSheet?.title))")
            shotSheet("skip-win-sheet")
            checkWinSheetEmoji()
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }  // "Close"
        }
        step { [self] in
            check("C6 sheet dismissed", window.attachedSheet == nil, "sheet=\(String(describing: window.attachedSheet)) phase=\(game.phase)")
        }

        // 6. Win animation
        let king = c(13, .spades)
        step { [self] in
            controller.load(makeGame(foundations: [(1...13).map { c($0, .clubs) }, (1...13).map { c($0, .diamonds) }, (1...13).map { c($0, .hearts) }, (1...12).map { c($0, .spades) }],
                                     tableau: [[king]]))
        }
        var winClickTime = Date()
        step { [self] in
            shot("near-won")
            winClickTime = Date()
            click(centre(table.frameOfCard(pile: .tableau(0), index: 0)))
        }
        step { [self] in
            check("6a click completed the game", game.phase == .completed && game.foundations[3].count == 13, "phase=\(game.phase) F3=\(game.foundations[3].count) score=\(game.score)")
        }
        step(1.1) { [self] in  // ~1.5 s after the click
            check("6b win animation running", table.isWinAnimating, "isWinAnimating=\(table.isWinAnimating)")
            var off = 0
            for f in 0..<4 { for card in game.foundations[f] where !approx(table.cardLayer(for: card)!.frame, table.slotFrame(.foundation(f))) { off += 1 } }
            check("6c cards in flight", off > 0, "\(off) card layers away from their foundation")
            shot("win-in-flight")
        }
        poll(timeout: 25, until: { [self] in !table.isWinAnimating }) { [self] done in
            check("6d win animation ended", done, String(format: done ? "ended %.1f s after the click" : "still running %.1f s after the click", Date().timeIntervalSince(winClickTime)))
            var wrong: [String] = []
            for f in 0..<4 { for card in game.foundations[f] where !approx(table.cardLayer(for: card)!.frame, table.slotFrame(.foundation(f))) { wrong.append("\(card)@\(fmt(table.cardLayer(for: card)!.frame))") } }
            check("6e all cards back on foundations", wrong.isEmpty, wrong.isEmpty ? "52 cards on their foundation slots" : wrong.joined(separator: " "))
            let (ok, d) = layerAt(king, table.slotFrame(.foundation(3)))
            check("6f K♠ on foundation 3", ok, d)
            shot("after-win")
        }
        step(0.6) { [self] in
            check("6g win sheet shown", window.attachedSheet != nil, "sheet=\(String(describing: window.attachedSheet?.title))")
            shotSheet("win-sheet")
        }

        step(0.8) { [self] in
            note("DONE failures=\(failures)")
            // An NSAlert sheet blocks terminate: while attached (NSWindow.preventsApplicationTerminationWhenModal
            // defaults to true), so dismiss the win sheet first. Cmd-Q behaves the same way for a user.
            if let sheet = window.attachedSheet {
                note("win sheet attached: preventsApplicationTerminationWhenModal=\(sheet.preventsApplicationTerminationWhenModal); ending it before terminate")
                window.endSheet(sheet)
            }
            NSApp.terminate(nil)
        }
        step(1.0) { [self] in
            check("9 NSApp.terminate exited the app", false, "still running 1 s after terminate; sheet=\(String(describing: window.attachedSheet))")
            exit(1)
        }
    }
}
