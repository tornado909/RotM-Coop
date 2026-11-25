# 0.6.5 gate, sequence and enemy regression QA

- Real game executables in an isolated two-instance mock Steam session, Pyramid arena: host crossed gate X=19152 to X=18752, guest outside at X=19752 was moved to X=18592. Host remained at X=18752. The guest received the new position. Both local sequences finished once; both view targets were their own pawns, camera Z=266 at pawn Z=190. Evidence lab/network-join/7cfc685bb0ca4998ba9662d5a1a14608.
- Hub test reproduced a role-1 replicated mummy and a role-3 locally spawned mummy in the same location. Suppression restricted to the exact hub dummy class and guest authority role; the server replica remains visible/collidable. First suppression test showed hidden=true and coll=false for the local duplicate; an unavailable SetCanBeDamaged method was subsequently replaced with a guarded property assignment.
- Enemy death is host-owned; client hides dead actor rather than invoking Die_BP again. Native death animation is not guaranteed. Stable enemy snapshot batches refresh at one second; changed batches remain on the existing fast path.
- Projectile position prediction bounded to 100 ms using actual projectile velocity, client interpolation at 16 ms. Visual smoothness has not been measured in a live rendered Steam fight.
- 20 Lua test files and CombatTransport tests passed; Steam bridge compiled. Gate tests cover both directions and ambiguity rejection.
- Full live Steam run, physical mouse movement, subsequent arena gates and rendered projectile/death presentation remain unverified. Do not treat this as a fully validated release.
