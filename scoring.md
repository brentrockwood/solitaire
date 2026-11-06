# Solitaire Epic 1.8.0 — Klondike scoring, recovered from the binary

Source: `GameAssembly.dylib` (x86_64 slice) plus `global-metadata.dat` from
`/Applications/Solitaire Epic.app`, bundle `com.kristanix.mac.solitaireepic2`.
Every rule below was read from disassembly; function names come from the IL2CPP
metadata. Addresses are x86_64 slice offsets. Tooling lives in `tools/il2cpp/`.

## Scoring modes

Setting `scoring` cycles None → Standard → Vegas (`OptionsBehaviour.ChangeScoring`,
values 0, 1, 2; labels `OPTION SCORING NONE/STANDARD/VEGAS`). The board copies the
setting into `currentScoring` only when a deal starts (`Board.ResetGame`, 0x202b90),
so changing the option mid-game does not affect the game in progress.

- **None** (0): scored internally exactly like Standard, but the score label is hidden
  (`Admin.SetupOptions`, `OptionsBehaviour.OnHide`, `FinishedBehaviour.Show`), and no
  best score is recorded at the end (`GoalManager.SetCompletedGame`).
- **Standard** (1): points below, starting at 0.
- **Vegas** (2): dollars below, starting at −52.

Every code path tests only `currentScoring == 2`; "not Vegas" means Standard values.

## Point values

| Event | Standard | Vegas | Where |
|---|---|---|---|
| Card moved onto a foundation (from waste or tableau) | +10 | +5 | `Card.DoMoveToFoundation` 0x1ff670 |
| Card moved from waste to tableau (onto a card or an empty column) | +5 | 0 | `Card.DoMoveToTableauTop` 0x1ff980, `Card.DoMoveToCard` 0x1ffcb0 |
| Card moved from foundation back to tableau | −15 | −5 | `Card.DoMoveToCard` 0x1ffcb0 |
| Face-down tableau card turned over because the card above it moved away | +5 | 0 | `Card.SetParentOpened` 0x2130c0 |
| Tableau to tableau move | 0 | 0 | |
| Drawing from the stock | 0 | 0 | `Stock.NextCard` 0x27ffd0 |
| Recycling the waste back into the stock | 0 | 0 | `Stock.NextCard` |
| Elapsed time | 0 | 0 | `Board.UpdatePlaying` 0x20e8e0 only updates the clock |
| Finishing the game | 0 | 0 | `Board.FinishedGame` 0x20a610 adds nothing |
| New deal (Vegas buy-in) | start 0 | start −52 | `Board.ResetGame` 0x202fb0 |

Notes:
- Moving a card that is already on a foundation to another foundation scores 0.
- The reveal bonus is awarded by `Card.SetParentOpened`, which is reached from
  `Card.MovedCard` after any move that exposes a face-down card. It is a separate
  score increment from the move itself.
- Autocomplete moves cards through `Card.DoMoveToFoundation`
  (`<ThreadAutocompleteCard>d__47.MoveNext`), so it scores like manual moves.
- Hints only highlight cards; they never change the score. A tap on a card
  (`Card.OnPointerClick`) performs the first hint move for that card and scores normally.
- There is no time penalty, no time bonus, and no penalty for passing through the
  stock. Windows-style rules for those do not exist in this game.

## Stock passes

`Stock.CanResetStock` 0x27fe60 decides whether the waste may be recycled:

| Mode | Draw 1 | Draw 3 |
|---|---|---|
| None / Standard | unlimited | unlimited |
| Vegas | 1 pass, no recycle | 3 passes (recycle allowed while `numStockPasses <= 1`) |

When no more passes are allowed, clicking the stock shows a message box
(`STOCK VEGAS END`) instead of recycling. `numStockPasses` counts completed
recycles and is decremented again when a recycle is undone (`Stock.UndoCard`).

## Vegas cumulative

Setting `vegasCumulative` (bool) with running total `vegasScore` (saved as
`s.o.vegasScore`):

- Displayed score in Vegas is `numScore + vegasScore` when cumulative is on
  (`Board.SetScoreText` 0x1f9c30). The in-game score itself still starts at −52.
- `vegasScore += numScore` when a Vegas game is completed
  (`GoalManager.SetCompletedGame` 0x233a60, only if `currentScoring == 2` and
  cumulative is on).
- `vegasScore += numScore` when a Vegas game in progress (board state PLAYING) is
  abandoned by starting a new deal (`Board.IncreaseNewDealStats` 0x205e70).
- Reset: options button → Yes/No message box (`RESET VEGAS MESSAGE`) → on Yes,
  `vegasScore = 0` and save (`OptionsBehaviour.MessageBoxResetVegasReply`).
- Turning the cumulative option off just stops adding; the stored total is kept.

## Undo

`UndoSystem.AddUndo` records `UNDO_TYPE` {NONE, CARD, TABLEAU, FOUNDATION, STOCK,
DREW_1, DREW_3}, the source card, the card it came from, an index, the score delta
of the move, and whether the source's parent was face up.

- A card move's recorded delta is move points plus the reveal bonus (the handlers
  pass `move + reveal` to `AddCardUndo`).
- `UndoSystem.Undo` 0x282da0 reverses the move, re-closes a card that was revealed,
  then calls `IncreaseScore(-delta)`. So undo subtracts exactly what was scored.
- Stock draws and recycles record a delta of 0; undoing a recycle also decrements
  `numStockPasses`.
- Undo counts as a move (`IncreaseMoves` is called on every undo). The stats
  counter `HintsUsed`/undo counter is incremented too (not needed for a clone).
- Undo is blocked while a card is flying, while autocompleting, and after the game
  is completed.

## Moves and time

- `numMoves` increments on every card move (`Card.MovedCard`), every stock click
  including recycles (`Stock.NextCard`), and every undo.
- The clock (`boardTime`, float seconds) runs while board state is PLAYING and the
  main menu panel is not showing. It starts on the first undoable action
  (`UndoSystem.AddUndo` sets `startedTime = true`). Display is `m:ss`
  (`FinishedBehaviour.Show` divides by 60).

## Display

- Standard: `"Score: " + numScore` via text key `score`.
- Vegas: `Board.GetDollarString(n)` formats `{0}${1}` with `{0}` = `"-"` when n < 0
  else `""`, and `{1}` = |n|. Examples: `-$52`, `$0`, `$13`.

## Best-score bookkeeping (stats only, not required)

`GoalManager.SetCompletedGame`: `BestStandardScore` updated only when
`currentScoring == 1`; `BestVegasScore` when `== 2`. `Board.IncreaseScore` also
raises `BestVegasScore` live using `numScore + vegasScore`.
