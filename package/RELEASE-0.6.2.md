## Regression hotfix candidate

- Prevents pausing before delayed native card offers are ready; separates unavailable offers from completed choices, retries publication, resolves current pawn components, and restores game-only input after card selection.
- Reconciles primary mouse release and suppresses combat input while paused or using the card UI.
- Restores mouse capture after guest travel; separates overlapping HUD value labels and leaves host native health values to the game.
- Includes the guest join null-dependency guard from 0.6.1.

18 Lua regression tests passed locally, including two consecutive simulated card rounds. **Real two-player verification is pending.** The reported host crash on reconnect has not been diagnosed because the host dump is unavailable. This is an experimental pre-release, not a stable build. The primary input reconciliation uses the default left-mouse binding; remapped controls are not verified.

Install the same version on all PCs. Close the game, extract the ZIP and run Install-RotMCoop.cmd. Windows x64, Steam game build 1.0.0.301.
