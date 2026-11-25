<div align="center">

# Revenge of the Mage · Co-op

**Online co-op for Revenge of the Mage**

[Download v0.6.2](https://github.com/tornado909/RotM-Coop/releases/download/v0.6.2/RotMCoop-Win64-0.6.2-test.zip) · [Releases](https://github.com/tornado909/RotM-Coop/releases) · [Русский](README.ru.md)

Windows x64 · Steam game build 1.0.0.301 · Experimental pre-release

</div>

> **Known regressions in 0.6.2:** repeated card drafts, stuck primary attacks, duplicate host HUD and guest enemy death presentation. Main contains a native draft-close fix verified in three consecutive rounds across two local game instances; primary release and HUD changes still need graphical gameplay verification. Enemy death and host reconnect remain open. No replacement release yet.


RotMCoop adds online co-op to [Revenge of the Mage](https://store.steampowered.com/app/2287150/Revenge_of_the_Mage/). Create an in-game Steam lobby, invite friends and play with separate characters and spell loadouts. Steam P2P handles the connection; manual IP entry, port forwarding and VPN are not required for the Steam mode.

## Features

| Multiplayer | Gameplay |
| --- | --- |
| Steam lobby browser and friend invitations | Individual mage schools, spells and card choices |
| Up to four lobby slots | Simultaneous combat and native automatic/manual reload |
| Connection status and automatic reconnect attempts | Server-authoritative ammo, aim and spell effects |
| Native co-op menu in 14 languages | Ally models, school colors and through-wall outlines |
| Shared pause during card selection | Ally HUD with health, armor, spell charges and cooldowns |
| Arena travel and gate recovery | Five-second ally revival with 50% health |

These features are implemented, but not all have completed end-to-end gameplay validation.

## What's new in 0.6.0

- Per-player animation event isolation fixes the shared primary-attack stall observed in Fire/Fire testing.
- Native reload and server-authoritative ammo synchronization replace artificial refill behavior.
- Improved vertical aiming and spell effect synchronization, including LavaLeap targeting and landing.
- Native ally HUD, spell icons, charges and cooldowns.
- Localized multiplayer controls, loading and party status.
- Combat transport v2. **0.5.9 and 0.6.0 cannot join each other's lobbies.**

## Installation

Requirements: Windows x64, Steam running and the exact game build **1.0.0.301**. Every participant must install the same mod version.

1. Close the game.
2. Download and extract [RotMCoop-Win64-0.6.2-test.zip](https://github.com/tornado909/RotM-Coop/releases/download/v0.6.2/RotMCoop-Win64-0.6.2-test.zip).
3. Run `Install-RotMCoop.cmd` and select the game root containing the `RevengeOfTheMage` subfolder.
4. Launch Revenge of the Mage normally through Steam.

The installer checks the executable hash, backs up replaced files, preserves existing mod configuration and unrelated UE4SS mods, and rejects incompatible loader files by default. No separate launcher is required. [SHA-256 checksums](https://github.com/tornado909/RotM-Coop/releases/download/v0.6.2/SHA256SUMS.txt) are available.

## How to play

| Host | Guest |
| --- | --- |
| Open **CO-OP → CREATE LOBBY**. | Open the game with Steam online. |
| Select **INVITE FRIEND**, then invite a player from the list. | Accept the invitation or select **CO-OP → FIND LOBBY**. |
| Press **START GAME**. | Join the room and wait for the host to enter the hub. |

Menu text follows the game's language (English fallback). The 14 supported languages are English, Arabic, German, Spanish, French, Japanese, Korean, Polish, Brazilian and European Portuguese, Russian, Turkish, Simplified and Traditional Chinese.

Invitations may appear as **Spacewar** because the experimental Steam bridge uses AppID 480. Keep the game running when accepting an invitation. During a run, choose your own upgrade cards; the party resumes after the participating players finish choosing. To revive an ally, stay in their revival zone for five seconds.

## Test status and known limitations

| Test | Status |
| --- | --- |
| Steam connection between two PCs and hub entry | Passed |
| Simultaneous Fire primary attacks | Passed: 313 seconds, 38 host and 53 guest reloads |
| Positive/negative vertical aim | Verified in diagnostic projectile traces |
| Fire/Ice simultaneous primary and reload | Passed in subsequent hub QA |
| All six school loadouts | Granted in subsequent hub QA; not all spells validated |
| Lua regression tests | 17/17 passed |
| Four-player transport | Automated test passed; four-player gameplay not certified |
| Full run, normal portal, all spells, overlapping effects, damage ownership and revival | Full acceptance pending |

The subsequent six-school diagnostic tests did not confirm sustained primary attacks for every school. In particular LightningStrike, ArcaneMissiles and ArcOfDarkness did not show activation or ammo expenditure during held input in the empty hub. Blood primary sustained behavior also needs validation. These are unresolved test results, not proof that the spells fail in every arena.

This is an experimental mod, not a stable release. Back up saves. The two-PC combat tests used diagnostic native ability input, not a complete manual playthrough.

## Troubleshooting

- Check the game build, mod version and Steam connectivity on every PC.
- Use the in-game invitation button rather than relying on the Steam overlay.
- To disable the mod, close the game and set `RotMCoop : 0` in `RevengeOfTheMage/Binaries/Win64/ue4ss/Mods/mods.txt`.
- For a [bug report](https://github.com/tornado909/RotM-Coop/issues), include host/guest role, mage school, ability, reproduction steps and relevant excerpts from `ue4ss/UE4SS.log` and `ue4ss/Mods/RotMCoop/Scripts/steam-ipc/state.txt`. Remove personal identifiers before sharing.

## Development

[Lua runtime](mod/) · [Steam bridge](steam-bridge/) · [Tests](tests/) · [Architecture](docs/ARCHITECTURE.md) · [Build workflow](.github/workflows/release-060.yml)

Built with [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) and Steamworks. No game assets or game executable are distributed. Unofficial; not affiliated with the game developers or Valve.
