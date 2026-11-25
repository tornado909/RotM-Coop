<div align="center">

# Revenge of the Mage · Co-op

**Explore the arenas together. Build your own mage. Revive your allies.**

[Download v0.5.9](https://github.com/tornado909/RotM-Coop/releases/tag/v0.5.9) · [Installation](#installation) · [How to play](#how-to-play) · [Русский](README.ru.md)

Windows x64 · Steam 1.0.0.301 · Experimental release

</div>

---

RotMCoop adds online cooperative play to [Revenge of the Mage](https://store.steampowered.com/app/2287150/Revenge_of_the_Mage/). Create a Steam lobby, invite friends and enter the arenas together. Steam P2P handles the connection; no port forwarding, VPN or manual IP entry is needed.

## Features

| Multiplayer | Gameplay |
| --- | --- |
| In-game lobby browser and Steam invitations | Individual spell loadouts and aiming |
| Host-controlled sessions, up to four lobby slots | Personal card choices and a shared selection pause |
| Automatic reconnection between maps | Arena gate recovery for players left behind |
| Native loading screen with connection status | Five-second ally revival with 50% health |

Two-player sessions have been tested. Four-player gameplay, every spell type and full-party defeat still need wider testing.

## Installation

**Requirements:** Windows 64-bit, a running Steam client, and game build **1.0.0.301**. All players must use the same mod version.

1. Close the game.
2. Download [RotMCoop-Win64-0.5.9-test.zip](https://github.com/tornado909/RotM-Coop/releases/download/v0.5.9/RotMCoop-Win64-0.5.9-test.zip) and extract it.
3. Run `Install-RotMCoop.cmd` from the extracted folder.
4. Select the game directory containing the `RevengeOfTheMage` folder.
5. Launch the game normally through Steam.

The installer verifies the game executable, backs up replaced files and preserves unrelated UE4SS mods. No separate launcher is needed. If the game has been updated or another UE4SS version is present, installation stops rather than silently replacing incompatible files.

## How to play

| Host | Guest |
| --- | --- |
| Open **СЕТЕВАЯ ИГРА** (Multiplayer). | Open the game with Steam online. |
| Select **СОЗДАТЬ ЛОББИ** (Create lobby). | Accept the Steam invitation or select **НАЙТИ ЛОББИ** (Find lobby). |
| Use **ПРИГЛАСИТЬ ДРУГА** (Invite friend). | Select the host's lobby and wait for the host. |
| Press **НАЧАТЬ ИГРУ** (Start game). | Enter the hub automatically when the host is ready. |

The current multiplayer menu uses Russian labels. Steam invitations may appear as **Spacewar**, because the experimental bridge uses Steamworks test AppID 480.

During a run, choose your own cards. The game resumes once all participating players have chosen. To revive a downed ally, stay inside their revival zone for five seconds.

## Compatibility and troubleshooting

- Only Steam build 1.0.0.301 is supported; other executable versions are rejected by the installer.
- The original game executable is not modified on disk. The mod uses UE4SS and version-specific in-memory patches.
- Back up your saves before testing. This is an unofficial experimental modification, not an official multiplayer mode.
- If connection fails, check that both players have the same mod version, are online in Steam, and have the game running before inviting.
- To disable the mod, close the game and set `RotMCoop : 0` in `RevengeOfTheMage/Binaries/Win64/ue4ss/Mods/mods.txt`.

For bug reports, include the game version, mod version, host/guest role, reproduction steps and relevant excerpts from `ue4ss/UE4SS.log` and `ue4ss/Mods/RotMCoop/Scripts/steam-ipc/state.txt`. Remove personal identifiers from logs before posting.

## Development

The Lua runtime lives in [mod/](mod/), the .NET Steam transport in [steam-bridge/](steam-bridge/), and regression tests in [tests/](tests/). See [architecture and build instructions](docs/ARCHITECTURE.md).

## Credits

Built for Revenge of the Mage using [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) (MIT) and the Steamworks API. Game assets and the game executable are not included. Not affiliated with the game developers or Valve.
