[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GameRoot
)

$ErrorActionPreference = 'Stop'
$ExpectedExeSha256 = '98c8eb1d3474883d826d24fc67a49310425d5e42099af120d5326a0de09c8682'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Win64 = Join-Path $GameRoot 'RevengeOfTheMage\Binaries\Win64'
$Exe = Join-Path $Win64 'RevengeOfTheMage-Win64-Shipping.exe'
$Ue4ss = Join-Path $Win64 'ue4ss'
$Mods = Join-Path $Ue4ss 'Mods'
$ModsFile = Join-Path $Mods 'mods.txt'
$SourceMod = Join-Path $ProjectRoot 'mod\RotMCoop'
$TargetMod = Join-Path $Mods 'RotMCoop'

if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) {
    throw "Revenge of the Mage shipping executable was not found under: $GameRoot"
}

$ExePath = (Resolve-Path -LiteralPath $Exe).ProviderPath
$Sha256 = [System.Security.Cryptography.SHA256]::Create()
try {
    $ExeStream = [System.IO.File]::OpenRead($ExePath)
    try {
        $ActualHash = [BitConverter]::ToString($Sha256.ComputeHash($ExeStream)).Replace('-', '').ToLowerInvariant()
    } finally {
        $ExeStream.Dispose()
    }
} finally {
    $Sha256.Dispose()
}
if ($ActualHash -ne $ExpectedExeSha256) {
    throw "Unsupported game build. Expected EXE SHA-256 $ExpectedExeSha256, got $ActualHash"
}

if (-not (Test-Path -LiteralPath (Join-Path $Ue4ss 'UE4SS.dll') -PathType Leaf)) {
    throw 'UE4SS v4.0.0 is not installed. Install the pinned official release before installing this mod.'
}

if (-not (Test-Path -LiteralPath $ModsFile -PathType Leaf)) {
    throw "UE4SS mods.txt was not found: $ModsFile"
}

if (-not (Test-Path -LiteralPath $SourceMod -PathType Container)) {
    throw "Source mod directory was not found: $SourceMod"
}

$Backup = "$ModsFile.rotm-coop.bak"
if (-not (Test-Path -LiteralPath $Backup)) {
    Copy-Item -LiteralPath $ModsFile -Destination $Backup
}

New-Item -ItemType Directory -Path $TargetMod -Force | Out-Null
Copy-Item -Path (Join-Path $SourceMod '*') -Destination $TargetMod -Recurse -Force

$Lines = @(Get-Content -LiteralPath $ModsFile)
$Found = $false
$Updated = foreach ($Line in $Lines) {
    if ($Line -match '^\s*RotMCoop\s*:') {
        $Found = $true
        'RotMCoop : 1'
    } else {
        $Line
    }
}
if (-not $Found) {
    $Updated += 'RotMCoop : 1'
}
Set-Content -LiteralPath $ModsFile -Value $Updated -Encoding UTF8

Write-Host "Installed RotMCoop for verified Steam 1.0.0.301 build."
Write-Host "Runtime path: $TargetMod"
