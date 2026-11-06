import Foundation

public enum Suit: Int, CaseIterable, Codable, Hashable, Sendable {
    case clubs, diamonds, hearts, spades

    public var isRed: Bool { self == .diamonds || self == .hearts }
    public var symbol: String {
        switch self {
        case .clubs: return "♣"
        case .diamonds: return "♦"
        case .hearts: return "♥"
        case .spades: return "♠"
        }
    }
}

/// Rank 1 = ace … 13 = king.
public struct Card: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rank: Int
    public let suit: Suit
    public var faceUp: Bool

    public init(rank: Int, suit: Suit, faceUp: Bool = false) {
        precondition((1...13).contains(rank))
        self.rank = rank
        self.suit = suit
        self.faceUp = faceUp
    }

    public var isAce: Bool { rank == 1 }
    public var isKing: Bool { rank == 13 }
    public var isRed: Bool { suit.isRed }

    /// Identity ignoring face-up state.
    public var id: Int { suit.rawValue * 13 + (rank - 1) }

    public var rankLabel: String {
        switch rank {
        case 1: return "A"
        case 11: return "J"
        case 12: return "Q"
        case 13: return "K"
        default: return String(rank)
        }
    }

    public var description: String { rankLabel + suit.symbol + (faceUp ? "" : "↓") }

    public static func fullDeck() -> [Card] {
        Suit.allCases.flatMap { suit in (1...13).map { Card(rank: $0, suit: suit) } }
    }
}

/// Deterministic shuffle so a deal can be reproduced from its seed.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
