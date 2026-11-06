import Foundation

public enum Pile: Hashable, Codable, Sendable {
    case stock
    case waste
    case foundation(Int)
    case tableau(Int)

    public var isFoundation: Bool { if case .foundation = self { return true } else { return false } }
    public var isTableau: Bool { if case .tableau = self { return true } else { return false } }
}

/// One undoable action.
public enum UndoRecord: Codable, Equatable, Sendable {
    /// `count` cards moved from `from` to `to`; `revealed` means the card left on top of
    /// the source tableau column was turned face up by this move.
    case move(from: Pile, to: Pile, count: Int, scoreDelta: Int, revealed: Bool)
    /// `count` cards drawn from stock to waste.
    case draw(count: Int)
    /// Waste recycled into stock.
    case recycle
}
