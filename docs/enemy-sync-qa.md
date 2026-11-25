# Enemy replication investigation (experimental)

Native LAN test on two isolated game processes, Ghoul class, MageHub_New.
- Host spawned enemy: HP 1200; guest replica: HP 900.
- Native server KillInstantly: host HP 0, bIsDead true; guest remained HP 900, bIsDead false.
- Native actor names differ. Per-connection ActorChannel index and opening packet range match both ends (player 258, channel 6, packet 12457 in the final probe).
- Death tears off the actor channel; cache identity before death.
- A diagnostic file exchange (not Steam) using the cached identity updated guest HP to 1200, then HP 0 and bIsDead true; Die_BP and collision disable completed without a Lua exception.
- C# transport and Lua parser regression tests passed.
- Integrated native game + real bridge + local mock Steam API: 52388f9eb691406ab340db652224f5ca confirmed one enemy at 1200 HP, then 0 HP, dead flag and disabled collision on guest.
- Multi-actor integration: 1d52e38098924be6b9e0b630197e017c. Two enemies at 1200 HP, one reduced to 500 HP, then both killed independently. Both guest replicas reached 0 HP with disabled collision; replacement enemy remained alive at 1200 HP.
- Terminal snapshots retained across channel reuse; guest rejects a prior actor lifetime if the same object path now has a different live channel identity.
- Native target cleanup added when the client's detector references a dead enemy; general target selection, large waves/pool reuse and visual death animation are not yet proven.
- Steam API mock transport tested authority rejection, stale snapshots, reconnect and lobby transitions. Real Valve relay and physical input are not covered by this stand.

The candidate is disabled by default (experimental_enemy_sync = false). Do not advertise as a released fix or enable in an ongoing run.
