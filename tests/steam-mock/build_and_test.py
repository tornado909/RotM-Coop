"""Build the disposable two-identity Steam mock and run its transport regression.

The mock DLL is TEST ONLY; never copy it into a production game or release.
"""
from pathlib import Path
import os
import shutil
import socket
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BIN = HERE / "runtime"

def invoke(args, cwd=None):
    print("BUILD_STEP", Path(args[0]).name, flush=True)
    result = subprocess.run(args, cwd=cwd or HERE, check=False)
    if result.returncode:
        raise RuntimeError(f"Build command failed: {result.returncode}")
    return result

def locate_vcvars():
    for base in (Path(os.environ.get("ProgramFiles", r"C:\Program Files")),
                 Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"))):
        for year in ("2022", "2026"):
            for edition in ("Community", "Professional", "Enterprise", "BuildTools"):
                path = base / "Microsoft Visual Studio" / year / edition / "VC" / "Auxiliary" / "Build" / "vcvars64.bat"
                if path.is_file():
                    return path
    raise FileNotFoundError("Visual Studio C++ build tools are required")

def main():
    # Do not interfere with a live game on the default Unreal UDP port.
    test = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        test.bind(("127.0.0.1", 7777))
    finally:
        test.close()
    vcvars = locate_vcvars()
    mock = HERE / "steam_api64.dll"
    command = (
        'call "' + str(vcvars) + '" >nul && cl.exe /nologo /LD /O2 /std:c++17 ' +
        '"' + str(HERE / "steam_api64.cpp") + '" /link /OUT:"' + str(mock) + '"'
    )
    print("BUILD_STEP cl.exe", flush=True)
    subprocess.run(command, cwd=HERE, shell=True, check=True)
    base = BIN / "base"
    base.mkdir(parents=True, exist_ok=True)
    project = str(ROOT / "steam-bridge" / "RotMSteamBridge.csproj")
    local_packages = Path.home() / ".nuget" / "packages"
    invoke(["dotnet", "restore", project, "-r", "win-x64", "--source",
            str(local_packages), "--ignore-failed-sources", "--nologo",
            "-v", "quiet"], cwd=ROOT)
    invoke(["dotnet", "publish", project,
            "-c", "Release", "-r", "win-x64", "--self-contained", "true",
            "--no-restore",
            "-p:PublishSingleFile=true", "-p:IncludeNativeLibrariesForSelfExtract=true",
            "-p:DebugType=None", "-p:DebugSymbols=false",
            "-o", str(base), "--nologo", "-v", "quiet"], cwd=ROOT)
    for role in ("host", "guest"):
        dest = BIN / role
        dest.mkdir(parents=True, exist_ok=True)
        shutil.copy2(base / "RotMSteamBridge.exe", dest / "RotMSteamBridge.exe")
        shutil.copy2(mock, dest / "steam_api64.dll")
        (dest / "steam_appid.txt").write_text("480\n", encoding="ascii")
    invoke([sys.executable, str(HERE / "test_p2p.py")], cwd=ROOT)
    print("COOP_ANYTHING_P2P_HARNESS_PASS", flush=True)

if __name__ == "__main__":
    main()
