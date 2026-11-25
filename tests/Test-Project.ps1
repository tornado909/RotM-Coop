$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Main = Join-Path $Root 'mod\RotMCoop\Scripts\main.lua'
$Config = Join-Path $Root 'mod\RotMCoop\Scripts\config.lua'
$Required = @(
    'RegisterKeyBind(Key.F5',
    'RegisterKeyBind(Key.F6',
    'RegisterKeyBind(Key.F7',
    'local options = "?listen"',
    'system:IsStandalone(world)',
    'system:IsServer(world)'
)

foreach ($Path in @($Main, $Config, (Join-Path $Root 'scripts\install.ps1'), (Join-Path $Root 'scripts\uninstall.ps1'))) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing required file: $Path"
    }
}

$Source = Get-Content -Raw -LiteralPath $Main
foreach ($Needle in $Required) {
    if (-not $Source.Contains($Needle)) {
        throw "main.lua is missing required token: $Needle"
    }
}

if ($Source.Contains('CreatePlayer')) {
    throw 'The native split-screen crash probe must not ship.'
}
if (-not (Select-String -LiteralPath $Config -SimpleMatch 'auto_action = nil' -Quiet)) {
    throw 'Test automation must be disabled in the shipping config.'
}
if (-not (Select-String -LiteralPath $Config -SimpleMatch 'diagnostic_engine_game_mode = false' -Quiet)) {
    throw 'The stock engine control must be opt-in.'
}

$null = [scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $Root 'scripts\install.ps1')))
$null = [scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $Root 'scripts\uninstall.ps1')))

Write-Host 'ALL OK'
