## Hotfix

- Adds a null-dependency guard for the native EnemyDetectionComponent deactivation path during guest join. Two 0.6.0 crash dumps confirmed the same null-pointer dereference.
- Includes the 0.6.0 combat and HUD changes.

**Test pre-release:** build and automated transport checks passed; the fix has not yet been verified by a successful real two-PC join. Do not treat this as a stable release.

## Installation

Close the game, extract the ZIP, run Install-RotMCoop.cmd, and select the game root. Windows x64; exact Steam game build 1.0.0.301. Install the same version on all players.
