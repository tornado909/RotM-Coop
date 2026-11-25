import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid
from xml.etree import ElementTree

PROJECT = Path(__file__).resolve().parents[1]
GAME_BIN = Path("RevengeOfTheMage/Binaries/Win64")
GAME_EXE = "RevengeOfTheMage-Win64-Shipping.exe"
GAME_SHA256 = "98c8eb1d3474883d826d24fc67a49310425d5e42099af120d5326a0de09c8682"
MAGE_HUB = "/Game/Arenas/MageHub_New/MageHub_New"
KNOWN_STACK = "9CD851E63FB152E93920CDD07F96427BA3044D64"
KNOWN_ERROR = "EXCEPTION_ACCESS_VIOLATION reading address 0x00000000000007f4"


def classify(events, crashes, exit_code, timed_out):
    if crashes:
        if "CREATE controller_id=1" in events and (KNOWN_STACK, KNOWN_ERROR) in crashes:
            return "FAIL", "Reproduced the second-player native crash (read at 0x7f4)."
        return "FAIL", "Unreal wrote a crash context during the run."
    for event in events:
        if event.startswith("RESULT FAIL:"):
            return "FAIL", event.removeprefix("RESULT FAIL:").strip()
    if timed_out:
        return "TIMEOUT", "The game did not complete and exit before the deadline."
    if exit_code != 0:
        return "FAIL", f"The game exited with code {exit_code}."
    ready = any(event.startswith("READY local_controllers=1 ") for event in events)
    samples = sum(event.startswith("PLAYERS local_controllers=2 ") for event in events)
    if ready and "CREATE controller_id=1" in events and samples >= 3 and "RESULT PASS" in events:
        return "PASS", "Two distinct local mage pawns remained possessed across three samples."
    return "FAIL", "The probe exited without complete possession evidence."


def crash_contexts(profile):
    for path in profile.rglob("CrashContext.runtime-xml"):
        try:
            runtime = ElementTree.parse(path).getroot().find("RuntimeProperties")
        except ElementTree.ParseError:
            yield "", ""
            continue
        if runtime is None:
            yield "", ""
            continue
        error = runtime.findtext("ErrorMessage", "").strip().removeprefix("Unhandled Exception: ")
        yield runtime.findtext("PCallStackHash", "").strip(), error


def run(args):
    if os.name != "nt":
        raise RuntimeError("The probe requires a Windows game runtime.")
    if args.isolated_game_root is None:
        raise ValueError("An isolated game root is required.")
    game_bin = args.isolated_game_root.resolve(strict=True) / GAME_BIN
    exe = game_bin / GAME_EXE
    with exe.open("rb") as binary:
        sha256 = hashlib.sha256()
        while chunk := binary.read(1024 * 1024):
            sha256.update(chunk)
    if sha256.hexdigest() != GAME_SHA256:
        raise ValueError("The game executable does not match Steam 1.0.0.301.")

    token = uuid.uuid4().hex
    output = PROJECT / "lab" / "local-players" / token
    profile = output / "profile"
    loader = output / "ue4ss"
    mods = loader / "Mods"
    probe = mods / "RotMCoopLocalQA" / "Scripts"
    profile.mkdir(parents=True)
    probe.mkdir(parents=True)

    installed_loader = game_bin / "ue4ss"
    for filename in ("UE4SS.dll", "UE4SS-settings.ini"):
        shutil.copyfile(installed_loader / filename, loader / filename)
    shutil.copytree(installed_loader / "Mods" / "shared", mods / "shared")
    mod_order = ["RotMCoopLocalQA : 1\n"]
    if args.candidate_lua:
        candidate = mods / "RotMCoopLocalCandidate" / "Scripts"
        candidate.mkdir(parents=True)
        shutil.copyfile(args.candidate_lua, candidate / "main.lua")
        mod_order.insert(0, "RotMCoopLocalCandidate : 1\n")
    (mods / "mods.txt").write_text("".join(mod_order), encoding="ascii")
    fixture = Path(__file__).with_name("local-players-probe.lua").read_text(encoding="utf-8")
    fixture = fixture.replace("@RUN_TOKEN@", token).replace(
        "@LAUNCH_MAP@", "true" if args.start == "launch" else "false"
    )
    (probe / "main.lua").write_text(fixture, encoding="utf-8")

    environment = os.environ.copy()
    environment.pop("UE4SS_MODS_PATHS", None)
    if args.additional_mods:
        additional_mods = args.additional_mods.resolve(strict=True)
        if not additional_mods.is_dir():
            raise ValueError("The additional mods path must be a directory.")
        environment["UE4SS_MODS_PATHS"] = str(additional_mods)
    variant = args.label or ("candidate" if args.additional_mods or args.candidate_lua else "baseline")
    print(f"Variant: {variant} | map start: {args.start}\nEvidence: {output}", flush=True)

    command = [str(exe)]
    if args.start == "launch":
        command.append(MAGE_HUB)
    command.extend(
        (
            "-nosteam", "-dx11", "-windowed", "-ResX=640", "-ResY=480", "-NoSplash",
            "-Multiprocess", "-unattended", "-nocrashreports", "-log",
            "--ue4ss-path", str(loader / "UE4SS.dll"),
        )
    )
    # Unreal's parser expects quotes around the value after the equals sign.
    command_line = subprocess.list2cmdline(command) + f' -userdir="{profile}"'
    startup = subprocess.STARTUPINFO()
    startup.dwFlags = subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = subprocess.SW_HIDE
    process = subprocess.Popen(
        command_line, executable=exe, cwd=game_bin, env=environment, startupinfo=startup
    )
    timed_out = False
    try:
        process.wait(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=10)

    log = loader / "UE4SS.log"
    marker = f"[RotMCoopLocalQA {token}] "
    events = []
    if log.is_file():
        for line in log.read_text(encoding="utf-8", errors="replace").splitlines():
            if marker in line:
                event = line.split(marker, 1)[1].strip()
                events.append(event)
                print(event)
    return classify(events, list(crash_contexts(profile)), process.returncode, timed_out)


def self_test():
    create = "CREATE controller_id=1"
    events = ["READY local_controllers=1 host=mage", create]
    evidence = events + ["PLAYERS local_controllers=2 host=mage_a guest=mage_b"] * 3
    assert classify(evidence + ["RESULT PASS"], [], 0, False)[0] == "PASS"
    assert classify(["RESULT PASS"], [], 0, False)[0] == "FAIL"
    assert classify(evidence, [], 0, False)[0] == "FAIL"
    assert classify(events, [], -1073741819, True)[0] == "TIMEOUT"
    assert classify(events, [(KNOWN_STACK, KNOWN_ERROR)], 3, False)[1].startswith("Reproduced")
    assert not classify([], [(KNOWN_STACK, KNOWN_ERROR)], 3, False)[1].startswith("Reproduced")


def main():
    parser = argparse.ArgumentParser(description="Probe local Mage Hub player initialization.")
    parser.add_argument("isolated_game_root", type=Path, nargs="?")
    parser.add_argument("--start", choices=("travel", "launch"), default="travel")
    parser.add_argument("--additional-mods", type=Path)
    parser.add_argument("--candidate-lua", type=Path, help="Load a standalone test candidate before the probe.")
    parser.add_argument("--label", help="Name the test variant in the output.")
    parser.add_argument("--timeout", type=int, default=65)
    parser.add_argument("--self-test", action="store_true", help="Verify result scoring without the game.")
    args = parser.parse_args()
    status, detail = "FAIL", "The probe did not start."
    try:
        if args.self_test:
            self_test()
            status, detail = "PASS", "Result scorer self-test passed."
        elif args.timeout <= 0:
            raise ValueError("Timeout must be positive.")
        else:
            status, detail = run(args)
    except (AssertionError, OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        detail = str(error) or type(error).__name__
    print(detail)
    print(f"RESULT: {status}")
    return 0 if status == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
