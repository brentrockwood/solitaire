import Foundation

public enum GamePhase: Int, Codable, Sendable { case playing, completed }

public enum MoveError: Error, Equatable {
    case illegal
    case notPlaying
    case nothingToUndo
    case noMorePasses
}

/// Complete Klondike game state. Piles are arrays with the top card last.
public struct Game: Codable, Equatable, Sendable {
    public private(set) var stock: [Card] = []
    public private(set) var waste: [Card] = []
    public private(set) var foundations: [[Card]] = Array(repeating: [], count: 4)
    public private(set) var tableau: [[Card]] = Array(repeating: [], count: 7)

    public let seed: UInt64
    public let scoring: ScoringMode
    public let drawThree: Bool

    public private(set) var score: Int
    public private(set) var moves: Int = 0
    public private(set) var stockPasses: Int = 0
    public private(set) var phase: GamePhase = .playing
    /// True once the first action has been taken; the clock runs from then on.
    public private(set) var started = false
    public var elapsed: TimeInterval = 0
    public private(set) var undoStack: [UndoRecord] = []
    /// True once this game's score has been folded into the Vegas cumulative total.
    public internal(set) var absorbed = false

    public init(seed: UInt64, scoring: ScoringMode, drawThree: Bool) {
        self.seed = seed
        self.scoring = scoring
        self.drawThree = drawThree
        self.score = Scoring.initialScore(scoring)
        var rng = SplitMix64(seed: seed)
        var deck = Card.fullDeck().shuffled(using: &rng)
        for column in 0..<7 {
            for row in 0...column {
                var card = deck.removeLast()
                card.faceUp = (row == column)
                tableau[column].append(card)
            }
        }
        stock = deck
    }

    // MARK: - Queries

    public func cards(in pile: Pile) -> [Card] {
        switch pile {
        case .stock: return stock
        case .waste: return waste
        case .foundation(let i): return foundations[i]
        case .tableau(let i): return tableau[i]
        }
    }

    public var isWon: Bool { foundations.allSatisfy { $0.count == 13 } }

    public var passLimit: Int? { Scoring.passLimit(scoring, drawThree: drawThree) }

    /// Whether clicking an empty stock may recycle the waste.
    public var canRecycle: Bool {
        guard let limit = passLimit else { return true }
        return stockPasses + 1 < limit
    }

    /// Index of the first card of the run that may be dragged from `pile`, or nil.
    public func draggableStart(in pile: Pile, at index: Int) -> Int? {
        let cards = self.cards(in: pile)
        guard index >= 0, index < cards.count else { return nil }
        switch pile {
        case .stock: return nil
        case .waste, .foundation: return index == cards.count - 1 ? index : nil
        case .tableau: return cards[index].faceUp ? index : nil
        }
    }

    public func canMove(from: Pile, index: Int, to: Pile) -> Bool {
        guard phase == .playing, from != to, draggableStart(in: from, at: index) != nil else { return false }
        let run = Array(cards(in: from)[index...])
        guard let first = run.first else { return false }
        switch to {
        case .stock, .waste:
            return false
        case .foundation(let f):
            guard run.count == 1 else { return false }
            let pile = foundations[f]
            if let top = pile.last { return top.suit == first.suit && top.rank + 1 == first.rank }
            return first.isAce
        case .tableau(let t):
            if let top = tableau[t].last {
                return top.isRed != first.isRed && top.rank == first.rank + 1
            }
            return first.isKing
        }
    }

    // MARK: - Actions

    /// Move the run starting at `index` in `from` onto `to`. Returns the score change.
    @discardableResult
    public mutating func move(from: Pile, index: Int, to: Pile) throws -> Int {
        guard phase == .playing else { throw MoveError.notPlaying }
        guard canMove(from: from, index: index, to: to) else { throw MoveError.illegal }
        var run = Array(cards(in: from)[index...])
        remove(count: run.count, from: from)
        for i in run.indices { run[i].faceUp = true }
        append(run, to: to)

        var delta = Scoring.movePoints(scoring, from: from, to: to)
        var revealed = false
        if case .tableau(let t) = from, let top = tableau[t].last, !top.faceUp {
            tableau[t][tableau[t].count - 1].faceUp = true
            revealed = true
            delta += Scoring.reveal(scoring)
        }
        score += delta
        moves += 1
        started = true
        undoStack.append(.move(from: from, to: to, count: run.count, scoreDelta: delta, revealed: revealed))
        if isWon { phase = .completed }
        return delta
    }

    /// Click on the stock: draw one or three cards, or recycle the waste.
    public mutating func draw() throws {
        guard phase == .playing else { throw MoveError.notPlaying }
        if stock.isEmpty {
            guard !waste.isEmpty else { return }
            guard canRecycle else { throw MoveError.noMorePasses }
            stock = waste.reversed().map { var c = $0; c.faceUp = false; return c }
            waste = []
            stockPasses += 1
            moves += 1
            started = true
            undoStack.append(.recycle)
            return
        }
        let count = min(drawThree ? 3 : 1, stock.count)
        for _ in 0..<count {
            var card = stock.removeLast()
            card.faceUp = true
            waste.append(card)
        }
        moves += 1
        started = true
        undoStack.append(.draw(count: count))
    }

    public var canUndo: Bool { phase == .playing && !undoStack.isEmpty }

    public mutating func undo() throws {
        guard phase == .playing else { throw MoveError.notPlaying }
        guard let record = undoStack.popLast() else { throw MoveError.nothingToUndo }
        switch record {
        case let .move(from, to, count, delta, revealed):
            if revealed, case .tableau(let t) = from {
                tableau[t][tableau[t].count - 1].faceUp = false
            }
            let run = Array(cards(in: to).suffix(count))
            remove(count: count, from: to)
            append(run, to: from)
            score -= delta
        case .draw(let count):
            for _ in 0..<count {
                var card = waste.removeLast()
                card.faceUp = false
                stock.append(card)
            }
        case .recycle:
            waste = stock.reversed().map { var c = $0; c.faceUp = true; return c }
            stock = []
            stockPasses -= 1
        }
        moves += 1
    }

    /// Destination for a single click on a card, mimicking the original's tap-to-move:
    /// foundation first, then the first tableau column that accepts the run.
    public func autoMoveTarget(from: Pile, index: Int) -> Pile? {
        guard draggableStart(in: from, at: index) != nil else { return nil }
        for f in 0..<4 where canMove(from: from, index: index, to: .foundation(f)) { return .foundation(f) }
        // Prefer non-empty columns; an empty column only for a king that is not already at a column base.
        for t in 0..<7 where !tableau[t].isEmpty && canMove(from: from, index: index, to: .tableau(t)) { return .tableau(t) }
        if case .tableau = from, index == 0 { return nil }
        for t in 0..<7 where tableau[t].isEmpty && canMove(from: from, index: index, to: .tableau(t)) { return .tableau(t) }
        return nil
    }

    // MARK: - Autocomplete

    public struct Step: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case move(from: Pile, to: Pile), draw }
        public let kind: Kind
    }

    /// A sequence of actions that finishes the game by moving cards to the foundations,
    /// drawing from the stock when needed, or nil if that cannot finish it from here.
    public func autocompletePlan() -> [Step]? {
        guard phase == .playing, tableau.allSatisfy({ $0.allSatisfy(\.faceUp) }) else { return nil }
        var sim = self
        var steps: [Step] = []
        var drawsWithoutProgress = 0
        while !sim.isWon {
            var progressed = false
            let sources: [Pile] = [.waste] + (0..<7).map { .tableau($0) }
            for source in sources {
                let cards = sim.cards(in: source)
                guard !cards.isEmpty else { continue }
                let index = cards.count - 1
                if let f = (0..<4).first(where: { sim.canMove(from: source, index: index, to: .foundation($0)) }) {
                    _ = try? sim.move(from: source, index: index, to: .foundation(f))
                    steps.append(Step(kind: .move(from: source, to: .foundation(f))))
                    progressed = true
                    break
                }
            }
            if progressed { drawsWithoutProgress = 0; continue }
            guard !(sim.stock.isEmpty && sim.waste.isEmpty) else { return nil }
            if sim.stock.isEmpty && !sim.canRecycle { return nil }
            drawsWithoutProgress += 1
            if drawsWithoutProgress > sim.stock.count + sim.waste.count + 2 { return nil }
            try? sim.draw()
            steps.append(Step(kind: .draw))
        }
        return steps
    }

    public mutating func apply(_ step: Step) throws {
        switch step.kind {
        case .draw: try draw()
        case let .move(from, to): try move(from: from, index: cards(in: from).count - 1, to: to)
        }
    }

    // MARK: - Helpers

    private mutating func remove(count: Int, from pile: Pile) {
        switch pile {
        case .stock: stock.removeLast(count)
        case .waste: waste.removeLast(count)
        case .foundation(let i): foundations[i].removeLast(count)
        case .tableau(let i): tableau[i].removeLast(count)
        }
    }

    private mutating func append(_ cards: [Card], to pile: Pile) {
        switch pile {
        case .stock: stock.append(contentsOf: cards)
        case .waste: waste.append(contentsOf: cards)
        case .foundation(let i): foundations[i].append(contentsOf: cards)
        case .tableau(let i): tableau[i].append(contentsOf: cards)
        }
    }
}
