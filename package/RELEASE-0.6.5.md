## Changes

- Gate recovery uses the observed crossing direction. Only the lagging player is moved inside; ambiguous crossings are ignored.
- Local cinematic guard prevents remote mages from restarting the host intro. Camera recovery is limited to the locally controlled pawn after the sequence.
- Disable the guest-only duplicate training mummy in Mage Hub; keep the host replica. Enemy deaths remain host-owned; the client hides dead actors instead of spawning a second death effect.
- Projectile interpolation at 16 ms, velocity prediction limited to 100 ms; reduced unchanged enemy snapshot traffic.

## Verification

20 Lua regression files and CombatTransport tests passed. Two isolated game instances verified gate recovery on Pyramid, one intro completion per player and correct camera target. A separate hub retest verified that only the local dummy becomes hidden and non-collidable. Full live Steam run, later gates, raw mouse input and rendered projectile/death effects remain unverified.

Install the same version on all PCs. Windows x64, game build 1.0.0.301. Experimental pre-release.
