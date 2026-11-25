[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$GameRoot
)

$ErrorActionPreference = 'Stop'
$Win64 = Join-Path $GameRoot 'RevengeOfTheMage\Binaries\Win64'
$Mods = Join-Path $Win64 'ue4ss\Mods'
$ModsFile = Join-Path $Mods 'mods.txt'
$TargetMod = Join-Path $Mods 'RotMCoop'

if (Test-Path -LiteralPath $ModsFile -PathType Leaf) {
    $Updated = @(Get-Content -LiteralPath $ModsFile) | Where-Object { $_ -notmatch '^\s*RotMCoop\s*:' }
    Set-Content -LiteralPath $ModsFile -Value $Updated -Encoding UTF8
}

if ((Test-Path -LiteralPath $TargetMod) -and $PSCmdlet.ShouldProcess($TargetMod, 'Remove RotMCoop runtime files')) {
    Remove-Item -LiteralPath $TargetMod -Recurse -Force
}

Write-Host 'RotMCoop removed. UE4SS itself was left installed.'
