import Testing
import Foundation
@testable import SolitaireCore

/// Builds a game with an explicit layout by going through the Codable representation.
private func makeGame(scoring: ScoringMode = .standard, drawThree: Bool = false,
                      stock: [Card] = [], waste: [Card] = [], foundations: [[Card]] = [[], [], [], []], tableau: [[Card]]) throws -> Game {
    let g = Game(seed: 1, scoring: scoring, drawThree: drawThree)
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(g)) as! [String: Any]
    func enc(_ c: Card) -> [String: Any] { ["rank": c.rank, "suit": c.suit.rawValue, "faceUp": c.faceUp] }
    json["stock"] = stock.map(enc); json["waste"] = waste.map(enc)
    json["foundations"] = foundations.map { $0.map(enc) }
    var t = tableau; while t.count < 7 { t.append([]) }
    json["tableau"] = t.map { $0.map(enc) }
    return try JSONDecoder().decode(Game.self, from: JSONSerialization.data(withJSONObject: json))
}
private func c(_ r: Int, _ s: Suit, up: Bool = true) -> Card { Card(rank: r, suit: s, faceUp: up) }

@Test func noneModeScoresLikeStandardThroughEngine() throws {
    var g = try makeGame(scoring: .none, tableau: [[c(9, .clubs, up: false), c(1, .hearts)]])
    #expect(try g.move(from: .tableau(0), index: 1, to: .foundation(0)) == 15, "10 to foundation + 5 reveal")
    #expect(g.score == 15)
    #expect(g.tableau[0][0].faceUp)
    try g.undo()
    #expect(g.score == 0)
    #expect(!g.tableau[0][0].faceUp)
    #expect(g.tableau[0].count == 2)
}

@Test func multiCardRunMoveAndUndoRestoresOrder() throws {
    var g = try makeGame(tableau: [[c(5, .spades, up: false), c(8, .hearts), c(7, .clubs), c(6, .diamonds)], [c(9, .spades)]])
    #expect(g.canMove(from: .tableau(0), index: 1, to: .tableau(1)))
    #expect(!g.canMove(from: .tableau(0), index: 2, to: .tableau(1)), "7♣ can't go on 9♠")
    #expect(try g.move(from: .tableau(0), index: 1, to: .tableau(1)) == 5, "reveal only")
    #expect(g.tableau[1].map(\.rank) == [9, 8, 7, 6])
    #expect(g.tableau[0].map(\.faceUp) == [true])
    #expect(g.undoStack.last == .move(from: .tableau(0), to: .tableau(1), count: 3, scoreDelta: 5, revealed: true))
    try g.undo()
    #expect(g.tableau[0].map(\.rank) == [5, 8, 7, 6])
    #expect(g.tableau[0].map(\.faceUp) == [false, true, true, true])
    #expect(g.tableau[1].map(\.rank) == [9])
    #expect(g.score == 0)
}

@Test func moveWithNothingToRevealRecordsNoReveal() throws {
    var g = try makeGame(tableau: [[c(9, .clubs), c(8, .hearts)], [c(9, .spades)]])
    #expect(try g.move(from: .tableau(0), index: 1, to: .tableau(1)) == 0)
    #expect(g.undoStack.last == .move(from: .tableau(0), to: .tableau(1), count: 1, scoreDelta: 0, revealed: false))
    try g.undo()
    #expect(g.tableau[0].count == 2 && g.tableau[0][0].faceUp)
}

@Test func partialDrawThreeUndoRestoresStock() throws {
    var g = try makeGame(drawThree: true, stock: [c(2, .clubs, up: false), c(3, .clubs, up: false)], waste: [c(4, .clubs)], tableau: [[c(13, .hearts)]])
    try g.draw()
    #expect(g.waste.map(\.rank) == [4, 3, 2])
    #expect(g.stock.isEmpty)
    try g.undo()
    #expect(g.stock.map(\.rank) == [2, 3] && g.stock.allSatisfy { !$0.faceUp })
    #expect(g.waste.map(\.rank) == [4])
}

@Test func vegasRecycleUndoRestoresPassAllowance() throws {
    var g = try makeGame(scoring: .vegas, drawThree: true, stock: [c(2, .clubs, up: false)], tableau: [[c(13, .hearts)]])
    try g.draw(); try g.draw()  // draw, recycle (pass 1 done)
    try g.draw(); try g.draw()  // draw, recycle (pass 2 done)
    #expect(g.stockPasses == 2)
    try g.draw()
    #expect(!g.canRecycle)
    #expect(throws: MoveError.noMorePasses) { try g.draw() }
    try g.undo()  // un-draw
    try g.undo()  // un-recycle
    #expect(g.stockPasses == 1)
    #expect(g.canRecycle)
}

@Test func drawWithEmptyStockAndWasteIsNoOp() throws {
    var g = try makeGame(tableau: [[c(13, .hearts)]])
    try g.draw()
    #expect(g.moves == 0 && g.undoStack.isEmpty && !g.started)
}

@Test func actionsAfterCompletionThrow() throws {
    var g = try makeGame(foundations: [(1...13).map { c($0, .clubs) }, (1...13).map { c($0, .diamonds) }, (1...13).map { c($0, .hearts) }, (1...12).map { c($0, .spades) }],
                         tableau: [[c(13, .spades)]])
    #expect(try g.move(from: .tableau(0), index: 0, to: .foundation(3)) == 10)
    #expect(g.phase == .completed && g.isWon)
    #expect(throws: MoveError.notPlaying) { try g.draw() }
    #expect(throws: MoveError.notPlaying) { try g.undo() }
    #expect(throws: MoveError.notPlaying) { try g.move(from: .foundation(3), index: 12, to: .tableau(0)) }
}
