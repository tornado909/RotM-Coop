# Enemy replication investigation (experimental)

Native LAN test on two isolated game processes, Ghoul class, MageHub_New.
- Host spawned enemy: HP 1200; guest replica: HP 900.
- Native server KillInstantly: host HP 0, bIsDead true; guest remained HP 900, bIsDead false.
- Native actor names differ. Per-connection ActorChannel index and opening packet range match both ends (player 258, channel 6, packet 12457 in the final probe).
- Death tears off the actor channel; cache identity before death.
- A diagnostic file exchange (not Steam) using the cached identity updated guest HP to 1200, then HP 0 and bIsDead true; Die_BP and collision disable completed without a Lua exception.
- C# transport and Lua parser regression tests passed. Full Steam delivery, graphical death, targeting, channel reuse and wave/pool behavior have not passed integration QA.

The candidate is disabled by default (experimental_enemy_sync = false). Do not advertise as a released fix or enable in an ongoing run.
