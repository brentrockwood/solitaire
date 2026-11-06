import Testing
import Foundation
@testable import SolitaireCore

// Randomized engine test: play many seeds with random legal actions and check structural
// invariants after every action, plus exact undo round-trips.

private let fuzzSeeds: UInt64 = 300
private let fuzzActionsPerGame = 400

/// All (from, index, to) triples that `canMove` accepts right now.
private func legalMoves(_ g: Game) -> [(Pile, Int, Pile)] {
    var sources: [(Pile, Int)] = []
    if !g.waste.isEmpty { sources.append((.waste, g.waste.count - 1)) }
    for f in 0..<4 where !g.foundations[f].isEmpty { sources.append((.foundation(f), g.foundations[f].count - 1)) }
    for t in 0..<7 {
        for (i, card) in g.tableau[t].enumerated() where card.faceUp { sources.append((.tableau(t), i)) }
    }
    let targets: [Pile] = (0..<4).map { .foundation($0) } + (0..<7).map { .tableau($0) }
    var out: [(Pile, Int, Pile)] = []
    for (from, index) in sources {
        for to in targets where g.canMove(from: from, index: index, to: to) { out.append((from, index, to)) }
    }
    return out
}

/// Returns a list of violated invariants (empty when the state is sound).
private func invariantViolations(_ g: Game, initialScore: Int) -> [String] {
    var problems: [String] = []
    let all = g.stock + g.waste + g.foundations.flatMap { $0 } + g.tableau.flatMap { $0 }
    if all.count != 52 { problems.append("card count \(all.count) != 52") }
    if Set(all.map(\.id)).count != 52 { problems.append("cards are not 52 distinct") }

    if !g.stock.allSatisfy({ !$0.faceUp }) { problems.append("face-up card in stock") }
    if !g.waste.allSatisfy(\.faceUp) { problems.append("face-down card in waste") }
    for (f, pile) in g.foundations.enumerated() {
        if !pile.allSatisfy(\.faceUp) { problems.append("face-down card in foundation \(f)") }
        for (i, card) in pile.enumerated() {
            if card.rank != i + 1 { problems.append("foundation \(f) card \(i) is \(card), expected rank \(i + 1)") }
            if card.suit != pile[0].suit { problems.append("foundation \(f) mixes suits") }
        }
    }
    for (t, column) in g.tableau.enumerated() {
        var seenFaceUp = false
        for (i, card) in column.enumerated() {
            if card.faceUp { seenFaceUp = true } else if seenFaceUp { problems.append("tableau \(t) has face-down card \(card) above a face-up card") }
            if i > 0, card.faceUp, column[i - 1].faceUp {
                let below = column[i - 1]
                if below.rank != card.rank + 1 || below.isRed == card.isRed {
                    problems.append("tableau \(t) run broken at \(i): \(below) then \(card)")
                }
            }
        }
    }

    let recorded = g.undoStack.reduce(0) { sum, record in
        if case let .move(_, _, _, delta, _) = record { return sum + delta } else { return sum }
    }
    if g.score != initialScore + recorded { problems.append("score \(g.score) != initial \(initialScore) + recorded \(recorded)") }

    if let limit = g.passLimit, g.stockPasses > limit - 1 { problems.append("stockPasses \(g.stockPasses) exceeds limit \(limit) - 1") }
    if g.stockPasses < 0 { problems.append("negative stockPasses") }
    if (g.phase == .completed) != g.isWon { problems.append("phase \(g.phase) inconsistent with isWon \(g.isWon)") }
    return problems
}

/// Field-by-field comparison; `moves` is exempt (undo counts as a move) and so is `started`
/// (the original keeps the clock running once any action has been taken, even if undone).
private func undoDifferences(before: Game, after: Game) -> [String] {
    var diffs: [String] = []
    if after.stock != before.stock { diffs.append("stock") }
    if after.waste != before.waste { diffs.append("waste") }
    if after.foundations != before.foundations { diffs.append("foundations") }
    if after.tableau != before.tableau { diffs.append("tableau") }
    if after.score != before.score { diffs.append("score \(after.score) vs \(before.score)") }
    if after.stockPasses != before.stockPasses { diffs.append("stockPasses") }
    if after.phase != before.phase { diffs.append("phase") }
    if after.elapsed != before.elapsed { diffs.append("elapsed") }
    if after.undoStack != before.undoStack { diffs.append("undoStack") }
    if after.seed != before.seed || after.scoring != before.scoring || after.drawThree != before.drawThree { diffs.append("constants") }
    if after.moves != before.moves + 2 { diffs.append("moves \(after.moves) != \(before.moves) + 2") }
    return diffs
}

@Test(arguments: ScoringMode.allCases, [false, true])
func randomPlayKeepsInvariants(scoring: ScoringMode, drawThree: Bool) throws {
    for seed in 1...fuzzSeeds {
        var g = Game(seed: seed, scoring: scoring, drawThree: drawThree)
        let initialScore = g.score
        var rng = SplitMix64(seed: seed &* 7919 &+ UInt64(scoring.rawValue) &+ (drawThree ? 1000 : 0))
        var ok = true
        func check(_ condition: Bool, _ message: @autoclosure () -> String, step: Int) {
            guard ok, !condition else { return }
            ok = false
            #expect(Bool(false), "\(scoring.label) draw\(drawThree ? 3 : 1) seed \(seed) step \(step): \(message())")
        }

        let initial = invariantViolations(g, initialScore: initialScore)
        check(initial.isEmpty, "fresh deal: \(initial)", step: 0)

        for step in 1...fuzzActionsPerGame where ok && g.phase == .playing {
            let before = g
            let moves = legalMoves(g)
            let roll = Int.random(in: 0..<100, using: &rng)
            let canDraw = !(g.stock.isEmpty && g.waste.isEmpty)
            var actedWithRecord = false

            if roll < 10, g.canUndo {
                try g.undo()
                check(g.moves == before.moves + 1, "undo did not count as a move", step: step)
            } else if (roll < 45 || moves.isEmpty) && canDraw {
                let expectThrow = g.stock.isEmpty && !g.waste.isEmpty && !g.canRecycle
                do {
                    try g.draw()
                    check(!expectThrow, "draw succeeded although no passes remain", step: step)
                    check(g.moves == before.moves + 1, "draw did not count as a move", step: step)
                    check(g.undoStack.count == before.undoStack.count + 1, "draw did not push an undo record", step: step)
                    actedWithRecord = true
                } catch MoveError.noMorePasses {
                    check(expectThrow, "noMorePasses thrown while canRecycle was \(before.canRecycle)", step: step)
                    check(g == before, "a thrown draw changed the game", step: step)
                }
            } else if !moves.isEmpty {
                let (from, index, to) = moves[Int.random(in: 0..<moves.count, using: &rng)]
                let delta = try g.move(from: from, index: index, to: to)
                check(g.moves == before.moves + 1, "move did not count as a move", step: step)
                check(g.score == before.score + delta, "returned delta \(delta) does not match score change", step: step)
                check(g.undoStack.count == before.undoStack.count + 1, "move did not push an undo record", step: step)
                actedWithRecord = true
            } else if g.canUndo {
                try g.undo()
            } else {
                break  // stuck: nothing to draw, move, or undo
            }

            let problems = invariantViolations(g, initialScore: initialScore)
            check(problems.isEmpty, "\(problems)", step: step)

            // Random subset: undo and compare with the pre-action state.
            if ok, actedWithRecord, g.phase == .playing, Int.random(in: 0..<4, using: &rng) == 0 {
                try g.undo()
                let diffs = undoDifferences(before: before, after: g)
                check(diffs.isEmpty, "undo did not restore state: \(diffs)", step: step)
                let afterUndo = invariantViolations(g, initialScore: initialScore)
                check(afterUndo.isEmpty, "after undo: \(afterUndo)", step: step)
            }
        }
    }
}
