# Solitaire

A small native macOS Klondike solitaire, built to replace Solitaire Epic with the same
scoring rules and none of the extras. AppKit and Core Animation only: it launches in
well under a second, uses no CPU while idle, and never interferes with sleep or the
screensaver. Window management, full screen, and quitting are the standard macOS ones.

## Build

Requires Xcode (the command line tools alone cannot run the tests).

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
make app        # release build → build/Solitaire.app
make run        # build and launch
make test       # unit tests
make install    # copy to /Applications
```

## Playing

- Click the stock to draw. Click it when empty to recycle the waste.
- Drag cards, or single-click a card to send it to the first place it fits
  (foundation first, then a tableau column).
- Game menu: New Game (⌘N), Restart This Game (⌘R), Undo Move (⌘Z), Autocomplete (⌘A).
- Options live in the Game menu: Draw Three, Scoring (None / Standard / Vegas),
  Vegas Cumulative Score and its reset, Left-Handed Layout, Show Time and Moves, Sound.
  Draw mode and scoring take effect at the next deal, as in the original.
- The game in progress is saved and resumed on relaunch.

## Scoring

Exactly as recovered from Solitaire Epic; see `scoring.md`. In short: Standard gives
+10 to a foundation, +5 waste to tableau, +5 for turning a card over, −15 foundation
back to tableau, no time or pass penalties. Vegas starts at −$52, +$5 per card to a
foundation, −$5 back, one pass with draw one and three with draw three.

## Layout

- `Sources/SolitaireCore` — the engine: cards, rules, scoring, undo, autocomplete,
  save state. Pure Swift, fully unit-tested (`Tests/SolitaireCoreTests`).
- `Sources/Solitaire` — the app: card art drawn in code (`CardRenderer`), the table
  (`TableView`, one `CALayer` per card), controller, menus, procedural sounds, icon.

Hidden flags for checking the table without a human: `--screenshot out.png` renders
the window to a file and quits.
