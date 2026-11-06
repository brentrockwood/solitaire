import Foundation

/// User settings that persist across games. Stored by the app layer.
public struct Settings: Codable, Equatable, Sendable {
    public var scoring: ScoringMode = .standard
    public var drawThree: Bool = false
    public var leftHanded: Bool = true
    public var vegasCumulative: Bool = false
    /// Running Vegas total, in dollars (negative is a loss). Named after the original's save key.
    public var vegasScore: Int = 0
    public var showTimeAndMoves: Bool = true
    public var soundEnabled: Bool = true

    public init() {}

    /// Score to display for `game`, including the cumulative total when enabled.
    public func displayScore(for game: Game) -> Int {
        guard game.scoring == .vegas, vegasCumulative else { return game.score }
        return vegasScore + (game.absorbed ? 0 : game.score)
    }

    public func scoreText(for game: Game) -> String? {
        switch game.scoring {
        case .none: return nil
        case .standard: return String(game.score)
        case .vegas: return Scoring.dollarString(displayScore(for: game))
        }
    }

    /// Fold a Vegas game's result into the cumulative total. Call when a Vegas game is
    /// completed, or when a game in progress is abandoned for a new deal.
    public mutating func absorb(_ game: inout Game) {
        guard game.scoring == .vegas, vegasCumulative, !game.absorbed else { return }
        vegasScore += game.score
        game.absorbed = true
    }
}

public enum TimeFormat {
    /// "m:ss"
    public static func string(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}
