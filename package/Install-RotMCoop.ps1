[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$GameRoot,
    [switch]$ReplaceDifferentLoader
)
$ErrorActionPreference = 'Stop'
$ExpectedExe = '98C8EB1D3474883D826D24FC67A49310425D5E42099AF120D5326A0DE09C8682'
$OldLauncherHash = '86646D27BDECA2B3BBE27FE62ED721F3B2E2FCA0F2EB21C1C07BFFAEE716BF82'
$Source = $PSScriptRoot

if (-not $GameRoot) {
    Add-Type -AssemblyName System.Windows.Forms
    $picker = New-Object System.Windows.Forms.FolderBrowserDialog
    $picker.Description = 'Выберите папку игры с каталогом RevengeOfTheMage'
    if ($picker.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-Output 'Установка отменена.'
        exit 2
    }
    $GameRoot = $picker.SelectedPath
}
$GameRoot = [System.IO.Path]::GetFullPath($GameRoot)
$Win64 = Join-Path $GameRoot 'RevengeOfTheMage\Binaries\Win64'
$Exe = Join-Path $Win64 'RevengeOfTheMage-Win64-Shipping.exe'
# Avoid partially replacing a loaded bridge or UE4SS scripts while the game
# is running. A previous build allowed mid-session replacement and mixed versions.
$LiveGame = @(Get-CimInstance Win32_Process -Filter "Name='RevengeOfTheMage-Win64-Shipping.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -and
        [string]::Equals($_.ExecutablePath, $Exe, [System.StringComparison]::OrdinalIgnoreCase) })
if ($LiveGame.Count -gt 0) {
    throw 'Сначала закройте игру. Замена файлов во время работы Steam-моста запрещена.'
}
if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) {
    throw "Не найдена игра: $Exe"
}
if ((Get-FileHash -LiteralPath $Exe -Algorithm SHA256).Hash -ne $ExpectedExe) {
    throw 'Версия игры не поддерживается. Требуется Steam 1.0.0.301.'
}
$Active = @(Get-Process -Name RevengeOfTheMage-Win64-Shipping -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $Exe })
if ($Active.Count) { throw 'Закройте этот экземпляр игры перед установкой.' }
# The shipped game's steam_api64.dll may be a non-Steam stub. The bridge MUST
# use the vetted Steamworks redistributable from this release, not that DLL.
$OfficialSteamDll = Join-Path $Source 'steam_api64.dll'
$ExpectedSteamSha = '7A991D4A08A51E34721EAFB439AC0A144BEE410817411B2F9AA3C74425A997F1'
if (-not (Test-Path -LiteralPath $OfficialSteamDll -PathType Leaf) -or
    (Get-FileHash -LiteralPath $OfficialSteamDll -Algorithm SHA256).Hash -ne $ExpectedSteamSha) {
    throw 'В пакете отсутствует проверенная библиотека Steamworks. Установка отменена.'
}
$Components = @(
    @{ From='Runtime\dwmapi.dll'; To='dwmapi.dll'; Loader=$true },
    @{ From='Runtime\ue4ss\UE4SS.dll'; To='ue4ss\UE4SS.dll'; Loader=$true },
    @{ From='Runtime\ue4ss\UE4SS-settings.ini'; To='ue4ss\UE4SS-settings.ini'; Loader=$true },
    @{ From='Runtime\ue4ss\LICENSE'; To='ue4ss\LICENSE'; Loader=$true },
    @{ From='Runtime\ue4ss\Mods\shared\UEHelpers\UEHelpers.lua'; To='ue4ss\Mods\shared\UEHelpers\UEHelpers.lua'; Loader=$true },
    @{ From='Runtime\ue4ss\UE4SS_SDK_Backends\UE4SS.json'; To='ue4ss\UE4SS_SDK_Backends\UE4SS.json'; Loader=$true },
    @{ From='Runtime\RotMCoop\Scripts\main.lua'; To='ue4ss\Mods\RotMCoop\Scripts\main.lua'; Loader=$false },
    @{ From='Runtime\RotMCoop\Scripts\early_controller.lua'; To='ue4ss\Mods\RotMCoop\Scripts\early_controller.lua'; Loader=$false },
    @{ From='Runtime\RotMCoop\Scripts\startup_gate.lua'; To='ue4ss\Mods\RotMCoop\Scripts\startup_gate.lua'; Loader=$false },
    @{ From='Runtime\RotMCoop\Scripts\session_travel.lua'; To='ue4ss\Mods\RotMCoop\Scripts\session_travel.lua'; Loader=$false },
    @{ From='Runtime\RotMCoop\Scripts\steam_menu.lua'; To='ue4ss\Mods\RotMCoop\Scripts\steam_menu.lua'; Loader=$false },
    @{ From='Runtime\RotMCoop\Scripts\network_motion.lua'; To='ue4ss\Mods\RotMCoop\Scripts\network_motion.lua'; Loader=$false },
    @{ From='Runtime\RotMCoop\Scripts\hud_spells.lua'; To='ue4ss\Mods\RotMCoop\Scripts\hud_spells.lua'; Loader=$false },
    @{ From='Runtime\RotMCoop\Scripts\guest_spawn.lua'; To='ue4ss\Mods\RotMCoop\Scripts\guest_spawn.lua'; Loader=$false },
    @{ From='Runtime\RotMCoop\Scripts\party_loadout.lua'; To='ue4ss\Mods\RotMCoop\Scripts\party_loadout.lua'; Loader=$false },
    @{ From='Runtime\RotMCoop\Scripts\party_identity.lua'; To='ue4ss\Mods\RotMCoop\Scripts\party_identity.lua'; Loader=$false },
    @{ From='Runtime\RotMCoop\Scripts\party_combat.lua'; To='ue4ss\Mods\RotMCoop\Scripts\party_combat.lua'; Loader=$false },
    @{ From='Runtime\RotMCoop\Scripts\party_montage.lua'; To='ue4ss\Mods\RotMCoop\Scripts\party_montage.lua'; Loader=$false },
    @{ From='Runtime\RotMCoop\Scripts\party_gate.lua'; To='ue4ss\Mods\RotMCoop\Scripts\party_gate.lua'; Loader=$false },
    @{ From='Runtime\RotMCoop\Scripts\party_loading.lua'; To='ue4ss\Mods\RotMCoop\Scripts\party_loading.lua'; Loader=$false },
    @{ From='Runtime\RotMCoop\Scripts\party_cards.lua'; To='ue4ss\Mods\RotMCoop\Scripts\party_cards.lua'; Loader=$false },
    @{ From='Runtime\RotMCoop\Scripts\party_revive.lua'; To='ue4ss\Mods\RotMCoop\Scripts\party_revive.lua'; Loader=$false },
    @{ From='Runtime\RotMCoop\Scripts\party_gameplay.lua'; To='ue4ss\Mods\RotMCoop\Scripts\party_gameplay.lua'; Loader=$false },
    @{ From='Runtime\RotMCoop\Scripts\party_visuals.lua'; To='ue4ss\Mods\RotMCoop\Scripts\party_visuals.lua'; Loader=$false },
    @{ From='Runtime\RotMCoop\Scripts\party_hud.lua'; To='ue4ss\Mods\RotMCoop\Scripts\party_hud.lua'; Loader=$false },
    @{ From='Runtime\RotMCoop\Scripts\party_fx.lua'; To='ue4ss\Mods\RotMCoop\Scripts\party_fx.lua'; Loader=$false },
    @{ From='Runtime\RotMCoop\Scripts\party_ammo.lua'; To='ue4ss\Mods\RotMCoop\Scripts\party_ammo.lua'; Loader=$false },
    @{ From='Runtime\RotMCoop\Scripts\localization.lua'; To='ue4ss\Mods\RotMCoop\Scripts\localization.lua'; Loader=$false },
    @{ From='Runtime\RotMCoop\Scripts\config.lua'; To='ue4ss\Mods\RotMCoop\Scripts\config.lua'; Loader=$false },
    @{ From='RotMSteamBridge.exe'; To='ue4ss\Mods\RotMCoop\Scripts\RotMSteamBridge.exe'; Loader=$false }
)
foreach ($c in $Components) {
    $item = Join-Path $Source $c.From
    if (-not (Test-Path -LiteralPath $item -PathType Leaf)) {
        throw "Неполный пакет: $item"
    }
}
foreach ($c in $Components | Where-Object { $_.Loader }) {
    $from = Join-Path $Source $c.From
    $to = Join-Path $Win64 $c.To
    if ((Test-Path -LiteralPath $to -PathType Leaf) -and
        (Get-FileHash -LiteralPath $from -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $to -Algorithm SHA256).Hash -and
        -not $ReplaceDifferentLoader) {
        throw "Другая версия UE4SS: $to. Для замены с резервной копией используйте -ReplaceDifferentLoader."
    }
}
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
function Deploy-File {
    param([string]$From, [string]$To, [bool]$PreserveExisting = $false)
    $folder = Split-Path -Parent $To
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    if (Test-Path -LiteralPath $To -PathType Leaf) {
        if ((Get-FileHash -LiteralPath $From -Algorithm SHA256).Hash -eq
            (Get-FileHash -LiteralPath $To -Algorithm SHA256).Hash) { return }
        if ($PreserveExisting) { return }
        Copy-Item -LiteralPath $To -Destination "$To.rotm-backup-$Stamp" -Force
    }
    Copy-Item -LiteralPath $From -Destination $To -Force
}
if ($PSCmdlet.ShouldProcess($GameRoot, 'Установка RotMCoop v0.6.0 Steam 480 P2P')) {
    foreach ($c in $Components) {
        $keep = $c.To -eq 'ue4ss\Mods\RotMCoop\Scripts\config.lua'
        Deploy-File (Join-Path $Source $c.From) (Join-Path $Win64 $c.To) $keep
    }
    $Scripts = Join-Path $Win64 'ue4ss\Mods\RotMCoop\Scripts'
    Deploy-File $OfficialSteamDll (Join-Path $Scripts 'steam_api64.dll')
    [IO.File]::WriteAllText((Join-Path $Scripts 'steam_appid.txt'), "480`n",
        (New-Object System.Text.UTF8Encoding($false)))

    # Migrate older configuration while retaining custom settings and addresses.
    $ConfigPath = Join-Path $Scripts 'config.lua'
    $ConfigText = [IO.File]::ReadAllText($ConfigPath)
    $ConfigChanges = @(
        @{ Key='auto_action'; Val='nil' },
        @{ Key='steam_lobbies_enabled'; Val='true' },
        @{ Key='steam_ui_qa'; Val='false' },
        @{ Key='network_motion_tuning'; Val='true' },
        @{ Key='auto_reconnect'; Val='true' },
        @{ Key='max_reconnect_attempts'; Val='5' },
        @{ Key='reconnect_interval_seconds'; Val='25' }
    )
    $new = $ConfigText
    foreach ($setting in $ConfigChanges) {
        $pattern = '(?m)^(\s*' + [regex]::Escape($setting.Key) + '\s*=\s*)([^,\r\n]+)'
        if ([regex]::IsMatch($new, $pattern)) {
            if ($setting.Key -in @('auto_action', 'steam_lobbies_enabled', 'steam_ui_qa')) {
                $new = [regex]::Replace($new, $pattern,
                    [System.Text.RegularExpressions.MatchEvaluator] {
                        param($m)
                        return $m.Groups[1].Value + $setting.Val
                    })
            }
        }
        else {
            $end = $new.LastIndexOf('}')
            if ($end -lt 0) { throw 'Неверная структура config.lua.' }
            $new = $new.Insert($end, "    $($setting.Key) = $($setting.Val),`r`n")
        }
    }
    if ($new -ne $ConfigText) {
        Copy-Item -LiteralPath $ConfigPath -Destination "$ConfigPath.rotm-backup-$Stamp"
        [IO.File]::WriteAllText($ConfigPath, $new, (New-Object System.Text.UTF8Encoding($false)))
    }

    $ModsFile = Join-Path $Win64 'ue4ss\Mods\mods.txt'
    if (Test-Path -LiteralPath $ModsFile) {
        $original = [IO.File]::ReadAllText($ModsFile)
        $others = @($original -split '\r?\n' | Where-Object { $_ -and $_ -notmatch '^\s*RotMCoop\s*:' })
    }
    else {
        $original = ''
        $others = @()
    }
    $entries = (@($others) + @('RotMCoop : 1')) -join "`r`n"
    if ($entries -ne $original.TrimEnd([char[]]@("`r","`n"))) {
        if (Test-Path -LiteralPath $ModsFile) {
            Copy-Item -LiteralPath $ModsFile -Destination "$ModsFile.rotm-backup-$Stamp"
        }
        [IO.File]::WriteAllText($ModsFile, $entries + "`r`n",
            (New-Object System.Text.UTF8Encoding($false)))
    }

    # Retire only the old launcher built by this project. Leave unknown binaries alone.
    $LegacyLauncher = Join-Path $GameRoot 'RotMCoopLauncher.exe'
    if ((Test-Path -LiteralPath $LegacyLauncher -PathType Leaf) -and
        (Get-FileHash -LiteralPath $LegacyLauncher -Algorithm SHA256).Hash -eq $OldLauncherHash) {
        Move-Item -LiteralPath $LegacyLauncher -Destination "$LegacyLauncher.rotm-backup-$Stamp"
    }
    Write-Host 'RotMCoop v0.6.0 установлен. Отдельный лаунчер не нужен.'
    Write-Host 'Запускайте игру обычным способом через Steam. В главном меню появится СЕТЕВАЯ ИГРА.'
    Write-Host 'Игровые пакеты передаются через Steam P2P. Переадресация портов не требуется.'
}
