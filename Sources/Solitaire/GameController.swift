import AppKit
import SolitaireCore

/// Owns the game and settings, persists both, runs the clock, and tells the view what changed.
@MainActor
final class GameController {
    private(set) var game: Game
    var settings: Settings { didSet { saveSettings(); Sounds.shared.enabled = settings.soundEnabled } }
    /// False in `--uitest` mode so a scripted run never overwrites the saved game or settings.
    var persists = true

    /// Called after any change to game state. `animatedFrom` is the previous state for the view to animate from.
    var onChange: ((Game) -> Void)?
    var onTick: (() -> Void)?
    var onWin: (() -> Void)?
    var onNoMorePasses: (() -> Void)?

    private var timer: Timer?
    private var lastTick = Date()
    private var autocompleteTask: Task<Void, Never>?

    private static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Solitaire", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static let gameURL = dir.appendingPathComponent("game.json")
    private static let settingsKey = "settings"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey), let s = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = s
        } else {
            settings = Settings()
        }
        Sounds.shared.enabled = settings.soundEnabled
        if let data = try? Data(contentsOf: Self.gameURL), let g = try? JSONDecoder().decode(Game.self, from: data) {
            game = g
        } else {
            game = Game(seed: UInt64.random(in: 1...UInt64.max), scoring: settings.scoring, drawThree: settings.drawThree)
        }
        updateClock()
    }

    // MARK: - Game lifecycle

    func newGame() {
        cancelAutocomplete()
        if game.phase == .playing { settings.absorb(&game) }  // abandoning a Vegas deal still costs its buy-in
        game = Game(seed: UInt64.random(in: 1...UInt64.max), scoring: settings.scoring, drawThree: settings.drawThree)
        Sounds.shared.play(.deal)
        changed()
    }

    func restartGame() {
        cancelAutocomplete()
        if game.phase == .playing { settings.absorb(&game) }
        game = Game(seed: game.seed, scoring: game.scoring, drawThree: game.drawThree)
        Sounds.shared.play(.deal)
        changed()
    }

    /// Replaces the game outright (used by `--uitest` to load fixtures). Does not score or persist.
    func load(_ g: Game) {
        cancelAutocomplete()
        game = g
        updateClock()
        onChange?(game)
    }

    // MARK: - Actions

    func draw() {
        guard autocompleteTask == nil else { return }
        do {
            try game.draw()
            Sounds.shared.play(.flip)
            changed()
        } catch MoveError.noMorePasses {
            onNoMorePasses?()
        } catch {}
    }

    @discardableResult
    func move(from: Pile, index: Int, to: Pile) -> Bool {
        guard autocompleteTask == nil else { return false }
        guard (try? game.move(from: from, index: index, to: to)) != nil else { return false }
        Sounds.shared.play(.place)
        changed()
        return true
    }

    func undo() {
        guard autocompleteTask == nil, game.canUndo else { return }
        try? game.undo()
        Sounds.shared.play(.place)
        changed()
    }

    var canAutocomplete: Bool { autocompleteTask == nil && game.autocompletePlan() != nil }

    func autocomplete() {
        guard let plan = game.autocompletePlan() else { return }
        autocompleteTask = Task { @MainActor [weak self] in
            for step in plan {
                guard let self, !Task.isCancelled else { return }
                try? self.game.apply(step)
                Sounds.shared.play(.place)
                self.changed()
                try? await Task.sleep(for: .milliseconds(110))
            }
            self?.autocompleteTask = nil
        }
    }

    func cancelAutocomplete() {
        autocompleteTask?.cancel()
        autocompleteTask = nil
    }

    func resetVegasTotal() {
        settings.vegasScore = 0
        onTick?()  // labels only; a full change notification would replay a finished game's celebration
    }

    // MARK: - Clock

    /// The clock runs only while a started game is in progress, so an idle or finished table has no timer.
    private func updateClock() {
        let shouldRun = game.phase == .playing && game.started
        if shouldRun && timer == nil {
            lastTick = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer?.tolerance = 0.2
        } else if !shouldRun, let t = timer {
            t.invalidate()
            timer = nil
        }
    }

    private func tick() {
        let now = Date()
        defer { lastTick = now }
        guard game.phase == .playing, game.started, NSApp.isActive || NSApp.windows.contains(where: { $0.isVisible && !$0.isMiniaturized }) else { return }
        game.elapsed += min(now.timeIntervalSince(lastTick), 2)
        onTick?()
    }

    // MARK: - Persistence

    private func changed() {
        if game.phase == .completed {
            settings.absorb(&game)
            Sounds.shared.play(.win)
        }
        updateClock()
        onChange?(game)
        saveGame()
    }

    func saveGame() {
        guard persists else { return }
        if let data = try? JSONEncoder().encode(game) { try? data.write(to: Self.gameURL, options: .atomic) }
    }

    private func saveSettings() {
        guard persists else { return }
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
    }
}
