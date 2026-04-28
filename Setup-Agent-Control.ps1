[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Agent-Control'),
    [string]$HermesDistro,
    [int]$OpenClawPort = 18789,
    [int]$AutoRefreshSeconds = 15,
    [switch]$CreateDesktopShortcut = $true,
    [switch]$CreateStartMenuShortcut = $true,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$wslExe = Join-Path $env:SystemRoot 'System32\wsl.exe'

function Get-WslDistroNames {
    if (-not (Test-Path $wslExe)) { return @() }
    try {
        @(& $wslExe -l -q 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } catch {
        @()
    }
}

function Resolve-HermesDistro {
    param([string]$Preferred)
    $distros = @(Get-WslDistroNames)
    if ($Preferred -and ($distros -contains $Preferred)) { return $Preferred }
    if ($distros -contains 'Ubuntu') { return 'Ubuntu' }
    if ($distros.Count -eq 1) { return $distros[0] }
    if ($distros.Count -gt 0) { return $distros[0] }
    return if ($Preferred) { $Preferred } else { 'Ubuntu' }
}

function New-Shortcut {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Target,
        [string]$Arguments = '',
        [string]$WorkingDirectory = '',
        [string]$Description = 'Agent Control'
    )
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($Path)
    $sc.TargetPath = $Target
    if ($Arguments) { $sc.Arguments = $Arguments }
    if ($WorkingDirectory) { $sc.WorkingDirectory = $WorkingDirectory }
    $sc.Description = $Description
    $sc.IconLocation = Join-Path $env:SystemRoot 'System32\shell32.dll,167'
    $sc.Save()
}

if (-not (Test-Path $sourceDir)) {
    throw "Source folder not found: $sourceDir"
}

if (-not (Test-Path (Join-Path $sourceDir 'Agent-Control.ps1'))) {
    throw "Could not find Agent-Control.ps1 in $sourceDir"
}

$resolvedDistro = Resolve-HermesDistro $HermesDistro

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

$filesToCopy = @(
    'Agent-Control.ps1',
    'Agent-Control.cmd',
    'Agent-Control.vbs',
    'Agent-Control-Launcher.cs',
    'Agent-Control.exe',
    'Agent Control GUI.exe'
)

foreach ($name in $filesToCopy) {
    $src = Join-Path $sourceDir $name
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination (Join-Path $InstallDir $name) -Force
    }
}

$settings = [pscustomobject]@{
    HermesDistro       = $resolvedDistro
    OpenClawPort       = $OpenClawPort
    AutoRefreshSeconds  = $AutoRefreshSeconds
}
$settingsPath = Join-Path $InstallDir 'Agent-Control.settings.json'
$json = $settings | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($settingsPath, $json, [System.Text.UTF8Encoding]::new($false))

$launchCmd = Join-Path $InstallDir 'Agent-Control.cmd'
if (-not (Test-Path $launchCmd)) {
    throw "Launch wrapper not found after install: $launchCmd"
}

$shortcutTargets = @()
if ($CreateDesktopShortcut) {
    $desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
    if ($desktop) { $shortcutTargets += (Join-Path $desktop 'Agent Control.lnk') }
}
if ($CreateStartMenuShortcut) {
    $startMenu = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::StartMenu)) 'Programs'
    if ($startMenu) { $shortcutTargets += (Join-Path $startMenu 'Agent Control.lnk') }
}

foreach ($shortcut in $shortcutTargets) {
    $parent = Split-Path -Parent $shortcut
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    New-Shortcut -Path $shortcut -Target $launchCmd -WorkingDirectory $InstallDir -Description 'Agent Control'
}

Write-Host ''
Write-Host 'Agent Control is ready.' -ForegroundColor Green
Write-Host "Install folder: $InstallDir"
Write-Host "Hermes distro:  $resolvedDistro"
Write-Host "OpenClaw port:  $OpenClawPort"
Write-Host "Auto-refresh:   $AutoRefreshSeconds s"
if ($CreateDesktopShortcut) { Write-Host 'Desktop shortcut: created' }
if ($CreateStartMenuShortcut) { Write-Host 'Start Menu shortcut: created' }
Write-Host ''
Write-Host 'Launch it with Agent-Control.cmd or the shortcut.'
