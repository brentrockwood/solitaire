import AppKit
import SolitaireCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let controller = GameController()
    var window: NSWindow!
    var table: TableView!
    var screenshotPath: String?
    var uiTest: UITest?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        table = TableView(controller: controller)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Solitaire"
        window.contentView = table
        window.minSize = NSSize(width: 560, height: 420)
        // Do not set `contentAspectRatio` to 0x0 here: AppKit raises an NSException when it later
        // restores the autosaved frame with a zero aspect ratio, which silently aborts the rest of
        // this method (no window, no screenshot timer). Unconstrained is already the default.
        window.collectionBehavior = [.fullScreenPrimary]
        window.setFrameAutosaveName("MainWindow")
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let path = screenshotPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
                table.writeSnapshot(to: path)
                NSApp.terminate(nil)
            }
        }
        controller.onWin = { [weak self] in self?.showWinAlert() }
        controller.onNoMorePasses = { [weak self] in self?.showNoMorePasses() }
        uiTest?.start(controller: controller, table: table, window: window)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        controller.saveGame()
    }

    // MARK: - Menu

    private func buildMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)
        appMenu.addItem(withTitle: "About Solitaire", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Solitaire", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Solitaire", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = NSMenu(title: "Game")
        let fileItem = NSMenuItem(); fileItem.submenu = file; main.addItem(fileItem)
        file.addItem(withTitle: "New Game", action: #selector(newGame), keyEquivalent: "n")
        file.addItem(withTitle: "Restart This Game", action: #selector(restartGame), keyEquivalent: "r")
        file.addItem(.separator())
        file.addItem(withTitle: "Undo Move", action: #selector(undoMove), keyEquivalent: "z")
        file.addItem(withTitle: "Autocomplete", action: #selector(autocomplete), keyEquivalent: "a")
        file.addItem(.separator())
        file.addItem(withTitle: "Draw Three", action: #selector(toggleDrawThree), keyEquivalent: "")
        let scoring = NSMenu(title: "Scoring")
        for mode in ScoringMode.allCases {
            let item = scoring.addItem(withTitle: mode.label, action: #selector(setScoring(_:)), keyEquivalent: "")
            item.tag = mode.rawValue
        }
        let scoringItem = file.addItem(withTitle: "Scoring", action: nil, keyEquivalent: "")
        scoringItem.submenu = scoring
        file.addItem(withTitle: "Vegas Cumulative Score", action: #selector(toggleVegasCumulative), keyEquivalent: "")
        file.addItem(withTitle: "Reset Vegas Total…", action: #selector(resetVegas), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: "Left-Handed Layout", action: #selector(toggleLeftHanded), keyEquivalent: "")
        file.addItem(withTitle: "Show Time and Moves", action: #selector(toggleTimeMoves), keyEquivalent: "")
        file.addItem(withTitle: "Sound", action: #selector(toggleSound), keyEquivalent: "")

        let view = NSMenu(title: "View")  // AppKit adds "Enter Full Screen" here automatically
        let viewItem = NSMenuItem(); viewItem.submenu = view; main.addItem(viewItem)

        let windowMenu = NSMenu(title: "Window")
        let windowItem = NSMenuItem(); windowItem.submenu = windowMenu; main.addItem(windowItem)
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let s = controller.settings
        switch item.action {
        case #selector(undoMove): return controller.game.canUndo
        case #selector(autocomplete): return controller.canAutocomplete
        case #selector(toggleDrawThree): item.state = s.drawThree ? .on : .off
        case #selector(setScoring(_:)): item.state = item.tag == s.scoring.rawValue ? .on : .off
        case #selector(toggleVegasCumulative): item.state = s.vegasCumulative ? .on : .off
        case #selector(resetVegas): return s.vegasScore != 0
        case #selector(toggleLeftHanded): item.state = s.leftHanded ? .on : .off
        case #selector(toggleTimeMoves): item.state = s.showTimeAndMoves ? .on : .off
        case #selector(toggleSound): item.state = s.soundEnabled ? .on : .off
        default: break
        }
        return true
    }

    // MARK: - Actions

    @objc func newGame() { controller.newGame() }
    @objc func restartGame() { controller.restartGame() }
    @objc func undoMove() { controller.undo() }
    @objc func autocomplete() { controller.autocomplete() }

    @objc func toggleDrawThree() { controller.settings.drawThree.toggle(); noteAppliesToNextGame() }
    @objc func setScoring(_ sender: NSMenuItem) {
        controller.settings.scoring = ScoringMode(rawValue: sender.tag) ?? .standard
        noteAppliesToNextGame()
    }
    @objc func toggleVegasCumulative() { controller.settings.vegasCumulative.toggle(); table.updateLabels() }
    @objc func toggleLeftHanded() { controller.settings.leftHanded.toggle(); table.needsLayout = true }
    @objc func toggleTimeMoves() { controller.settings.showTimeAndMoves.toggle(); table.updateLabels() }
    @objc func toggleSound() { controller.settings.soundEnabled.toggle() }

    @objc func resetVegas() {
        let alert = NSAlert()
        alert.window.preventsApplicationTerminationWhenModal = false  // ⌘Q must keep working
        alert.messageText = "Reset the Vegas total?"
        alert.informativeText = "The cumulative total is \(Scoring.dollarString(controller.settings.vegasScore)). This sets it back to $0."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] r in
            if r == .alertFirstButtonReturn { self?.controller.resetVegasTotal() }
        }
    }

    /// Draw mode and scoring take effect at the next deal, as in the original. Offer to deal now.
    private func noteAppliesToNextGame() {
        let g = controller.game
        let s = controller.settings
        guard g.phase == .playing, g.scoring != s.scoring || g.drawThree != s.drawThree else { return }
        let alert = NSAlert()
        alert.window.preventsApplicationTerminationWhenModal = false  // ⌘Q must keep working
        alert.messageText = "Start a new game with these settings?"
        alert.informativeText = "The current game keeps its \(g.scoring.label) scoring and draw-\(g.drawThree ? "three" : "one") rules until you deal again."
        alert.addButton(withTitle: "New Game")
        alert.addButton(withTitle: "Keep Playing")
        alert.beginSheetModal(for: window) { [weak self] r in
            if r == .alertFirstButtonReturn { self?.controller.newGame() }
        }
    }

    private func showWinAlert() {
        let g = controller.game
        let s = controller.settings
        let alert = NSAlert()
        alert.window.preventsApplicationTerminationWhenModal = false  // ⌘Q must keep working
        alert.messageText = "You won!"
        var lines = ["Time: \(TimeFormat.string(g.elapsed))", "Moves: \(g.moves)"]
        if let score = s.scoreText(for: g) { lines.insert("Score: \(score)", at: 0) }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "New Game")
        alert.addButton(withTitle: "Close")
        alert.beginSheetModal(for: window) { [weak self] r in
            if r == .alertFirstButtonReturn { self?.controller.newGame() }
        }
    }

    private func showNoMorePasses() {
        let alert = NSAlert()
        alert.window.preventsApplicationTerminationWhenModal = false  // ⌘Q must keep working
        alert.messageText = "No more passes through the stock"
        let g = controller.game
        alert.informativeText = "Vegas scoring allows \(g.passLimit ?? 0) pass\(g.passLimit == 1 ? "" : "es") with draw \(g.drawThree ? "three" : "one")."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}
