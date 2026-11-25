# Architecture

RotMCoop targets Windows x64, Unreal Engine 5.8 and game build 1.0.0.301. The original executable remains unchanged on disk.

## Runtime

- UE4SS Lua integrates Steam lobby controls into the native game menu, coordinates travel, guest possession, loadouts, card selection and revival.
- The host is an Unreal listen server. The bridge discovers its actual owned UDP listener before announcing readiness.
- Steam lobby membership and a verified P2P handshake establish the transport. Local UDP proxies bridge Unreal traffic to Steam; fragmented datagrams are bounded and paced.
- Map epochs distinguish reconnects from earlier sessions. The host publishes party drafts and downed state; card choices and revival are applied authoritatively.
- Native guards verify the executable SHA-256 and expected instruction bytes before patching memory. Startup polling waits for a stable local controller; party guards are installed at lobby entry.

## Build

Use Windows x64 with the .NET 10 SDK and Lua 5.4 available.

```powershell
dotnet publish steam-bridge/RotMSteamBridge.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=None -p:DebugSymbols=false -o out/bridge
```

The release also includes UE4SS v4.0.0 and the Steamworks redistributable. Their files and the installer are arranged in the release archive; the proprietary game executable is not part of the repository. The loader's license is included in the archive.

## Tests

```powershell
Get-ChildItem tests/Test-*.lua | ForEach-Object { lua $_.FullName }
powershell -ExecutionPolicy Bypass -File tests/Test-Project.ps1
```

The Python and mock-Steam integration tests under `tests/` are development fixtures. Run real-game tests only against a separate test installation.
