"""Isolated two-process LAN/loopback diagnostic for Revenge of the Mage Co-op."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
GAME_SUBPATH = Path("RevengeOfTheMage/Binaries/Win64")
EXE = "RevengeOfTheMage-Win64-Shipping.exe"
EXPECTED_SHA256 = "98c8eb1d3474883d826d24fc67a49310425d5e42099af120d5326a0de09c8682"
LOADER_FILES = ("UE4SS.dll", "UE4SS-settings.ini")


def verify_game(game_root):
    if os.name != "nt":
        raise RuntimeError("The game must be tested on Windows")
    game_root = game_root.resolve(strict=True)
    # Never point the automated runner at an installed/user-played game.
    if not game_root.is_relative_to((ROOT / "lab").resolve()):
        raise ValueError("Only a copy under the repository's lab directory is permitted")
    binary = game_root / GAME_SUBPATH / EXE
    hasher = hashlib.sha256()
    with binary.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            hasher.update(chunk)
    sha = hasher.hexdigest()
    if sha != EXPECTED_SHA256:
        raise ValueError("Game EXE hash mismatch")
    return binary


def prepare_client(game_bin, evidence, role, port, guest_candidate=None, guest_start_hub=False, host_candidate=None, steam_ui_smoke=False, steam_menu_only=False, headless=False):
    root = evidence / role
    profile = root / "profile"
    loader = root / "ue4ss"
    mods = loader / "Mods"
    profile.mkdir(parents=True)
    mods.mkdir(parents=True)

    base = game_bin / "ue4ss"
    for filename in LOADER_FILES:
        shutil.copyfile(base / filename, loader / filename)
    shutil.copytree(base / "Mods" / "shared", mods / "shared")
    shutil.copytree(ROOT / "mod" / "RotMCoop", mods / "RotMCoop")
    order = ["RotMCoop : 1"]
    if role == "host":
        host_state = mods / "RotMHostStateQA" / "Scripts"
        host_state.mkdir(parents=True)
        shutil.copyfile(ROOT / "tests" / "HostPlayerStateProbe.lua", host_state / "main.lua")
        order.insert(0, "RotMHostStateQA : 1")
    if role == "join" and guest_candidate:
        guest_mod = mods / "RotMGuestQA" / "Scripts"
        guest_mod.mkdir(parents=True)
        (guest_mod / "main.lua").write_text("package.path=" + json.dumps((mods / "RotMCoop" / "Scripts" / "?.lua").as_posix() + ";", ensure_ascii=False) + "..package.path\n" + guest_candidate.read_text(encoding="utf-8"), encoding="utf-8")
        order.insert(0, "RotMGuestQA : 1")
    if role == "host" and host_candidate:
        host_mod = mods / "RotMHostQA" / "Scripts"
        host_mod.mkdir(parents=True)
        (host_mod / "main.lua").write_text("package.path=" + json.dumps((mods / "RotMCoop" / "Scripts" / "?.lua").as_posix() + ";", ensure_ascii=False) + "..package.path\n" + host_candidate.read_text(encoding="utf-8"), encoding="utf-8")
        order.insert(0, "RotMHostQA : 1")
    if role == "join" and steam_ui_smoke:
        publish = ROOT / "lab" / "steam-bridge-publish"
        scripts = mods / "RotMCoop" / "Scripts"
        for filename in ("RotMSteamBridge.exe", "steam_api64.dll", "steam_appid.txt"):
            shutil.copyfile(publish / filename, scripts / filename)
    (mods / "mods.txt").write_text("\n".join(order) + "\n", encoding="utf-8")

    config = mods / "RotMCoop" / "Scripts" / "config.lua"
    source = config.read_text(encoding="utf-8")
    values = {
        'join_address = "127.0.0.1:7777"': f'join_address = "127.0.0.1:{port}"',
        "auto_action = nil": 'auto_action = nil' if (role == "join" and steam_menu_only) else f'auto_action = "{role}"',
        "steam_lobbies_enabled = true": "steam_lobbies_enabled = true" if (role == "join" and steam_ui_smoke) else "steam_lobbies_enabled = false",
        "steam_ui_qa = false": "steam_ui_qa = true" if (role == "join" and steam_ui_smoke) else "steam_ui_qa = false",
        "auto_delay_ms = 8000": f'auto_delay_ms = {8000 if role == "host" else 18000}',
    }
    for old, new in values.items():
        if source.count(old) != 1:
            raise ValueError(f"Missing unique config marker for {role}: {old}")
        source = source.replace(old, new)
    config.write_text(source, encoding="utf-8")

    command = [
        str(game_bin / EXE),
        "-nosteam", *(["-nullrhi", "-nosound"] if headless else ["-dx11", "-windowed", "-ResX=640", "-ResY=480"]),
        "-NoSplash", "-Multiprocess", "-unattended", "-nocrashreports", "-log",
        f"-port={port}", "--ue4ss-path", str(loader / "UE4SS.dll"),
    ]
    if role == "join" and guest_start_hub:
        command.insert(1, "/Game/Arenas/MageHub_New/MageHub_New")
    cmdline = subprocess.list2cmdline(command) + f' -userdir="{profile}"'
    startup = subprocess.STARTUPINFO()
    startup.dwFlags = subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = subprocess.SW_HIDE
    env = os.environ.copy()
    env.pop("UE4SS_MODS_PATHS", None)
    proc = subprocess.Popen(
        cmdline, executable=game_bin / EXE, cwd=game_bin,
        env=env, startupinfo=startup
    )
    return proc, root


def capture(root):
    loader_log = root / "ue4ss" / "UE4SS.log"
    events = []
    if loader_log.is_file():
        for line in loader_log.read_text(encoding="utf-8", errors="replace").splitlines():
            if "[RotMCoop]" in line:
                events.append(line.split("[RotMCoop]", 1)[1].strip())
            elif "[RotMHostTrace]" in line:
                events.append("HOST_TRACE " + line.split("[RotMHostTrace]", 1)[1].strip())
    crashes = list((root / "profile").rglob("CrashContext.runtime-xml"))
    return events, crashes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("isolated_game_root", type=Path)
    parser.add_argument("--port", type=int, default=17777)
    parser.add_argument("--timeout", type=int, default=68)
    parser.add_argument("--guest-candidate", type=Path, help="Optional isolated guest-only UE4SS diagnostic")
    parser.add_argument("--guest-start-hub", action="store_true", help="Start guest in standalone Mage Hub before joining")
    parser.add_argument("--host-candidate", type=Path, help="Optional isolated host-only UE4SS diagnostic")
    parser.add_argument("--guest-native-launcher", type=Path, help="Compiled launcher executable that patches the isolated guest")
    parser.add_argument("--steam-ui-smoke", action="store_true", help="Enable Steam AppID 480 UMG and bridge in isolated guest")
    parser.add_argument("--steam-menu-only", action="store_true", help="Do not automatically join when running Steam UMG smoke")
    parser.add_argument("--skip-host", action="store_true", help="Only launch the isolated guest for UI host-lobby smoke tests")
    parser.add_argument("--headless", action="store_true")
    parser.add_argument("--host-native-guard", type=Path, help="Install production party UI guard on isolated host for native draft regression")
    args = parser.parse_args()
    if not (1024 <= args.port <= 65535 and 40 <= args.timeout <= 110):
        parser.error("Port must be 1024-65535 and timeout 40-110 seconds")

    processes = []
    roots = {}
    try:
        exe = verify_game(args.isolated_game_root)
        game_bin = exe.parent
        evidence = ROOT / "lab" / "network-join" / uuid.uuid4().hex
        evidence.mkdir(parents=True)
        print(f"Evidence: {evidence}", flush=True)

        host = None
        if not args.skip_host:
            host, roots["host"] = prepare_client(game_bin, evidence, "host", args.port, host_candidate=args.host_candidate, headless=args.headless)
            processes.append(host)
            print(f"Host PID: {host.pid}", flush=True)
            time.sleep(10)
            if host.poll() is not None:
                raise RuntimeError(f"Host exited before guest startup: {host.returncode}")
            if args.host_native_guard:
                subprocess.run([str(args.host_native_guard.resolve(strict=True)), "--qa-party-guard", str(host.pid), str(exe)], check=True, timeout=18)

        guest, roots["join"] = prepare_client(game_bin, evidence, "join", args.port, args.guest_candidate, args.guest_start_hub, steam_ui_smoke=args.steam_ui_smoke, steam_menu_only=args.steam_menu_only, headless=args.headless)
        processes.append(guest)
        print(f"Guest PID: {guest.pid}", flush=True)
        if args.guest_native_launcher:
            native_exe = args.guest_native_launcher.resolve(strict=True)
            result = subprocess.run(
                [str(native_exe), "--apply-guard", str(guest.pid), str(exe)],
                capture_output=True, text=True, timeout=18
            )
            if result.returncode != 0:
                raise RuntimeError(f"Compiled launcher guard failed ({result.returncode}): {result.stderr}")
            print("COMPILED_LAUNCHER_GUARDS_OK", flush=True)

        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            if host is not None and host.poll() is not None:
                print("Host stopped during join", flush=True)
                break
            if guest.poll() is not None:
                print("Guest stopped; waiting 10 seconds for server diagnostics", flush=True)
                time.sleep(10)
                break
            time.sleep(2)
    except Exception as error:
        print(f"ERROR: {type(error).__name__}: {error}", flush=True)
    finally:
        for proc in processes:
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=12)

    for role, path in roots.items():
        events, crashes = capture(path)
        print(f"=== {role.upper()} EVENTS ({len(events)}) CRASHES ({len(crashes)}) ===")
        for event in events[-65:]:
            print(event)
        for crash in crashes:
            print("CRASH_CONTEXT:", crash)
    host_events, host_crashes = capture(roots["host"]) if "host" in roots else ([], [])
    guest_events, guest_crashes = capture(roots["join"]) if "join" in roots else ([], [])
    server = any("net mode: server" in e for e in host_events)
    two_players = any("player states: 2" in e for e in host_events)
    transient_two_players = any("HOST_TRACE playerStates=2" in e or
                                "HOST_TRACE playerStates=3" in e or
                                "HOST_TRACE playerStates=4" in e for e in host_events)
    two_players = two_players or transient_two_players
    guest_client = any("net mode: client" in e for e in guest_events)
    # The 2/10/30s snapshots can miss a late successful possession.
    # The persistent Lua watchdog emits this event only after verifying a
    # valid local RM_MageBase pawn *and* local PlayerState in a network arena.
    guest_pawn = any(
        "guest readiness: local pawn possessed" in e
        or "Client is connected to an arena" in e
        for e in guest_events
    )
    success = server and two_players and guest_client and guest_pawn and not host_crashes and not guest_crashes
    print(f"STATUS: {'PASS' if success else 'INCOMPLETE'} host_server={server} two_player_states={two_players} transient_two_player_states={transient_two_players} guest_client={guest_client} guest_pawn={guest_pawn} host_crashes={len(host_crashes)} guest_crashes={len(guest_crashes)}")
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
