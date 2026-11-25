from pathlib import Path
import hashlib, re, zipfile, urllib.request, sys
root = Path(__file__).resolve().parents[1]
out = root / "out"
out.mkdir(exist_ok=True)
base = out / "runtime-v0.5.9.zip"
url = "https://github.com/tornado909/RotM-Coop/releases/download/v0.5.9/RotMCoop-Win64-0.5.9-test.zip"
if not base.exists():
    urllib.request.urlretrieve(url, base)
assert hashlib.sha256(base.read_bytes()).hexdigest() == "840ecfdd619368d1987c285273394e6c02bbf983ce50fb371128688f0062e372"
files = {}
with zipfile.ZipFile(base) as z:
    for name in z.namelist():
        if "/" not in name:
            continue
        p = name.split("/", 1)[1]
        if p.startswith("Runtime/ue4ss/") or p in ("Runtime/dwmapi.dll", "steam_api64.dll"):
            files[p] = z.read(name)
assert len(files) == 7
assert hashlib.sha256(files["steam_api64.dll"]).hexdigest() == "7a991d4a08a51e34721eafb439ac0a144bee410817411b2f9aa3c74425a997f1"
for p in (root / "mod/RotMCoop/Scripts").glob("*.lua"):
    files["Runtime/RotMCoop/Scripts/" + p.name] = p.read_bytes()
files["RotMSteamBridge.exe"] = (out / "bridge/RotMSteamBridge.exe").read_bytes()
files["Install-RotMCoop.cmd"] = (root / "package/Install-RotMCoop.cmd").read_bytes()
installer = (root / "package/Install-RotMCoop.ps1").read_text(encoding="utf-8-sig")
files["Install-RotMCoop.ps1"] = installer.encode("utf-8-sig")
files["README-RU.md"] = (root / "package/README-RU.md").read_bytes()
for p in re.findall(r"From='([^']+)'", installer):
    assert p.replace("\\", "/") in files, p
assert "Runtime/RotMCoop/Scripts/party_montage.lua" in files
assert "auto_action = nil" in files["Runtime/RotMCoop/Scripts/config.lua"].decode("utf-8-sig")
assert not any("Shipping.exe" in n or "FullQA" in n or "steam-ipc" in n for n in files)
name = "RotMCoop-Win64-0.6.4-test"
target = out / (name + ".zip")
with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    for p, data in sorted(files.items()):
        z.writestr(name + "/" + p, data)
with zipfile.ZipFile(target) as z:
    assert z.testzip() is None
    assert len(z.namelist()) == len(files)
sha = hashlib.sha256(target.read_bytes()).hexdigest()
(out / "SHA256SUMS.txt").write_text(sha + "  " + target.name + "\n", encoding="ascii")
print(f"{target.name}: {len(files)} files, {target.stat().st_size} bytes, SHA256 {sha}")
