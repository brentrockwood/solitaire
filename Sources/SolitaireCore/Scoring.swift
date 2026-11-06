import Foundation

/// Scoring modes exactly as in Solitaire Epic (see scoring.md).
public enum ScoringMode: Int, Codable, CaseIterable, Sendable {
    /// Scored like Standard internally, but the score is not shown.
    case none = 0
    case standard = 1
    case vegas = 2

    public var label: String {
        switch self {
        case .none: return "None"
        case .standard: return "Standard"
        case .vegas: return "Vegas"
        }
    }
}

public enum Scoring {
    public static func initialScore(_ mode: ScoringMode) -> Int { mode == .vegas ? -52 : 0 }
    public static func toFoundation(_ mode: ScoringMode) -> Int { mode == .vegas ? 5 : 10 }
    public static func wasteToTableau(_ mode: ScoringMode) -> Int { mode == .vegas ? 0 : 5 }
    public static func foundationToTableau(_ mode: ScoringMode) -> Int { mode == .vegas ? -5 : -15 }
    public static func reveal(_ mode: ScoringMode) -> Int { mode == .vegas ? 0 : 5 }

    /// Points for moving a run whose source is `from` onto `to`, before any reveal bonus.
    public static func movePoints(_ mode: ScoringMode, from: Pile, to: Pile) -> Int {
        switch (from, to) {
        case (.foundation, .foundation): return 0
        case (_, .foundation): return toFoundation(mode)
        case (.waste, .tableau): return wasteToTableau(mode)
        case (.foundation, .tableau): return foundationToTableau(mode)
        default: return 0
        }
    }

    /// Number of passes through the stock allowed; nil means unlimited.
    public static func passLimit(_ mode: ScoringMode, drawThree: Bool) -> Int? {
        guard mode == .vegas else { return nil }
        return drawThree ? 3 : 1
    }

    /// "$13", "-$52"
    public static func dollarString(_ value: Int) -> String {
        (value < 0 ? "-$" : "$") + String(abs(value))
    }
}
