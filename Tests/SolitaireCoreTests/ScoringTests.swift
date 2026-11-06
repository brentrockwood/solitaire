import Testing
import Foundation
@testable import SolitaireCore

// MARK: - Point table (scoring.md)

@Test func pointTable() {
    #expect(Scoring.initialScore(.standard) == 0)
    #expect(Scoring.initialScore(.none) == 0)
    #expect(Scoring.initialScore(.vegas) == -52)
    #expect(Scoring.movePoints(.standard, from: .waste, to: .foundation(0)) == 10)
    #expect(Scoring.movePoints(.standard, from: .tableau(1), to: .foundation(0)) == 10)
    #expect(Scoring.movePoints(.vegas, from: .tableau(1), to: .foundation(0)) == 5)
    #expect(Scoring.movePoints(.standard, from: .foundation(1), to: .foundation(0)) == 0)
    #expect(Scoring.movePoints(.standard, from: .waste, to: .tableau(0)) == 5)
    #expect(Scoring.movePoints(.vegas, from: .waste, to: .tableau(0)) == 0)
    #expect(Scoring.movePoints(.standard, from: .foundation(0), to: .tableau(0)) == -15)
    #expect(Scoring.movePoints(.vegas, from: .foundation(0), to: .tableau(0)) == -5)
    #expect(Scoring.movePoints(.standard, from: .tableau(0), to: .tableau(1)) == 0)
    #expect(Scoring.reveal(.standard) == 5)
    #expect(Scoring.reveal(.none) == 5)
    #expect(Scoring.reveal(.vegas) == 0)
    #expect(Scoring.passLimit(.standard, drawThree: true) == nil)
    #expect(Scoring.passLimit(.none, drawThree: false) == nil)
    #expect(Scoring.passLimit(.vegas, drawThree: false) == 1)
    #expect(Scoring.passLimit(.vegas, drawThree: true) == 3)
    #expect(Scoring.dollarString(-52) == "-$52")
    #expect(Scoring.dollarString(0) == "$0")
    #expect(Scoring.dollarString(13) == "$13")
}

// MARK: - Deal

@Test func dealShape() {
    let g = Game(seed: 1, scoring: .standard, drawThree: false)
    #expect(g.stock.count == 24)
    #expect(g.waste.isEmpty)
    for (i, column) in g.tableau.enumerated() {
        #expect(column.count == i + 1)
        #expect(column.last!.faceUp)
        #expect(column.dropLast().allSatisfy { !$0.faceUp })
    }
    #expect(g.stock.allSatisfy { !$0.faceUp })
    let all = (g.stock + g.tableau.flatMap { $0 }).map { var c = $0; c.faceUp = false; return c }
    #expect(Set(all).count == 52)
    #expect(Game(seed: 1, scoring: .standard, drawThree: false) == g, "seeded deals are reproducible")
    #expect(Game(seed: 2, scoring: .standard, drawThree: false).stock != g.stock)
}

// MARK: - Draw and recycle

@Test func drawOneAndRecycleUnlimitedInStandard() throws {
    var g = Game(seed: 3, scoring: .standard, drawThree: false)
    try g.draw()
    #expect(g.waste.count == 1)
    #expect(g.waste[0].faceUp)
    #expect(g.moves == 1)
    #expect(g.score == 0)
    #expect(g.started)
    for _ in 0..<23 { try g.draw() }
    #expect(g.stock.isEmpty)
    let wasteOrder = g.waste
    try g.draw()  // recycle
    #expect(g.stockPasses == 1)
    #expect(g.stock.count == 24)
    #expect(g.waste.isEmpty)
    #expect(g.stock.allSatisfy { !$0.faceUp })
    try g.draw()
    #expect(g.waste[0].id == wasteOrder[0].id, "recycling preserves order")
    for _ in 0..<60 { try g.draw() }
    #expect(g.stockPasses > 2)
}

@Test func drawThreeDrawsUpToThree() throws {
    var g = Game(seed: 3, scoring: .standard, drawThree: true)
    try g.draw()
    #expect(g.waste.count == 3)
    for _ in 0..<7 { try g.draw() }
    #expect(g.waste.count == 24)
    #expect(g.stock.isEmpty)
}

@Test func vegasDrawOneAllowsNoRecycle() throws {
    var g = Game(seed: 3, scoring: .vegas, drawThree: false)
    #expect(g.score == -52)
    for _ in 0..<24 { try g.draw() }
    #expect(!g.canRecycle)
    #expect(throws: MoveError.noMorePasses) { try g.draw() }
    #expect(g.stockPasses == 0)
}

@Test func vegasDrawThreeAllowsThreePasses() throws {
    var g = Game(seed: 3, scoring: .vegas, drawThree: true)
    for pass in 1...3 {
        for _ in 0..<8 { try g.draw() }
        #expect(g.stock.isEmpty)
        if pass < 3 {
            #expect(g.canRecycle)
            try g.draw()
            #expect(g.stockPasses == pass)
        }
    }
    #expect(!g.canRecycle)
    #expect(throws: MoveError.noMorePasses) { try g.draw() }

    var h = Game(seed: 3, scoring: .vegas, drawThree: true)
    for _ in 0..<8 { try h.draw() }
    try h.draw()
    #expect(h.stockPasses == 1)
    try h.undo()
    #expect(h.stockPasses == 0, "undoing a recycle gives the pass back")
    #expect(h.waste.count == 24)
    #expect(h.stock.isEmpty)
}

// MARK: - Move scoring with reveal and undo

/// A seeded deal where a tableau top card can move onto another column, revealing a card.
private func findRevealMove() -> (Game, Pile, Int, Pile) {
    for seed in 1...5000 {
        let g = Game(seed: UInt64(seed), scoring: .standard, drawThree: false)
        for from in 1..<7 {
            let idx = g.tableau[from].count - 1
            for to in 0..<7 where g.canMove(from: .tableau(from), index: idx, to: .tableau(to)) {
                return (g, .tableau(from), idx, .tableau(to))
            }
        }
    }
    fatalError("no reveal move found")
}

@Test func tableauMoveRevealsAndScoresFive() throws {
    var (g, from, idx, to) = findRevealMove()
    let delta = try g.move(from: from, index: idx, to: to)
    #expect(delta == 5, "tableau to tableau is 0, reveal is +5")
    #expect(g.score == 5)
    #expect(g.moves == 1)
    guard case .tableau(let f) = from else { Issue.record("bad pile"); return }
    #expect(g.tableau[f].last!.faceUp)
    #expect(g.undoStack.last == .move(from: from, to: to, count: 1, scoreDelta: 5, revealed: true))
    try g.undo()
    #expect(g.score == 0)
    #expect(g.moves == 2, "undo counts as a move")
    #expect(!g.tableau[f][idx - 1].faceUp, "undo re-closes the revealed card")
    #expect(g.tableau[f].count == idx + 1)
}

@Test func revealIsZeroInVegas() throws {
    let (std, from, idx, to) = findRevealMove()
    var g = Game(seed: std.seed, scoring: .vegas, drawThree: false)
    #expect(try g.move(from: from, index: idx, to: to) == 0)
    #expect(g.score == -52)
}

/// A deal whose first drawn card is an ace.
private func findWasteToFoundation(_ mode: ScoringMode) -> Game {
    for seed in 1...5000 {
        var g = Game(seed: UInt64(seed), scoring: mode, drawThree: false)
        try! g.draw()
        if g.waste.last!.isAce { return g }
    }
    fatalError()
}

@Test func wasteToFoundationAndFoundationToFoundation() throws {
    var g = findWasteToFoundation(.standard)
    #expect(try g.move(from: .waste, index: 0, to: .foundation(0)) == 10)
    #expect(g.score == 10)
    #expect(g.foundations[0].count == 1)
    #expect(try g.move(from: .foundation(0), index: 0, to: .foundation(1)) == 0, "foundation to foundation scores nothing")
    #expect(g.score == 10)
    try g.undo()
    try g.undo()
    #expect(g.score == 0)
    #expect(g.waste.count == 1)
    #expect(g.foundations[0].isEmpty)

    var v = findWasteToFoundation(.vegas)
    #expect(try v.move(from: .waste, index: 0, to: .foundation(2)) == 5)
    #expect(v.score == -47)
}

@Test func foundationToTableauPenaltyThroughEngine() throws {
    // Construct: 2♥ on foundation (over A♥), 3♠ as a tableau top. Moving 2♥ onto 3♠ is legal and costs 15.
    var g = Game(seed: 1, scoring: .standard, drawThree: false)
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(g)) as! [String: Any]
    func card(_ r: Int, _ s: Suit, _ up: Bool = true) -> [String: Any] { ["rank": r, "suit": s.rawValue, "faceUp": up] }
    json["stock"] = [card(5, .clubs, false)]
    json["waste"] = []
    json["foundations"] = [[card(1, .hearts), card(2, .hearts)], [], [], []]
    json["tableau"] = [[card(3, .spades)], [card(7, .diamonds, false), card(4, .clubs)], [], [], [], [], []]
    g = try JSONDecoder().decode(Game.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(try g.move(from: .foundation(0), index: 1, to: .tableau(0)) == -15)
    #expect(g.score == -15)
    #expect(g.tableau[0].count == 2)
    #expect(!g.canMove(from: .foundation(0), index: 0, to: .tableau(0)), "ace cannot go on a 2")
    try g.undo()
    #expect(g.score == 0)
    #expect(g.foundations[0].count == 2)
}

// MARK: - Rules

@Test func illegalMovesRejected() throws {
    var g = Game(seed: 7, scoring: .standard, drawThree: false)
    #expect(throws: MoveError.illegal) { try g.move(from: .stock, index: 0, to: .tableau(0)) }
    #expect(throws: MoveError.illegal) { try g.move(from: .tableau(1), index: 0, to: .tableau(0)) }
    #expect(!g.canMove(from: .tableau(0), index: 0, to: .tableau(0)))
    #expect(g.draggableStart(in: .tableau(6), at: 3) == nil, "face-down card is not draggable")
    #expect(g.draggableStart(in: .tableau(6), at: 6) == 6)
}

@Test func onlyKingOnEmptyColumn() throws {
    var g = Game(seed: 1, scoring: .standard, drawThree: false)
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(g)) as! [String: Any]
    func card(_ r: Int, _ s: Suit, _ up: Bool = true) -> [String: Any] { ["rank": r, "suit": s.rawValue, "faceUp": up] }
    json["tableau"] = [[], [card(13, .hearts)], [card(12, .spades)], [card(9, .clubs, false), card(13, .clubs)], [], [], []]
    json["stock"] = []; json["waste"] = [card(13, .diamonds)]
    g = try JSONDecoder().decode(Game.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(g.canMove(from: .tableau(1), index: 0, to: .tableau(0)))
    #expect(!g.canMove(from: .tableau(2), index: 0, to: .tableau(0)))
    #expect(g.canMove(from: .tableau(3), index: 1, to: .tableau(0)))
    #expect(g.canMove(from: .waste, index: 0, to: .tableau(0)))
    #expect(g.autoMoveTarget(from: .tableau(1), index: 0) == nil, "a lone king at a column base has nowhere useful to go")
    #expect(g.autoMoveTarget(from: .tableau(3), index: 1) == .tableau(0))
    #expect(g.autoMoveTarget(from: .tableau(2), index: 0) == .tableau(1), "queen onto the king")
}

// MARK: - Persistence and settings

@Test func codableRoundTrip() throws {
    var g = Game(seed: 42, scoring: .vegas, drawThree: true)
    try g.draw()
    g.elapsed = 12.5
    let back = try JSONDecoder().decode(Game.self, from: JSONEncoder().encode(g))
    #expect(back == g)
}

@Test func vegasCumulativeDisplayAndAbsorb() throws {
    var s = Settings()
    s.scoring = .vegas
    s.vegasCumulative = true
    s.vegasScore = -30
    var g = Game(seed: 1, scoring: .vegas, drawThree: false)
    #expect(s.displayScore(for: g) == -82)
    #expect(s.scoreText(for: g) == "-$82")
    s.absorb(&g)
    #expect(s.vegasScore == -82)
    #expect(g.absorbed)
    #expect(s.displayScore(for: g) == -82, "an absorbed game is not added to the total again")
    s.absorb(&g)
    #expect(s.vegasScore == -82, "absorbing twice is a no-op")
    s.vegasCumulative = false
    #expect(s.scoreText(for: g) == "-$52")
    var h = Game(seed: 2, scoring: .vegas, drawThree: false)
    s.absorb(&h)
    #expect(s.vegasScore == -82 && !h.absorbed, "absorb is a no-op when cumulative is off")
    var std = Game(seed: 3, scoring: .standard, drawThree: false)
    s.vegasCumulative = true
    s.absorb(&std)
    #expect(s.vegasScore == -82, "standard games never touch the Vegas total")
    #expect(Settings().scoreText(for: Game(seed: 1, scoring: .none, drawThree: false)) == nil)
    #expect(Settings().scoreText(for: Game(seed: 1, scoring: .standard, drawThree: false)) == "0")
}

@Test func timeFormat() {
    #expect(TimeFormat.string(0) == "0:00")
    #expect(TimeFormat.string(65.9) == "1:05")
    #expect(TimeFormat.string(3600) == "60:00")
}

// MARK: - Autocomplete

@Test func autocompleteFinishesSimpleEndgame() throws {
    var g = Game(seed: 1, scoring: .standard, drawThree: false)
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(g)) as! [String: Any]
    func card(_ r: Int, _ s: Suit, _ up: Bool = true) -> [String: Any] { ["rank": r, "suit": s.rawValue, "faceUp": up] }
    json["stock"] = [card(13, .spades, false)]
    json["waste"] = [card(12, .hearts)]
    json["foundations"] = [
        (1...13).map { card($0, .clubs) },
        (1...13).map { card($0, .diamonds) },
        (1...11).map { card($0, .hearts) },
        (1...12).map { card($0, .spades) },
    ]
    json["tableau"] = [[], [card(13, .hearts)], [], [], [], [], []]
    g = try JSONDecoder().decode(Game.self, from: JSONSerialization.data(withJSONObject: json))
    let plan = try #require(g.autocompletePlan())
    #expect(plan.count == 4, "Q♥, K♥, draw, K♠")
    for step in plan { try g.apply(step) }
    #expect(g.isWon)
    #expect(g.phase == .completed)
    #expect(g.score == 30)
    #expect(!g.canUndo, "no undo after completion")
}

@Test func autocompleteUnavailableWithFaceDownCards() {
    #expect(Game(seed: 1, scoring: .standard, drawThree: false).autocompletePlan() == nil)
}
