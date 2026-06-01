[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Agent-Control'),
    [string]$HermesDistro,
    [int]$OpenClawPort = 18789,
    [int]$AutoRefreshSeconds = 15,
    [switch]$CreateDesktopShortcut = $true,
    [switch]$CreateStartMenuShortcut = $true,
    [switch]$Force,
    [switch]$AutoInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Detection state ────────────────────────────────────────────────────────────
$Detected = @{
    OsVersion      = $null
    IsWslInstalled = $false
    WslDistros     = @()
    HermesFound    = $false
    HermesDistro   = $null
    HermesVersion  = $null
    OpenClawFound  = $false
    OpenClawPath   = $null
    OpenClawVersion = $null
    NodeFound      = $false
    NodePath       = $null
    GitFound       = $false
}

$sourceDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$wslExe    = Join-Path $env:SystemRoot 'System32\wsl.exe'

# ── UI helpers ─────────────────────────────────────────────────────────────────
$Host.UI.RawUI.ForegroundColor = $null  # reset

function Write-Step {
    param([string]$Message, [string]$Color = 'White')
    Write-Host "`n ◆ " -ForegroundColor Cyan -NoNewline
    Write-Host $Message -ForegroundColor $Color
}

function Write-Ok {
    param([string]$Message)
    Write-Host "   ✔ " -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Write-Warn {
    param([string]$Message)
    Write-Host "   ⚠ " -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}

function Write-Fail {
    param([string]$Message)
    Write-Host "   ✘ " -ForegroundColor Red -NoNewline
    Write-Host $Message
}

function Write-Info {
    param([string]$Message)
    Write-Host "     " -NoNewline
    Write-Host $Message -ForegroundColor DarkGray
}

function Test-CommandExists {
    param([string]$Command)
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $result = Get-Command $Command -ErrorAction SilentlyContinue
    $ErrorActionPreference = $oldPreference
    return ($null -ne $result)
}

function Read-Choice {
    param([string]$Question, [string[]]$Options)
    $title = ''
    $prompt = $Question
    $choices = @()
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $accelerator = '&' + ($i + 1)
        $label = if ($i -eq 0) { "$accelerator $($Options[$i])" } else { "$accelerator $($Options[$i])" }
        $choices += New-Object System.Management.Automation.Host.ChoiceDescription($label, $Options[$i])
    }
    $result = $Host.UI.PromptForChoice($title, $prompt, $choices, 0)
    return $result
}

# ════════════════════════════════════════════════════════════════════════════════
#  PHASE 1: DETECT
# ════════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║      Agent Control — Setup & Detect      ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan

# ── 1a. OS ─────────────────────────────────────────────────────────────────────
Write-Step "Checking system..."
$os = Get-CimInstance Win32_OperatingSystem
$Detected.OsVersion = $os.Version
Write-Info "Windows $($os.Caption) - Build $($os.Version)"
if ($os.Version -lt '10.0.22000') {
    Write-Warn "Windows 11 or Windows 10 22H2+ recommended for WSL2."
}

# ── 1b. WSL ────────────────────────────────────────────────────────────────────
Write-Step "Checking WSL..."
if (Test-Path $wslExe) {
    try {
        $wslOutput = & $wslExe --status 2>&1 | Out-String
        $Detected.IsWslInstalled = ($LASTEXITCODE -eq 0) -or ($wslOutput -match 'Default Distribution|WSL version')
        if (-not $Detected.IsWslInstalled) {
            # Fallback: try --list
            $null = & $wslExe -l -q 2>$null
            $Detected.IsWslInstalled = ($LASTEXITCODE -eq 0)
        }
    } catch { $Detected.IsWslInstalled = $false }

    if ($Detected.IsWslInstalled) {
        Write-Ok "WSL is present."
        # Get distros
        $distros = @(& $wslExe -l -q 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne 'docker-desktop' -and $_ -ne 'docker-desktop-data' })
        $Detected.WslDistros = $distros
        if ($distros.Count -gt 0) {
            Write-Ok "WSL distros: $($distros -join ', ')"
        } else {
            Write-Warn "WSL installed but no distros found."
        }
    } else {
        Write-Warn "wsl.exe found but WSL may not be fully set up."
    }
} else {
    Write-Fail "WSL is not installed."
}

# ── 1c. Hermes (inside each WSL distro) ────────────────────────────────────────
Write-Step "Checking for Hermes..."

if ($Detected.WslDistros.Count -gt 0) {
    # Try preferred distro first, then all others
    $distroCandidates = if ($HermesDistro) {
        @($HermesDistro) + ($Detected.WslDistros | Where-Object { $_ -ne $HermesDistro })
    } else {
        $Detected.WslDistros
    }

    foreach ($distro in $distroCandidates) {
        if ($Detected.HermesFound) { break }

        Write-Info "Checking '$distro'..."

        # Check 1: Is the hermes CLI installed?
        $hermesCheck = & $wslExe -d $distro -- bash -lc 'command -v hermes 2>/dev/null; hermes --version 2>/dev/null || echo "NOT_FOUND"' 2>$null
        $hasCli = ($LASTEXITCODE -eq 0) -and ($hermesCheck -notmatch 'NOT_FOUND')

        if (-not $hasCli) {
            Write-Info "   No hermes CLI found in '$distro'."
            continue
        }

        $Detected.HermesFound = $true
        $Detected.HermesDistro = $distro
        $Detected.HermesVersion = ($hermesCheck | Select-String 'Hermes Agent v[\d.]+' | ForEach-Object { $_.Matches.Value }) -replace 'Hermes Agent ',''

        # Check gateway service
        $gwStatus = & $wslExe -d $distro -- bash -lc 'systemctl --user is-enabled hermes-gateway 2>/dev/null || echo "NOT_INSTALLED"' 2>$null
        $gwActive = & $wslExe -d $distro -- bash -lc 'systemctl --user is-active hermes-gateway 2>/dev/null || echo "inactive"' 2>$null

        $gwInfo = switch ($gwActive.Trim()) {
            'active'   { "running" }
            'inactive' { "installed but stopped" }
            default    { $gwActive.Trim() }
        }

        Write-Ok "Hermes v$($Detected.HermesVersion) in '$distro' (gateway: $gwInfo)"
        break
    }

    if (-not $Detected.HermesFound) {
        Write-Warn "Hermes not found in any WSL distro."
    }
} else {
    Write-Warn "No WSL distros to check for Hermes."
}

# ── 1d. OpenClaw (on Windows) ─────────────────────────────────────────────────
Write-Step "Checking for OpenClaw..."

$openclawPaths = @(
    (Get-Command 'openclaw' -ErrorAction SilentlyContinue).Source,
    (Get-Command 'openclaw.cmd' -ErrorAction SilentlyContinue).Source,
    (Join-Path $env:APPDATA 'npm\openclaw.cmd'),
    (Join-Path $env:APPDATA 'npm\openclaw'),
    (Join-Path $env:LOCALAPPDATA 'npm\openclaw.cmd'),
    (Join-Path $env:LOCALAPPDATA 'npm\openclaw')
)

foreach ($path in $openclawPaths) {
    if ($path -and (Test-Path $path)) {
        $Detected.OpenClawFound = $true
        $Detected.OpenClawPath = $path
        try {
            $versionOutput = & $path --version 2>&1 | Out-String
            if ($versionOutput -match 'OpenClaw\s+([\d.]+)') {
                $Detected.OpenClawVersion = $Matches[1]
            } elseif ($versionOutput -match '([\d.]+)') {
                $Detected.OpenClawVersion = $Matches[1]
            }
        } catch {}
        Write-Ok "OpenClaw $($Detected.OpenClawVersion) at $path"
        break
    }
}

if (-not $Detected.OpenClawFound) {
    Write-Warn "OpenClaw not found on Windows PATH."
}

# ── 1e. Node.js (prerequisite for OpenClaw) ────────────────────────────────────
Write-Step "Checking prerequisites..."

$Detected.NodeFound = Test-CommandExists 'node'
$Detected.NodePath  = (Get-Command 'node' -ErrorAction SilentlyContinue).Source
if ($Detected.NodeFound) {
    $nodeVer = & node --version 2>&1
    Write-Ok "Node.js $nodeVer at $($Detected.NodePath)"
} else {
    Write-Warn "Node.js not found (needed to install OpenClaw via npm)."
}

$Detected.GitFound = Test-CommandExists 'git'
if ($Detected.GitFound) {
    $gitVer = & git --version 2>&1
    Write-Ok "Git $gitVer"
} else {
    Write-Warn "Git not found (needed for Hermes install)."
}

# ════════════════════════════════════════════════════════════════════════════════
#  PHASE 2: REPORT
# ════════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║            Detection Summary              ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan

Write-Host ""
Write-Host "  WSL:" -ForegroundColor Yellow
if ($Detected.IsWslInstalled) {
    Write-Host "    Installed:  Yes" -ForegroundColor Green
    if ($Detected.WslDistros.Count -gt 0) {
        Write-Host "    Distros:    $($Detected.WslDistros -join ', ')" -ForegroundColor White
    }
} else { Write-Host "    Installed:  No" -ForegroundColor Red }

Write-Host "  Hermes:" -ForegroundColor Yellow
if ($Detected.HermesFound) {
    Write-Host "    Status:     v$($Detected.HermesVersion) in $($Detected.HermesDistro)" -ForegroundColor Green
} else { Write-Host "    Status:     Not found" -ForegroundColor Red }

Write-Host "  OpenClaw:" -ForegroundColor Yellow
if ($Detected.OpenClawFound) {
    Write-Host "    Status:     v$($Detected.OpenClawVersion)" -ForegroundColor Green
    Write-Host "    Path:       $($Detected.OpenClawPath)" -ForegroundColor DarkGray
} else { Write-Host "    Status:     Not found" -ForegroundColor Red }

Write-Host "  Prerequisites:" -ForegroundColor Yellow
Write-Host "    Node.js:    $(if ($Detected.NodeFound) { '✓' } else { '✘' })" -ForegroundColor $(if ($Detected.NodeFound) { 'Green' } else { 'Red' })
Write-Host "    Git:        $(if ($Detected.GitFound) { '✓' } else { '✘' })" -ForegroundColor $(if ($Detected.GitFound) { 'Green' } else { 'Red' })

# ════════════════════════════════════════════════════════════════════════════════
#  PHASE 3: INSTALL (if needed)
# ════════════════════════════════════════════════════════════════════════════════
$anythingMissing = (-not $Detected.IsWslInstalled) -or (-not $Detected.HermesFound) -or (-not $Detected.OpenClawFound)
$canInstallOpenClaw = $Detected.NodeFound -and (-not $Detected.OpenClawFound)
$canInstallHermes = $Detected.IsWslInstalled -and (-not $Detected.HermesFound) -and ($Detected.WslDistros.Count -gt 0 -or $AutoInstall)

if ($anythingMissing) {
    Write-Step "Checking what can be installed..." "Yellow"

    $wantsInstall = $AutoInstall
    if (-not $wantsInstall) {
        $choice = Read-Choice "Missing components detected. Install now?" @('Install missing', 'Skip install, just configure GUI')
        $wantsInstall = ($choice -eq 0)
    }

    if ($wantsInstall) {
        # ── 3a. Install WSL if missing ──
        if (-not $Detected.IsWslInstalled) {
            Write-Step "Installing WSL2..." "Yellow"
            Write-Warn "This will run: wsl --install (requires admin rights)"
            Write-Info "A reboot will be required after installation."

            if ($AutoInstall -or ((Read-Choice "Proceed with WSL install?" @('Yes, install WSL', 'Skip WSL')) -eq 0)) {
                try {
                    Write-Host "   Running wsl --install..." -NoNewline
                    $wslInstall = & $wslExe --install 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host " Done" -ForegroundColor Green
                        Write-Ok "WSL2 + Ubuntu are being installed."
                        Write-Warn "You'll need to reboot, then run this setup again to continue."
                        Write-Warn "After reboot, launch 'Ubuntu' from Start Menu to complete the WSL setup."
                        return
                    } else {
                        Write-Host " Failed" -ForegroundColor Red
                        Write-Fail "WSL install returned exit code $LASTEXITCODE"
                        Write-Info "$wslInstall"
                    }
                } catch {
                    Write-Host " Error" -ForegroundColor Red
                    Write-Fail "Could not install WSL: $_"
                }
            }
        }

        # ── 3b. Install Hermes if missing ──
        if ($canInstallHermes) {
            $targetDistro = if ($Detected.WslDistros.Count -gt 0) {
                $Detected.WslDistros[0]
            } else { 'Ubuntu' }

            Write-Step "Installing Hermes in '$targetDistro'..." "Yellow"
            Write-Info "This runs the official Hermes install script inside WSL."
            Write-Info "It will clone the repo and set up the Python venv."

            if ($AutoInstall -or ((Read-Choice "Install Hermes in '$targetDistro'?" @('Yes, install Hermes', 'Skip')) -eq 0)) {
                try {
                    Write-Host "   Installing..." -NoNewline
                    $installOutput = & $wslExe -d $targetDistro -- bash -lc 'curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash' 2>&1

                    if ($LASTEXITCODE -eq 0) {
                        Write-Host " Done" -ForegroundColor Green
                        Write-Ok "Hermes installed in '$targetDistro'."

                        # Update detection
                        $Detected.HermesFound = $true
                        $Detected.HermesDistro = $targetDistro
                        $verOut = & $wslExe -d $targetDistro -- bash -lc 'hermes --version 2>/dev/null | head -1' 2>$null
                        if ($verOut -match 'v([\d.]+)') { $Detected.HermesVersion = $Matches[1] }

                        # Enable & start the gateway
                        Write-Host "   Enabling gateway service..." -NoNewline
                        & $wslExe -d $targetDistro -- bash -lc 'systemctl --user enable hermes-gateway 2>/dev/null; systemctl --user start hermes-gateway 2>/dev/null' 2>$null
                        Write-Host " Done" -ForegroundColor Green
                        Write-Info "Gateway enabled. You should now configure:"
                        Write-Info "  1. Run: hermes model"
                        Write-Info "  2. Set up your Telegram bot token"
                        Write-Info "  3. Run: hermes gateway setup"
                    } else {
                        Write-Host " Failed" -ForegroundColor Red
                        Write-Fail "Hermes install returned exit code $LASTEXITCODE"
                        Write-Info "$installOutput"
                    }
                } catch {
                    Write-Host " Error" -ForegroundColor Red
                    Write-Fail "Could not install Hermes: $_"
                }
            }
        } elseif (-not $Detected.HermesFound -and $Detected.IsWslInstalled) {
            Write-Warn "Hermes install requires at least one WSL distro."
            Write-Info "Install Ubuntu from Microsoft Store, then run this setup again."
        }

        # ── 3c. Install OpenClaw if missing ──
        if ($canInstallOpenClaw) {
            Write-Step "Installing OpenClaw via npm..." "Yellow"
            Write-Info "This runs: npm install -g openclaw"

            if ($AutoInstall -or ((Read-Choice "Install OpenClaw?" @('Yes, install OpenClaw', 'Skip')) -eq 0)) {
                try {
                    Write-Host "   Installing openclaw..." -NoNewline
                    $npmOutput = & npm install -g openclaw 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host " Done" -ForegroundColor Green
                        Write-Ok "OpenClaw installed."
                        $Detected.OpenClawFound = $true
                        $Detected.OpenClawPath = (Get-Command 'openclaw' -ErrorAction SilentlyContinue).Source
                    } else {
                        Write-Host " Failed" -ForegroundColor Red
                        Write-Fail "npm install failed."
                        Write-Info "$npmOutput"
                    }
                } catch {
                    Write-Host " Error" -ForegroundColor Red
                    Write-Fail "Could not install OpenClaw: $_"
                }
            }
        } elseif (-not $Detected.OpenClawFound) {
            Write-Warn "OpenClaw install requires Node.js (npm)."
            Write-Info "Install Node.js from https://nodejs.org then run this setup again."
        }

    } else {
        Write-Step "Skipping install. Will configure GUI with what exists." "DarkGray"
    }
} else {
    Write-Step "All components detected!" "Green"
}

# ════════════════════════════════════════════════════════════════════════════════
#  PHASE 4: CONFIGURE GUI
# ════════════════════════════════════════════════════════════════════════════════
Write-Step "Setting up Agent Control GUI..." "Cyan"

# Resolve the Hermes distro for settings
$finalDistro = $Detected.HermesDistro
if (-not $finalDistro) {
    if ($HermesDistro) { $finalDistro = $HermesDistro }
    elseif ($Detected.WslDistros.Count -gt 0) { $finalDistro = $Detected.WslDistros[0] }
    else { $finalDistro = 'Ubuntu' }
}

# Copy files
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

$filesToCopy = @(
    'Agent-Control.ps1',
    'Agent-Control.cmd',
    'Agent-Control.vbs',
    'Agent-Control-Launcher.cs',
    'Agent-Control.exe',
    'Agent Control GUI.exe'
)

$copied = 0
foreach ($name in $filesToCopy) {
    $src = Join-Path $sourceDir $name
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination (Join-Path $InstallDir $name) -Force
        $copied++
    }
}
Write-Ok "Copied $copied file(s) to $InstallDir"

# Write settings file
$settings = [pscustomobject]@{
    HermesDistro       = $finalDistro
    OpenClawPort       = $OpenClawPort
    AutoRefreshSeconds = $AutoRefreshSeconds
}
$settingsPath = Join-Path $InstallDir 'Agent-Control.settings.json'
$json = $settings | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($settingsPath, $json, [System.Text.UTF8Encoding]::new($false))
Write-Ok "Settings written to $settingsPath"
Write-Info "  Hermes distro:  $finalDistro"
Write-Info "  OpenClaw port:  $OpenClawPort"
Write-Info "  Auto-refresh:   ${AutoRefreshSeconds}s"

# Create shortcuts
$launchCmd = Join-Path $InstallDir 'Agent-Control.cmd'
if (-not (Test-Path $launchCmd)) {
    Write-Warn "Launch wrapper missing at $launchCmd — cannot create shortcuts."
} else {
    function New-Shortcut {
        param(
            [string]$Path,
            [string]$Target,
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
    Write-Ok "Shortcuts created ($($shortcutTargets.Count))"
}

# ════════════════════════════════════════════════════════════════════════════════
#  PHASE 5: SUMMARY
# ════════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║               Setup Complete              ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

Write-Host "  Agent Control GUI is ready!" -ForegroundColor Green
Write-Host "  ───────────────────────────" -ForegroundColor DarkGray
Write-Host "  Install folder: $InstallDir" -ForegroundColor White
Write-Host ""

Write-Host "  What's configured:" -ForegroundColor Yellow
if ($Detected.HermesFound) {
    Write-Host "   ✔ Hermes v$($Detected.HermesVersion) — $($Detected.HermesDistro)" -ForegroundColor Green
} else {
    Write-Host "   ✘ Hermes — not installed" -ForegroundColor Red
}
if ($Detected.OpenClawFound) {
    Write-Host "   ✔ OpenClaw v$($Detected.OpenClawVersion)" -ForegroundColor Green
} else {
    Write-Host "   ✘ OpenClaw — not installed" -ForegroundColor Red
}
Write-Host ""

Write-Host "  Launch it:" -ForegroundColor Yellow
Write-Host "   • Double-click the desktop shortcut" -ForegroundColor White
Write-Host "   • Or run: $launchCmd" -ForegroundColor DarkGray
Write-Host ""

if (-not $Detected.HermesFound -or -not $Detected.OpenClawFound) {
    Write-Host "  Post-install steps:" -ForegroundColor Yellow
    if (-not $Detected.HermesFound) {
        Write-Host "   • Install Hermes in WSL and re-run setup for auto-detection" -ForegroundColor DarkGray
        Write-Host "     Or manually edit HermesDistro in settings after installing." -ForegroundColor DarkGray
    }
    if (-not $Detected.OpenClawFound) {
        Write-Host "   • Install OpenClaw: npm install -g openclaw" -ForegroundColor DarkGray
        Write-Host "     Requires Node.js from https://nodejs.org" -ForegroundColor DarkGray
    }
    Write-Host ""
}

Write-Host "  Need API keys?" -ForegroundColor Yellow
Write-Host "   After launching the GUI, configure Hermes from WSL:" -ForegroundColor DarkGray
Write-Host "     wsl -d $finalDistro -- hermes setup" -ForegroundColor DarkGray
Write-Host "     wsl -d $finalDistro -- hermes gateway setup" -ForegroundColor DarkGray
Write-Host ""
