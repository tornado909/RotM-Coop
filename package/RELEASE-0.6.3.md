## Changes

- Fixes the native remote draft-close latch that prevented subsequent card offers. Three consecutive rounds with six successful choices verified in two isolated game instances over LAN.
- Adds targeted recovery for a primary ability that remains active after release, without cancelling another player's ability.
- Replaces cloned gameplay Blueprint widgets in the ally HUD with passive UMG elements. The host's native HUD is no longer modified by the vitality synchronization routine.

**Experimental pre-release.** All 18 Lua regression tests and four-player transport test passed locally. Physical mouse release and graphical HUD fixes still require end-to-end verification. Guest enemy death/targeting and host reconnect crash remain unresolved.

Install on all PCs: close the game, extract ZIP, run Install-RotMCoop.cmd and select the game root. Windows x64, Steam game build 1.0.0.301.
