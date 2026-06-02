#Requires -Version 5.1
[CmdletBinding()]
param([switch]$StartMinimized)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Ensure STA thread mode for NotifyIcon/Forms compatibility
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $cmd = "$PSCommandPath"
    if ($StartMinimized) { $cmd += ' -StartMinimized' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$cmd`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    [System.Diagnostics.Process]::Start($psi) | Out-Null
    exit 0
}

[System.Windows.Forms.Application]::EnableVisualStyles()

# ── App configuration ────────────────────────────────────────────────────────
$script:AppRoot      = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:SettingsPath = Join-Path $script:AppRoot 'Agent-Control.settings.json'
$script:SettingsWarnings = @()

function Get-DefaultSettings {
    [pscustomobject]@{
        HermesDistro       = $null
        OpenClawPort       = 18789
        AutoRefreshSeconds = 15
        StartWithWindows   = $false
    }
}

function Save-AgentControlSettings {
    param([pscustomobject]$Settings)
    $json = $Settings | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($script:SettingsPath, $json, [System.Text.UTF8Encoding]::new($false))
}

function Load-AgentControlSettings {
    $settings = Get-DefaultSettings
    if (-not (Test-Path $script:SettingsPath)) { return $settings }
    try {
        $raw  = Get-Content -Path $script:SettingsPath -Raw -ErrorAction Stop
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
        $props = @($data.PSObject.Properties.Name)

        if ($props -contains 'HermesDistro' -and $null -ne $data.HermesDistro -and [string]$data.HermesDistro -ne '') {
            $settings.HermesDistro = [string]$data.HermesDistro
        }
        if ($props -contains 'OpenClawPort') {
            $port = 0
            if ([int]::TryParse([string]$data.OpenClawPort, [ref]$port) -and $port -ge 1 -and $port -le 65535) {
                $settings.OpenClawPort = $port
            } else {
                $script:SettingsWarnings += "Invalid OpenClawPort '$($data.OpenClawPort)'; using default $($settings.OpenClawPort)."
            }
        }
        if ($props -contains 'AutoRefreshSeconds') {
            $secs = 0
            if ([int]::TryParse([string]$data.AutoRefreshSeconds, [ref]$secs) -and $secs -ge 1 -and $secs -le 3600) {
                $settings.AutoRefreshSeconds = $secs
            } else {
                $script:SettingsWarnings += "Invalid AutoRefreshSeconds '$($data.AutoRefreshSeconds)'; using default $($settings.AutoRefreshSeconds)."
            }
        }
        if ($props -contains 'StartWithWindows') {
            $sw = $data.StartWithWindows
            if ($sw -is [bool]) { $settings.StartWithWindows = $sw }
            elseif ($sw -is [string]) {
                $parsed = $false
                if ([bool]::TryParse($sw, [ref]$parsed)) {
                    $settings.StartWithWindows = $parsed
                } else {
                    $script:SettingsWarnings += "Invalid StartWithWindows string '$sw'; using default $($settings.StartWithWindows)."
                }
            } else {
                $typeName = if ($null -eq $sw) { 'null' } else { $sw.GetType().Name }
                $script:SettingsWarnings += "Invalid StartWithWindows type '$typeName'; using default $($settings.StartWithWindows)."
            }
        }
    } catch {
        $script:SettingsWarnings += "Failed to parse settings file; using defaults. $($_.Exception.Message)"
    }
    return $settings
}

# ── System paths ─────────────────────────────────────────────────────────────
$wslExe        = Join-Path $env:SystemRoot 'System32\wsl.exe'
$cmdExe        = Join-Path $env:SystemRoot 'System32\cmd.exe'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Get-WslDistroNames {
    if (-not (Test-Path $wslExe)) { return @() }
    try { @(& $wslExe -l -q 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    catch { @() }
}

function Resolve-HermesDistro {
    param([string]$Preferred)
    $distros = @(Get-WslDistroNames)
    if ($Preferred -and ($distros -contains $Preferred))              { return $Preferred }
    if ($env:HERMES_WSL_DISTRO -and ($distros -contains $env:HERMES_WSL_DISTRO)) { return $env:HERMES_WSL_DISTRO }
    $hermesNamed = @($distros | Where-Object { $_ -match 'hermes' })
    if ($hermesNamed.Count -ge 1) { return $hermesNamed[0] }
    if ($distros -contains 'Ubuntu') { return 'Ubuntu' }
    if ($distros.Count -ge 1)        { return $distros[0] }
    if ($Preferred) { return $Preferred }
    return 'Ubuntu'
}

$script:Settings           = Load-AgentControlSettings
$script:distro             = Resolve-HermesDistro $script:Settings.HermesDistro
$script:openClawPort       = if ($script:Settings.OpenClawPort)       { [int]$script:Settings.OpenClawPort       } else { 18789 }
$script:autoRefreshSeconds = if ($script:Settings.AutoRefreshSeconds) { [int]$script:Settings.AutoRefreshSeconds } else { 15 }
$script:autoRefreshMs      = [Math]::Max(1000, $script:autoRefreshSeconds * 1000)

if (-not (Test-Path $script:SettingsPath)) {
    $script:Settings.HermesDistro       = $script:distro
    $script:Settings.OpenClawPort       = $script:openClawPort
    $script:Settings.AutoRefreshSeconds = $script:autoRefreshSeconds
    Save-AgentControlSettings $script:Settings
}

# ── OpenClaw path resolution (done once at startup, in main session where PATH is correct) ──
# Background jobs (Start-Job) get a clean environment without user-level PATH entries,
# so we resolve all paths here and pass them as parameters to jobs.
function Resolve-OpenClawPaths {
    $result = [pscustomobject]@{
        CliPath    = $null   # openclaw.cmd wrapper
        GatewayCmd = $null   # gateway.cmd in state dir
        NodeExe    = $null   # node.exe
        EntryJs    = $null   # openclaw\dist\index.js
        StateDir   = $null   # OPENCLAW_STATE_DIR
    }

    # Resolve openclaw CLI wrapper
    try {
        $w = & $cmdExe /c 'where openclaw 2>nul'
        if ($LASTEXITCODE -eq 0) {
            $p = (($w | Out-String).Trim() -split '\r?\n')[0].Trim()
            if ($p -and (Test-Path $p)) { $result.CliPath = $p }
        }
    } catch {}
    if (-not $result.CliPath) {
        foreach ($c in @("$env:USERPROFILE\npm-global\openclaw.cmd",
                         "$env:APPDATA\npm\openclaw.cmd",
                         "$env:USERPROFILE\AppData\Roaming\npm\openclaw.cmd")) {
            if (Test-Path $c) { $result.CliPath = $c; break }
        }
    }

    # Resolve state directory
    $stateDirs = @(
        $env:OPENCLAW_STATE_DIR,
        'D:\Apps\Openclaw',
        "$env:USERPROFILE\.openclaw",
        "$env:LOCALAPPDATA\openclaw"
    ) | Where-Object { $_ -and (Test-Path $_) }
    if ($stateDirs) { $result.StateDir = $stateDirs[0] }

    # Resolve gateway.cmd
    foreach ($dir in $stateDirs) {
        $p = Join-Path $dir 'gateway.cmd'
        if (Test-Path $p) { $result.GatewayCmd = $p; break }
    }

    # Resolve node.exe
    foreach ($candidate in @('C:\Program Files\nodejs\node.exe')) {
        if (Test-Path $candidate) { $result.NodeExe = $candidate; break }
    }
    if (-not $result.NodeExe) {
        try {
            $w2 = & $cmdExe /c 'where node 2>nul'
            if ($LASTEXITCODE -eq 0) {
                $p = (($w2 | Out-String).Trim() -split '\r?\n')[0].Trim()
                if ($p -and (Test-Path $p)) { $result.NodeExe = $p }
            }
        } catch {}
    }

    # Resolve openclaw entry.js (for direct node launch fallback)
    foreach ($ep in @("$env:USERPROFILE\npm-global\node_modules\openclaw\dist\index.js",
                      "$env:APPDATA\npm\node_modules\openclaw\dist\index.js",
                      "$env:USERPROFILE\AppData\Roaming\npm\node_modules\openclaw\dist\index.js")) {
        if (Test-Path $ep) { $result.EntryJs = $ep; break }
    }

    $result
}

$script:ocPaths = Resolve-OpenClawPaths

# ── OLED dark palette ─────────────────────────────────────────────────────────
function rgb { param([int]$r,[int]$g,[int]$b) [System.Drawing.Color]::FromArgb($r,$g,$b) }

$C = @{
    BgForm    = rgb 10  11  15
    BgCard    = rgb 18  20  26
    BgHeader  = rgb 12  14  18
    BgLog     = rgb 14  16  22
    BgBtn     = rgb 29  32  42
    BgBtnHov  = rgb 40  44  56
    BgGreen   = rgb 17  46  29
    BgRed     = rgb 52  20  24
    BgBlue    = rgb 21  28  52
    BgOrange  = rgb 52  36  14
    Border    = rgb 43  47  62
    TxtPri    = rgb 239 242 247
    TxtMuted  = rgb 132 139 155
    Green     = rgb 74  222 128
    Red       = rgb 248 113 113
    Orange    = rgb 251 146 60
    Blue      = rgb 99  102 241
}

# ── Log box declared early so Add-Log can reference it ───────────────────────
$logBox = New-Object System.Windows.Forms.TextBox
$script:autoEnabled = $true

# ── Status state tracking (for change notifications) ─────────────────────────
$script:lastHermesStatus   = ''
$script:lastOpenClawStatus = ''
$script:trayHermesItem     = $null
$script:trayOpenClawItem   = $null

# ── Core helpers ──────────────────────────────────────────────────────────────
function Add-Log {
    param([string]$Message)
    $stamp = Get-Date -Format 'HH:mm:ss'
    $logBox.AppendText("[$stamp] $Message`r`n")
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
}

# ── Async helper ──────────────────────────────────────────────────────────────
$script:asyncJobs = @{}
function Invoke-Async {
    param(
        [scriptblock]$Work,
        [object[]]$WorkArgs = @(),
        [scriptblock]$Done  = {}
    )
    $id  = [System.Guid]::NewGuid().ToString()
    $job = $null
    try { $job = Start-Job -ScriptBlock $Work -ArgumentList $WorkArgs } catch {}
    if (-not $job) { try { & $Done @() } catch {}; return }
    $script:asyncJobs[$id] = @{ Job = $job; Done = $Done }
    $poll          = New-Object System.Windows.Forms.Timer
    $poll.Interval = 500
    $poll.Tag      = $id
    $poll.Add_Tick({
        param($sender, $e)
        $id    = $sender.Tag
        $entry = $script:asyncJobs[$id]
        if (-not $entry -or $entry.Job.State -in 'Running','NotStarted') { return }
        $sender.Stop(); $sender.Dispose()
        $res = @()
        try { $res = @(Receive-Job -Job $entry.Job -ErrorAction SilentlyContinue) } catch {}
        try { Remove-Job -Job $entry.Job -Force -ErrorAction SilentlyContinue } catch {}
        $script:asyncJobs.Remove($id) | Out-Null
        try { & $entry.Done $res } catch {}
    })
    $poll.Start()
}

# ── Service state updaters ────────────────────────────────────────────────────
$script:hermesStatusLabel   = $null
$script:hermesDot           = $null
$script:hermesSubLabel      = $null
$script:openClawStatusLabel = $null
$script:openClawDot         = $null
$script:openClawSubLabel    = $null
$script:hermesRefreshBusy   = $false
$script:openClawRefreshBusy = $false

# ── Notification throttling ───────────────────────────────────────────────────
# Prevent balloon spam from auto-refresh: only notify once per state category,
# with a minimum cooldown between notifications of the same category.
$script:lastHermesBalloonTime   = [DateTime]::MinValue
$script:lastOpenClawBalloonTime = [DateTime]::MinValue
$script:lastHermesBalloonCategory   = ''
$script:lastOpenClawBalloonCategory = ''
$script:balloonCooldownSeconds = 300   # 5 minutes between repeat notifications

function Get-StateCategory {
    param([string]$Text)
    # Collapse status text into a broad category so minor text changes (PID, restart count)
    # don't trigger repeated notifications.
    if ($Text -match 'Active|Listening')     { return 'healthy' }
    if ($Text -match 'Crash-looping')          { return 'degraded' }
    if ($Text -match 'Not active|Not listening|Stopped|inactive|failed|dead') { return 'down' }
    if ($Text -match 'WSL unavailable|Launch path missing') { return 'error' }
    if ($Text -match 'Starting|Restarting|Stopping|\\.\\.\\.') { return 'transition' }
    return 'unknown'
}

function Show-ThrottledBalloon {
    param([string]$Title,[string]$Text,[System.Drawing.Color]$Color,[ref]$LastTime,[ref]$LastCategory)
    $category = Get-StateCategory $Text
    $now = Get-Date
    $cooldown = $script:balloonCooldownSeconds

    # Skip transition states (Starting..., Stopping..., ...)
    if ($category -eq 'transition') { return }

    # Skip if same category shown recently
    if ($category -eq $LastCategory.Value -and ($now - $LastTime.Value).TotalSeconds -lt $cooldown) {
        return
    }

    # Skip the very first status update (empty last status means app just started)
    if ($LastCategory.Value -eq '') {
        $LastCategory.Value = $category
        $LastTime.Value = $now
        return
    }

    $icon = if ($Color.G -gt 100 -and $Color.R -lt 100) { [System.Windows.Forms.ToolTipIcon]::Info }
            elseif ($category -eq 'down' -or $category -eq 'error') { [System.Windows.Forms.ToolTipIcon]::Warning }
            else { [System.Windows.Forms.ToolTipIcon]::Info }
    try { $script:trayIcon.ShowBalloonTip(3000, $Title, $Text, $icon) } catch {}
    $LastCategory.Value = $category
    $LastTime.Value = $now
}

function Set-HermesState {
    param([string]$Text,[System.Drawing.Color]$Color)
    $script:hermesStatusLabel.Text      = $Text
    $script:hermesStatusLabel.ForeColor = $Color
    $script:hermesDot.Tag = $Color
    $script:hermesDot.Invalidate()
    # Throttled balloon notification on meaningful status change
    if ($script:lastHermesStatus -ne '' -and $script:lastHermesStatus -ne $Text) {
        Show-ThrottledBalloon -Title 'Hermes' -Text $Text -Color $Color `
            -LastTime ([ref]$script:lastHermesBalloonTime) -LastCategory ([ref]$script:lastHermesBalloonCategory)
    }
    $script:lastHermesStatus = $Text
    Update-TrayState
}

function Set-OpenClawState {
    param([string]$Text,[System.Drawing.Color]$Color)
    $script:openClawStatusLabel.Text      = $Text
    $script:openClawStatusLabel.ForeColor = $Color
    $script:openClawDot.Tag = $Color
    $script:openClawDot.Invalidate()
    if ($script:lastOpenClawStatus -ne '' -and $script:lastOpenClawStatus -ne $Text) {
        Show-ThrottledBalloon -Title 'OpenClaw' -Text $Text -Color $Color `
            -LastTime ([ref]$script:lastOpenClawBalloonTime) -LastCategory ([ref]$script:lastOpenClawBalloonCategory)
    }
    $script:lastOpenClawStatus = $Text
    Update-TrayState
}

# ── Tray icon polish ──────────────────────────────────────────────────────────
# Build a 16x16 status icon dynamically (green/yellow/red/gray circle)
function New-TrayStatusIcon {
    param([System.Drawing.Color]$Color)
    $size = 16
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    # Background: transparent
    $g.Clear([System.Drawing.Color]::Transparent)
    # Draw filled circle
    $brush = New-Object System.Drawing.SolidBrush($Color)
    $g.FillEllipse($brush, 1, 1, $size - 3, $size - 3)
    $brush.Dispose()
    # Border ring
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(180, 255, 255, 255), 1)
    $g.DrawEllipse($pen, 1, 1, $size - 3, $size - 3)
    $pen.Dispose()
    $g.Dispose()
    $ico = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $ico
}

function Get-TrayStatusColor {
    $h = $script:lastHermesStatus
    $o = $script:lastOpenClawStatus
    $hHealthy = $h -match 'Active \(systemd\)'
    $oHealthy = $o -match 'Listening'
    $hDown    = $h -match 'Not active|WSL unavailable|Launch path missing|Unknown'
    $oDown    = $o -match 'Not listening|Launch path missing|Unknown'
    $hWarn    = $h -match 'Crash-looping|Starting\.|Restarting\.|Stopping\.'
    $oWarn    = $o -match 'Starting\.|Restarting\.|Stopping\.'

    if ($hHealthy -and $oHealthy) { return $C.Green }
    if ($hDown -and $oDown)       { return $C.Red }
    if ($hWarn -or $oWarn)        { return $C.Orange }
    return $C.Orange  # mixed healthy/down
}

function Update-TrayState {
    if (-not $script:trayIcon) { return }
    $h = $script:lastHermesStatus
    $o = $script:lastOpenClawStatus
    $hEmoji = if ($h -match 'Active \(systemd\)') { '●' } elseif ($h -match 'Crash-looping') { '◐' } else { '○' }
    $oEmoji = if ($o -match 'Listening') { '●' } elseif ($o -match 'Starting|Restarting|Stopping') { '◐' } else { '○' }
    $hShort = if ($h -match 'Active \(systemd\)') { 'Active' } elseif ($h -match 'Crash-looping') { 'Degraded' } elseif ($h -match 'Not active') { 'Down' } elseif ($h -match 'WSL unavailable') { 'No WSL' } else { $h }
    $oShort = if ($o -match 'Listening') { 'Listening' } elseif ($o -match 'Not listening') { 'Down' } else { $o }
    $script:trayIcon.Text = "Agent Control`nHermes: $hEmoji $hShort`nOpenClaw: $oEmoji $oShort"

    # Update tray menu status items
    if ($script:trayHermesItem) { $script:trayHermesItem.Text = "Hermes: $hShort" }
    if ($script:trayOpenClawItem) { $script:trayOpenClawItem.Text = "OpenClaw: $oShort" }

    $color = Get-TrayStatusColor
    $oldIcon = $script:trayIcon.Icon
    $newIcon = New-TrayStatusIcon $color
    $script:trayIcon.Icon = $newIcon
    # Note: intentionally not disposing oldIcon to avoid interfering with $form.Icon
    # (tiny icons, GC handles them fine)
}

function Set-StartupWithWindows {
    param([bool]$Enable)
    $shortcutPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\Agent Control.lnk'
    if ($Enable) {
        $exe = Join-Path $script:AppRoot 'Agent Control GUI.exe'
        if (-not (Test-Path $exe)) { $exe = Join-Path $script:AppRoot 'Agent-Control.cmd' }
        if (Test-Path $exe) {
            $wsh = New-Object -ComObject WScript.Shell
            $sc = $wsh.CreateShortcut($shortcutPath)
            $sc.TargetPath = $exe
            $sc.WorkingDirectory = $script:AppRoot
            $sc.IconLocation = $exe
            $sc.Description = 'Agent Control - Start minimized'
            $sc.Save()
            [System.Runtime.Interopservices.Marshal]::ReleaseComObject($wsh) | Out-Null
        }
    } else {
        if (Test-Path $shortcutPath) { Remove-Item $shortcutPath -Force -ErrorAction SilentlyContinue }
    }
}

# ── Hermes functions ──────────────────────────────────────────────────────────
function Refresh-Hermes {
    if ($script:hermesRefreshBusy) { return }
    $script:hermesRefreshBusy = $true
    Set-HermesState '...' $C.TxtMuted
    $wsl = $wslExe; $dist = $script:distro
    Invoke-Async -Work {
        param($exe, $d)
        $maxRetries = 2; $retryDelay = 2
        $wslReady = $true; $exit = 1; $output = ''
        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            $proc   = & $exe -d $d -- bash -lc 'systemctl --user is-active hermes-gateway' 2>&1
            $exit   = $LASTEXITCODE
            $output = (($proc | Out-String) -replace "`0", '').Trim()
            if ($output -match '(?i)failed to attach disk|access is denied|createinstance|mountdisk') {
                $wslReady = $false; break
            }
            if ($exit -eq 0 -or $output -eq 'active') { break }
            Start-Sleep -Seconds $retryDelay
        }
        $nRestarts = 0
        if ($wslReady) {
            $nrOut = & $exe -d $d -- bash -lc 'systemctl --user show hermes-gateway -p NRestarts --value' 2>&1
            if ($nrOut -match '(\d+)') { $nRestarts = [int]$Matches[1] }
        }
        [pscustomobject]@{
            ExitCode  = $exit
            Output    = $output
            WslReady  = $wslReady
            NRestarts = $nRestarts
        }
    } -WorkArgs @($wsl, $dist) -Done {
        param($res)
        $script:hermesRefreshBusy = $false
        $r = if ($res) { $res[0] } else { $null }
        if (-not $r) { Set-HermesState 'Unknown' $C.Orange; return }
        if (-not $r.WslReady) { Set-HermesState 'WSL unavailable' $C.Red; return }
        if ($r.ExitCode -eq 0 -and $r.Output -eq 'active') {
            if ($r.NRestarts -ge 5) { Set-HermesState "Crash-looping ($($r.NRestarts) restarts)" $C.Orange }
            else { Set-HermesState 'Active (systemd)' $C.Green }
        }
        elseif ($r.Output -match '(?i)inactive|failed|dead|stopped') { Set-HermesState 'Not active' $C.Red }
        else { Set-HermesState 'Unknown' $C.Orange }
    }
}

function Start-Hermes {
    Add-Log 'Starting Hermes gateway...'
    Set-HermesState 'Starting...' $C.Orange
    $wsl = $wslExe; $dist = $script:distro
    Invoke-Async -Work {
        param($exe, $d)
        $proc = & $exe -d $d -- bash -lc 'systemctl --user start hermes-gateway' 2>&1
        $exit = $LASTEXITCODE
        $output = (($proc | Out-String) -replace "`0", '').Trim()
        $wslReady = -not ($exit -ne 0 -and $output -match '(?i)failed to attach disk|access is denied|createinstance|mountdisk')
        [pscustomobject]@{ ExitCode = $exit; Output = $output; WslReady = $wslReady }
    } -WorkArgs @($wsl, $dist) -Done {
        param($res)
        $r = if ($res) { $res[0] } else { $null }
        if ($r -and $r.ExitCode -eq 0)     { Add-Log 'Hermes start sent; verifying...' }
        elseif ($r -and -not $r.WslReady)  { Add-Log "Hermes start failed: WSL distro '$($script:distro)' unavailable. $($r.Output)" }
        else                               { Add-Log "Hermes start failed: $(if ($r) { $r.Output } else { 'no result' })" }
        Refresh-Hermes
    }
}

function Stop-Hermes {
    Add-Log 'Stopping Hermes gateway...'
    Set-HermesState 'Stopping...' $C.Orange
    $wsl = $wslExe; $dist = $script:distro
    Invoke-Async -Work {
        param($exe, $d)
        $proc = & $exe -d $d -- bash -lc 'systemctl --user stop hermes-gateway' 2>&1
        $exit = $LASTEXITCODE
        $output = (($proc | Out-String) -replace "`0", '').Trim()
        $wslReady = -not ($exit -ne 0 -and $output -match '(?i)failed to attach disk|access is denied|createinstance|mountdisk')
        [pscustomobject]@{ ExitCode = $exit; Output = $output; WslReady = $wslReady }
    } -WorkArgs @($wsl, $dist) -Done {
        param($res)
        $r = if ($res) { $res[0] } else { $null }
        if ($r -and $r.ExitCode -eq 0)    { Add-Log 'Hermes gateway stopped.' }
        elseif ($r -and -not $r.WslReady) { Add-Log "Hermes stop failed: WSL distro '$($script:distro)' unavailable." }
        else                              { Add-Log "Hermes stop failed: $(if ($r) { $r.Output } else { 'no result' })" }
        Refresh-Hermes
    }
}

function Restart-Hermes {
    Add-Log 'Restarting Hermes gateway...'
    Set-HermesState 'Restarting...' $C.Orange
    $wsl = $wslExe; $dist = $script:distro
    Invoke-Async -Work {
        param($exe, $d)
        $proc = & $exe -d $d -- bash -lc 'systemctl --user restart hermes-gateway' 2>&1
        $exit = $LASTEXITCODE
        $output = (($proc | Out-String) -replace "`0", '').Trim()
        $wslReady = -not ($exit -ne 0 -and $output -match '(?i)failed to attach disk|access is denied|createinstance|mountdisk')
        [pscustomobject]@{ ExitCode = $exit; Output = $output; WslReady = $wslReady }
    } -WorkArgs @($wsl, $dist) -Done {
        param($res)
        $r = if ($res) { $res[0] } else { $null }
        if ($r -and $r.ExitCode -eq 0)    { Add-Log 'Hermes restart sent; verifying...' }
        elseif ($r -and -not $r.WslReady) { Add-Log "Hermes restart failed: WSL unavailable." }
        else                              { Add-Log "Hermes restart failed: $(if ($r) { $r.Output } else { 'no result' })" }
        Refresh-Hermes
    }
}

# ── OpenClaw functions ────────────────────────────────────────────────────────
function Get-OpenClawListener {
    param([int]$Port)
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $conn) { return $null }
    $owner = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
    $ownerPath = $null; try { $ownerPath = $owner.Path } catch {}
    $cmdLine = $null
    try {
        $procInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $($conn.OwningProcess)" -ErrorAction SilentlyContinue
        if ($procInfo) { $cmdLine = $procInfo.CommandLine }
    } catch {}
    [pscustomobject]@{
        Pid         = $conn.OwningProcess
        ProcessName = if ($owner) { $owner.ProcessName } else { $null }
        Path        = $ownerPath
        CommandLine = $cmdLine
    }
}

function Test-OpenClawOwnedProcess {
    param([pscustomobject]$Listener)
    if (-not $Listener) { return $false }
    $name = if ($Listener.ProcessName) { $Listener.ProcessName.ToLowerInvariant() } else { '' }
    $cmd  = if ($Listener.CommandLine) { $Listener.CommandLine.ToLowerInvariant() } else { '' }
    $path = if ($Listener.Path)        { $Listener.Path.ToLowerInvariant() }        else { '' }
    if ($cmd  -match 'openclaw')  { return $true }
    if ($path -match 'openclaw')  { return $true }
    if (($name -eq 'openclaw') -or ($name -eq 'openclaw.exe')) { return $true }
    if ($name -eq 'node' -and $cmd -match 'gateway') { return $true }
    return $false
}

function Refresh-OpenClaw {
    if ($script:openClawRefreshBusy) { return }
    $script:openClawRefreshBusy = $true
    Set-OpenClawState '...' $C.TxtMuted
    $port = $script:openClawPort; $cmd = $cmdExe
    Invoke-Async -Work {
        param($c, $p)
        # Primary check: TCP port
        $conn = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($conn) {
            $owner = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
            # Secondary: HTTP health ping (any response = gateway is alive)
            $httpOk = $false
            try {
                $wr = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$p/health")
                $wr.Timeout = 2000; $wr.Method = 'GET'
                $resp = $wr.GetResponse()
                $resp.Close()
                $httpOk = $true
            } catch [System.Net.WebException] {
                # Non-null Response means the server replied (auth error, 404, etc.) — still alive
                if ($_.Exception.Response -ne $null) { $httpOk = $true }
            } catch {}
            return [pscustomobject]@{
                Type        = 'listener'
                Pid         = $conn.OwningProcess
                ProcessName = if ($owner) { $owner.ProcessName } else { 'listener' }
                HttpOk      = $httpOk
            }
        }
        # Fallback: check openclaw CLI status
        $proc = & $c /c 'openclaw gateway status' 2>&1
        [pscustomobject]@{ Type = 'status'; Output = ($proc | Out-String).Trim(); HttpOk = $false }
    } -WorkArgs @($cmd, $port) -Done {
        param($res)
        $script:openClawRefreshBusy = $false
        $r = if ($res) { $res[0] } else { $null }
        if (-not $r) { Set-OpenClawState 'Unknown' $C.Orange; return }
        if ($r.Type -eq 'listener') {
            $detail = if ($r.HttpOk) { 'HTTP OK' } else { $r.ProcessName }
            Set-OpenClawState "Listening :$($script:openClawPort)  $detail  PID $($r.Pid)" $C.Green
        }
        elseif ($r.Output -match '(?i)disabled|stopped|not running|failed') { Set-OpenClawState 'Not listening' $C.Red }
        else { Set-OpenClawState 'Not listening' $C.Red }
    }
}

function Start-OpenClaw {
    # Verify we have at least one way to launch the gateway
    $paths = $script:ocPaths
    $canStart = ($paths.GatewayCmd -and (Test-Path $paths.GatewayCmd)) -or
                ($paths.NodeExe -and $paths.EntryJs -and (Test-Path $paths.NodeExe) -and (Test-Path $paths.EntryJs))
    if (-not $canStart) {
        Add-Log 'OpenClaw: cannot start — gateway.cmd and node entry not found. Check installation.'
        Set-OpenClawState 'Launch path missing' $C.Red; return
    }
    $listener = Get-OpenClawListener -Port $script:openClawPort
    if ($listener) {
        Add-Log "OpenClaw already listening ($($listener.ProcessName) PID $($listener.Pid))."
        Refresh-OpenClaw; return
    }
    Add-Log 'Starting OpenClaw gateway (~15s to be ready)...'
    Set-OpenClawState 'Starting...' $C.Orange
    $port = $script:openClawPort
    $gw   = $paths.GatewayCmd
    $node = $paths.NodeExe
    $ejs  = $paths.EntryJs
    $sdir = $paths.StateDir
    Invoke-Async -Work {
        param($p, $gw2, $node2, $ejs2, $sdir2)
        # Try direct node+entry.js first (dynamically resolved path ? always correct)
        $startMsg = $null
        if ($node2 -and $ejs2 -and (Test-Path $node2) -and (Test-Path $ejs2)) {
            Start-Process -FilePath $node2 -ArgumentList @($ejs2, 'gateway', '--port', $p) -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
            $startMsg = "node $ejs2"
        }
        # Fallback to gateway.cmd (wrapper may have stale internal paths)
        elseif ($gw2 -and (Test-Path $gw2)) {
            Start-Process -FilePath 'cmd.exe' -ArgumentList "/d /c `"$gw2`"" -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
            $startMsg = "gateway.cmd: $gw2"
        }
        if (-not $startMsg) {
            return [pscustomobject]@{ StartMsg = 'No launch path found'; Listening = $false; ListenPid = 0 }
        }
        $deadline = (Get-Date).AddSeconds(40); $listening = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            $conn = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($conn) { $listening = $true; break }
        }
        $pid2 = 0
        if ($listening) {
            $conn2 = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
            $pid2 = if ($conn2) { $conn2.OwningProcess } else { 0 }
        }
        [pscustomobject]@{ StartMsg = $startMsg; Listening = $listening; ListenPid = $pid2 }
    } -WorkArgs @($port, $gw, $node, $ejs, $sdir) -Done {
        param($res)
        $r = if ($res) { $res[0] } else { $null }
        if ($r -and $r.Listening)    { Add-Log "OpenClaw listening (PID $($r.ListenPid)) via $($r.StartMsg)" }
        elseif ($r -and $r.StartMsg -eq 'No launch path found') { Add-Log 'OpenClaw start failed: no launch path.' }
        elseif ($r)                  { Add-Log "OpenClaw not listening after 40s. Tried: $($r.StartMsg)" }
        else                         { Add-Log 'OpenClaw start failed: no result from job.' }
        Refresh-OpenClaw
    }
}

function Stop-OpenClaw {
    $listener = Get-OpenClawListener -Port $script:openClawPort
    if (-not $listener) { Add-Log 'OpenClaw is not listening.'; Refresh-OpenClaw; return }
    $listenerPid = $listener.Pid
    Add-Log "Stopping OpenClaw (PID $listenerPid)..."
    Set-OpenClawState 'Stopping...' $C.Orange
    $port = $script:openClawPort; $cmd = $cmdExe
    Invoke-Async -Work {
        param($c, $p, $targetPid)
        $logs = [System.Collections.Generic.List[string]]::new()
        # Verify the process is still the one we found (race condition guard)
        $conn = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $conn) { return [pscustomobject]@{ Logs = @('Process already gone.'); StillRunning = $false } }
        $currentPid = $conn.OwningProcess
        # Safety: only kill if it's openclaw/node (by name or command line)
        $proc    = Get-Process -Id $currentPid -ErrorAction SilentlyContinue
        $name    = if ($proc) { $proc.ProcessName.ToLowerInvariant() } else { '' }
        $cmdLine = ''
        try {
            $w = Get-CimInstance Win32_Process -Filter "ProcessId = $currentPid" -ErrorAction SilentlyContinue
            if ($w) { $cmdLine = $w.CommandLine.ToLowerInvariant() }
        } catch {}
        $isSafe = ($cmdLine -match 'openclaw') -or ($name -eq 'openclaw') -or
                  ($name -eq 'node' -and ($cmdLine -match 'gateway' -or $cmdLine -match 'openclaw'))
        if (-not $isSafe) {
            $logs.Add("Safety: process on :$p does not look like OpenClaw (PID $currentPid, name '$name'). Skipping.")
            return [pscustomobject]@{ Logs = $logs.ToArray(); StillRunning = $true }
        }
        # Kill the process tree
        $killOut = & $c /c "taskkill /F /PID $currentPid /T" 2>&1 | Out-String
        $killOut.Trim() -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { $logs.Add($_) }
        Start-Sleep -Seconds 1
        $still = $null -ne (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1)
        [pscustomobject]@{ Logs = $logs.ToArray(); StillRunning = $still }
    } -WorkArgs @($cmd, $port, $listenerPid) -Done {
        param($res)
        $r = if ($res) { $res[0] } else { $null }
        if ($r) {
            foreach ($l in $r.Logs) { Add-Log $l }
            Add-Log $(if ($r.StillRunning) { 'OpenClaw still listening.' } else { 'OpenClaw stopped.' })
        }
        Refresh-OpenClaw
    }
}

function Restart-OpenClaw {
    Add-Log 'Restarting OpenClaw gateway...'
    Set-OpenClawState 'Restarting...' $C.Orange
    $port = $script:openClawPort; $cmd = $cmdExe
    $gw   = $script:ocPaths.GatewayCmd
    $node = $script:ocPaths.NodeExe
    $ejs  = $script:ocPaths.EntryJs
    $sdir = $script:ocPaths.StateDir
    if (-not (($gw -and (Test-Path $gw)) -or ($node -and $ejs -and (Test-Path $node) -and (Test-Path $ejs)))) {
        Add-Log 'OpenClaw restart failed: no launch path found.'
        Set-OpenClawState 'Launch path missing' $C.Red; return
    }
    Invoke-Async -Work {
        param($c, $p, $gw2, $node2, $ejs2, $sdir2)
        # Kill any process listening on the port
        $conn = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($conn) {
            & $c /c "taskkill /F /PID $($conn.OwningProcess) /T" 2>&1 | Out-Null
            Start-Sleep -Seconds 2
        }
        # Try direct node+entry.js first (dynamically resolved path ? always correct)
        $startMsg = $null
        if ($node2 -and $ejs2 -and (Test-Path $node2) -and (Test-Path $ejs2)) {
            Start-Process -FilePath $node2 -ArgumentList @($ejs2, 'gateway', '--port', $p) -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
            $startMsg = "node $ejs2"
        }
        # Fallback to gateway.cmd (wrapper may have stale internal paths)
        elseif ($gw2 -and (Test-Path $gw2)) {
            Start-Process -FilePath 'cmd.exe' -ArgumentList "/d /c `"$gw2`"" -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
            $startMsg = "gateway.cmd: $gw2"
        }
        # Wait for ready
        $deadline = (Get-Date).AddSeconds(40); $listening = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            $conn2 = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($conn2) { $listening = $true; break }
        }
        $pid2 = 0
        if ($listening) {
            $conn3 = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
            $pid2 = if ($conn3) { $conn3.OwningProcess } else { 0 }
        }
        [pscustomobject]@{ Listening = $listening; ListenPid = $pid2; StartMsg = $startMsg }
    } -WorkArgs @($cmd, $port, $gw, $node, $ejs, $sdir) -Done {
        param($res)
        $r = if ($res) { $res[0] } else { $null }
        if ($r -and $r.Listening) { Add-Log "OpenClaw restarted (PID $($r.ListenPid)) via $($r.StartMsg)" }
        else                      { Add-Log 'OpenClaw restart: not listening after 40s.' }
        Refresh-OpenClaw
    }
}

function Get-EnvironmentDiagnostics {
    $wslExists = Test-Path $wslExe
    $cmdExists = Test-Path $cmdExe
    $openClawCli = $false
    if ($cmdExists) {
        try { $null = & $cmdExe /c 'where openclaw' 2>$null; $openClawCli = ($LASTEXITCODE -eq 0) }
        catch { $openClawCli = $false }
    }
    [pscustomobject]@{ WslExeFound = $wslExists; CmdExeFound = $cmdExists; OpenClawCliFound = $openClawCli }
}

# ── Version detection ─────────────────────────────────────────────────────────
function Refresh-Versions {
    $cmd = $cmdExe; $wsl = $wslExe; $dist = $script:distro
    Invoke-Async -Work {
        param($c, $w, $d)
        $ocVer = ''
        try {
            $v = & $c /c 'openclaw --version 2>&1'
            $s = ($v | Out-String).Trim()
            if ($s -match '(\d+\.\d+[\.\d]*)') { $ocVer = "v$($Matches[1])" }
            elseif ($s) { $ocVer = $s -replace '^openclaw\s*', '' }
        } catch {}
        $hermesVer = ''
        try {
            $hv = & $w -d $d -- bash -lc 'hermes --version 2>/dev/null' 2>&1
            $s2 = (($hv | Out-String) -replace "`0", '').Trim()
            if ($s2 -match '(\d+\.\d+[\.\d]*)') { $hermesVer = "v$($Matches[1])" }
        } catch {}
        [pscustomobject]@{ OpenClawVersion = $ocVer; HermesVersion = $hermesVer }
    } -WorkArgs @($cmd, $wsl, $dist) -Done {
        param($res)
        $r = if ($res) { $res[0] } else { $null }
        if ($r) {
            if ($r.OpenClawVersion -and $script:openClawSubLabel) {
                $script:openClawSubLabel.Text = "Windows  ·  TCP :$($script:openClawPort)  ·  $($r.OpenClawVersion)"
            }
            if ($r.HermesVersion -and $script:hermesSubLabel) {
                $script:hermesSubLabel.Text = "WSL $($script:distro)  ·  systemd  ·  $($r.HermesVersion)"
            }
        }
    }
}

# ── Settings dialog ──────────────────────────────────────────────────────────
# Controls stored in script: scope so Add_Click closures can reach them
$script:dlgTxtDistro  = $null
$script:dlgTxtPort    = $null
$script:dlgTxtRefresh = $null
$script:dlgChkStartup = $null
$script:dlgRef        = $null

function Show-SettingsDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'Settings'
    $dlg.Size            = New-Object System.Drawing.Size(380,300)
    $dlg.StartPosition   = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.BackColor       = $C.BgForm
    $dlg.ForeColor       = $C.TxtPri
    $dlg.Font            = New-Object System.Drawing.Font('Segoe UI',9)

    # Label helper (inline, no nested function)
    $mkLbl = {
        param([string]$txt,[int]$x,[int]$y)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $txt; $l.AutoSize = $true
        $l.Location = New-Object System.Drawing.Point($x,$y)
        $l.ForeColor = $C.TxtMuted
        $l
    }

    $dlg.Controls.Add((& $mkLbl 'WSL Distro (Hermes):' 16 18))
    $script:dlgTxtDistro = New-Object System.Windows.Forms.TextBox
    $script:dlgTxtDistro.Text = $script:distro
    $script:dlgTxtDistro.Size = New-Object System.Drawing.Size(220,24)
    $script:dlgTxtDistro.Location = New-Object System.Drawing.Point(16,40)
    $script:dlgTxtDistro.BackColor = $C.BgCard; $script:dlgTxtDistro.ForeColor = $C.TxtPri
    $script:dlgTxtDistro.BorderStyle = 'FixedSingle'
    $dlg.Controls.Add($script:dlgTxtDistro)

    $dlg.Controls.Add((& $mkLbl 'OpenClaw Port:' 16 78))
    $script:dlgTxtPort = New-Object System.Windows.Forms.TextBox
    $script:dlgTxtPort.Text = "$script:openClawPort"
    $script:dlgTxtPort.Size = New-Object System.Drawing.Size(100,24)
    $script:dlgTxtPort.Location = New-Object System.Drawing.Point(16,100)
    $script:dlgTxtPort.BackColor = $C.BgCard; $script:dlgTxtPort.ForeColor = $C.TxtPri
    $script:dlgTxtPort.BorderStyle = 'FixedSingle'
    $dlg.Controls.Add($script:dlgTxtPort)

    $dlg.Controls.Add((& $mkLbl 'Auto-Refresh (seconds, 1-3600):' 16 138))
    $script:dlgTxtRefresh = New-Object System.Windows.Forms.TextBox
    $script:dlgTxtRefresh.Text = "$script:autoRefreshSeconds"
    $script:dlgTxtRefresh.Size = New-Object System.Drawing.Size(100,24)
    $script:dlgTxtRefresh.Location = New-Object System.Drawing.Point(16,160)
    $script:dlgTxtRefresh.BackColor = $C.BgCard; $script:dlgTxtRefresh.ForeColor = $C.TxtPri
    $script:dlgTxtRefresh.BorderStyle = 'FixedSingle'
    $dlg.Controls.Add($script:dlgTxtRefresh)

    $script:dlgChkStartup = New-Object System.Windows.Forms.CheckBox
    $script:dlgChkStartup.Text = 'Start with Windows (minimized to tray)'
    $script:dlgChkStartup.Checked = $script:Settings.StartWithWindows
    $script:dlgChkStartup.AutoSize = $true
    $script:dlgChkStartup.Location = New-Object System.Drawing.Point(16,196)
    $script:dlgChkStartup.ForeColor = $C.TxtPri
    $script:dlgChkStartup.BackColor = $C.BgForm
    $dlg.Controls.Add($script:dlgChkStartup)

    $script:dlgRef = $dlg

    $btnOK = New-FlatButton 'Save' -W 100 -H 32 -Bg $C.BgGreen -Fg $C.Green
    $btnOK.Location = New-Object System.Drawing.Point(16,236)
    $btnCancel = New-FlatButton 'Cancel' -W 100 -H 32
    $btnCancel.Location = New-Object System.Drawing.Point(126,236)

    $btnOK.Add_Click({
        $newDistro  = $script:dlgTxtDistro.Text.Trim()
        $newPortStr = $script:dlgTxtPort.Text.Trim()
        $newRefStr  = $script:dlgTxtRefresh.Text.Trim()
        $newPort    = 0
        $newRefresh = 0
        $errMsg     = ''
        if (-not $newDistro) {
            $errMsg = 'WSL Distro cannot be empty.'
        } elseif (-not [int]::TryParse($newPortStr, [ref]$newPort) -or $newPort -lt 1 -or $newPort -gt 65535) {
            $errMsg = 'Port must be between 1 and 65535.'
        } elseif (-not [int]::TryParse($newRefStr, [ref]$newRefresh) -or $newRefresh -lt 1 -or $newRefresh -gt 3600) {
            $errMsg = 'Refresh interval must be between 1 and 3600.'
        }
        if ($errMsg) {
            [System.Windows.Forms.MessageBox]::Show($errMsg, 'Validation Error', 'OK', 'Warning') | Out-Null
            return
        }
        $script:distro             = $newDistro
        $script:openClawPort       = $newPort
        $script:autoRefreshSeconds = $newRefresh
        $script:autoRefreshMs      = [Math]::Max(1000, $newRefresh * 1000)
        $newStartup = $script:dlgChkStartup.Checked
        $script:Settings.HermesDistro       = $newDistro
        $script:Settings.OpenClawPort       = $newPort
        $script:Settings.AutoRefreshSeconds = $newRefresh
        $script:Settings.StartWithWindows   = $newStartup
        Save-AgentControlSettings $script:Settings
        Set-StartupWithWindows -Enable $newStartup
        if ($script:autoEnabled -and $script:mainTimer) {
            $script:mainTimer.Stop()
            $script:mainTimer.Interval = $script:autoRefreshMs
            $script:mainTimer.Start()
        }
        Add-Log "Settings saved - distro: $newDistro, port: $newPort, refresh: ${newRefresh}s, startup: $newStartup"
        Refresh-Versions
        $script:dlgRef.DialogResult = 'OK'
        $script:dlgRef.Close()
    })
    $btnCancel.Add_Click({
        $script:dlgRef.DialogResult = 'Cancel'
        $script:dlgRef.Close()
    })

    $dlg.Controls.Add($btnOK)
    $dlg.Controls.Add($btnCancel)
    $dlg.AcceptButton = $btnOK
    $dlg.CancelButton = $btnCancel
    $null = $dlg.ShowDialog()
    $script:dlgRef = $null
}

# ── UI factory helpers ────────────────────────────────────────────────────────
function New-FlatButton {
    param([string]$Text,[int]$W=120,[int]$H=32,[System.Drawing.Color]$Bg,[System.Drawing.Color]$Fg)
    if (-not $PSBoundParameters.ContainsKey('Bg')) { $Bg = $C.BgBtn }
    if (-not $PSBoundParameters.ContainsKey('Fg')) { $Fg = $C.TxtPri }
    $b = New-Object System.Windows.Forms.Button
    $b.Text      = $Text
    $b.Size      = New-Object System.Drawing.Size($W,$H)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderColor        = $C.Border
    $b.FlatAppearance.BorderSize         = 1
    $b.FlatAppearance.MouseOverBackColor = $C.BgBtnHov
    $b.FlatAppearance.MouseDownBackColor = $C.BgBtnHov
    $b.BackColor = $Bg
    $b.ForeColor = $Fg
    $b.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $b.Font      = New-Object System.Drawing.Font('Segoe UI',9.25)
    $b.TextAlign = 'MiddleCenter'
    $b.UseVisualStyleBackColor = $false
    $b
}

function New-ChipLabel {
    param([string]$Text,[System.Drawing.Color]$Fg,[System.Drawing.Color]$Bg)
    $l = New-Object System.Windows.Forms.Label
    $l.Text      = " $Text "
    $l.AutoSize  = $true
    $l.Font      = New-Object System.Drawing.Font('Segoe UI',7.5,[System.Drawing.FontStyle]::Bold)
    $l.ForeColor = $Fg
    $l.BackColor = $Bg
    $l.Padding   = New-Object System.Windows.Forms.Padding(8,4,8,4)
    $l.Margin    = New-Object System.Windows.Forms.Padding(0)
    $l
}

function New-ServiceCard {
    param([int]$X,[int]$Y,[int]$W=298,[int]$H=212,[System.Drawing.Color]$Accent)
    $card = New-Object System.Windows.Forms.Panel
    $card.Size      = New-Object System.Drawing.Size($W,$H)
    $card.Location  = New-Object System.Drawing.Point($X,$Y)
    $card.BackColor = $C.BgCard
    if ($PSBoundParameters.ContainsKey('Accent')) { $card.Tag = $Accent }
    $card.Add_Paint({
        param($s,$e)
        $accent = if ($s.Tag -is [System.Drawing.Color]) { [System.Drawing.Color]$s.Tag } else { $C.Blue }
        $pen = New-Object System.Drawing.Pen($C.Border,1)
        $e.Graphics.DrawRectangle($pen,0,0,($s.Width-1),($s.Height-1))
        $pen.Dispose()
        $accentBrush = New-Object System.Drawing.SolidBrush($accent)
        $e.Graphics.FillRectangle($accentBrush,1,1,($s.Width-2),3)
        $accentBrush.Dispose()
    })
    $card
}

# ══════════════════════════════════════════════════════════════════════════════
#  FORM
# ══════════════════════════════════════════════════════════════════════════════
$form = New-Object System.Windows.Forms.Form
$form.Text            = 'Agent Control'
$form.Size            = New-Object System.Drawing.Size(680,612)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox     = $false
$form.BackColor       = $C.BgForm
$form.ForeColor       = $C.TxtPri
$form.Font            = New-Object System.Drawing.Font('Segoe UI',9)
$form.KeyPreview      = $true

# ── Header bar ────────────────────────────────────────────────────────────────
$header = New-Object System.Windows.Forms.Panel
$header.Dock      = 'Top'
$header.Height    = 64
$header.BackColor = $C.BgHeader
$header.Add_Paint({
    param($s,$e)
    $pen = New-Object System.Drawing.Pen($C.Border,1)
    $e.Graphics.DrawLine($pen,0,($s.Height-1),$s.Width,($s.Height-1))
    $pen.Dispose()
})

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text      = 'Agent Control'
$lblTitle.AutoSize  = $true
$lblTitle.Font      = New-Object System.Drawing.Font('Segoe UI Semibold',14)
$lblTitle.ForeColor = $C.TxtPri
$lblTitle.Location  = New-Object System.Drawing.Point(16,8)
$header.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text      = 'Hermes (WSL)  •  OpenClaw (Windows)'
$lblSub.AutoSize  = $true
$lblSub.Font      = New-Object System.Drawing.Font('Segoe UI',8)
$lblSub.ForeColor = $C.TxtMuted
$lblSub.Location  = New-Object System.Drawing.Point(18,36)
$header.Controls.Add($lblSub)

$headerMeta = New-Object System.Windows.Forms.Panel
$headerMeta.Size      = New-Object System.Drawing.Size(360,30)
$headerMeta.Location  = New-Object System.Drawing.Point(300,17)
$headerMeta.BackColor = $C.BgHeader
$header.Controls.Add($headerMeta)

$badgeMode = New-ChipLabel 'PORT-FIRST' $C.Blue $C.BgBlue
$badgeMode.Location = New-Object System.Drawing.Point(0,0)
$headerMeta.Controls.Add($badgeMode)

$script:badgeAuto = New-ChipLabel 'AUTO ON' $C.Green $C.BgGreen
$script:badgeAuto.Location = New-Object System.Drawing.Point(110,0)
$headerMeta.Controls.Add($script:badgeAuto)

$btnSettings = New-FlatButton 'Settings' -W 82 -H 26
$btnSettings.Location = New-Object System.Drawing.Point(568,18)
$btnSettings.Font = New-Object System.Drawing.Font('Segoe UI',8.5)
$btnSettings.Add_Click({ Show-SettingsDialog })
$header.Controls.Add($btnSettings)

$form.Controls.Add($header)

# ── Service cards ─────────────────────────────────────────────────────────────
$cardH  = New-ServiceCard 14  74 320 212 -Accent $C.Blue
$cardOC = New-ServiceCard 346 74 320 212 -Accent $C.Green
$form.Controls.Add($cardH)
$form.Controls.Add($cardOC)

function Add-CardContent {
    param($card,[string]$Tag,[string]$SubText)

    $dot = New-Object System.Windows.Forms.Panel
    $dot.Size      = New-Object System.Drawing.Size(12,12)
    $dot.Location  = New-Object System.Drawing.Point(16,18)
    $dot.BackColor = $C.BgCard
    $dot.Tag       = $C.Orange
    $dot.Add_Paint({
        param($s,$e)
        $col = if ($s.Tag -is [System.Drawing.Color]) { [System.Drawing.Color]$s.Tag } else { $C.Orange }
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $br = New-Object System.Drawing.SolidBrush($col)
        $g.FillEllipse($br,0,0,11,11)
        $br.Dispose()
    })
    $card.Controls.Add($dot)

    $lTag = New-Object System.Windows.Forms.Label
    $lTag.Text      = $Tag
    $lTag.AutoSize  = $true
    $lTag.Font      = New-Object System.Drawing.Font('Segoe UI Semibold',11)
    $lTag.ForeColor = $C.TxtPri
    $lTag.Location  = New-Object System.Drawing.Point(36,12)
    $card.Controls.Add($lTag)

    $lSub = New-Object System.Windows.Forms.Label
    $lSub.Text      = $SubText
    $lSub.AutoSize  = $true
    $lSub.Font      = New-Object System.Drawing.Font('Segoe UI',7.5)
    $lSub.ForeColor = $C.TxtMuted
    $lSub.Location  = New-Object System.Drawing.Point(16,40)
    $card.Controls.Add($lSub)

    $lStatus = New-Object System.Windows.Forms.Label
    $lStatus.Text      = 'Unknown'
    $lStatus.AutoSize  = $true
    $lStatus.Font      = New-Object System.Drawing.Font('Segoe UI Semibold',10.5)
    $lStatus.ForeColor = $C.Orange
    $lStatus.Location  = New-Object System.Drawing.Point(16,68)
    $card.Controls.Add($lStatus)

    @{ Dot = $dot; Status = $lStatus; Sub = $lSub }
}

$hermesWidgets   = Add-CardContent $cardH  'HERMES'   "WSL $($script:distro)  ·  systemd service"
$openClawWidgets = Add-CardContent $cardOC 'OPENCLAW' "Windows  ·  TCP :$($script:openClawPort)"

$script:hermesDot           = $hermesWidgets.Dot
$script:hermesStatusLabel   = $hermesWidgets.Status
$script:hermesSubLabel      = $hermesWidgets.Sub
$script:openClawDot         = $openClawWidgets.Dot
$script:openClawStatusLabel = $openClawWidgets.Status
$script:openClawSubLabel    = $openClawWidgets.Sub

function Add-CardButtons {
    param($card,[scriptblock]$OnStart,[scriptblock]$OnStop,[scriptblock]$OnStatus,[scriptblock]$OnRestart)
    $bStart   = New-FlatButton 'Start'   -W 138 -H 30 -Bg $C.BgGreen   -Fg $C.Green
    $bStop    = New-FlatButton 'Stop'    -W 138 -H 30 -Bg $C.BgRed     -Fg $C.Red
    $bStatus  = New-FlatButton 'Status'  -W 138 -H 30
    $bRestart = New-FlatButton 'Restart' -W 138 -H 30 -Bg $C.BgOrange  -Fg $C.Orange
    $bStart.Location   = New-Object System.Drawing.Point(14,110)
    $bStop.Location    = New-Object System.Drawing.Point(160,110)
    $bStatus.Location  = New-Object System.Drawing.Point(14,148)
    $bRestart.Location = New-Object System.Drawing.Point(160,148)
    $bStart.Add_Click($OnStart); $bStop.Add_Click($OnStop)
    $bStatus.Add_Click($OnStatus); $bRestart.Add_Click($OnRestart)
    $card.Controls.Add($bStart); $card.Controls.Add($bStop)
    $card.Controls.Add($bStatus); $card.Controls.Add($bRestart)
}

Add-CardButtons $cardH `
    { try { Start-Hermes }   catch { Add-Log "Hermes start error: $($_.Exception.Message)"   } } `
    { try { Stop-Hermes }    catch { Add-Log "Hermes stop error: $($_.Exception.Message)"    } } `
    { Refresh-Hermes; Add-Log 'Hermes status refreshed.' } `
    { try { Restart-Hermes } catch { Add-Log "Hermes restart error: $($_.Exception.Message)" } }

Add-CardButtons $cardOC `
    { try { Start-OpenClaw }   catch { Add-Log "OpenClaw start error: $($_.Exception.Message)"   } } `
    { try { Stop-OpenClaw }    catch { Add-Log "OpenClaw stop error: $($_.Exception.Message)"    } } `
    { Refresh-OpenClaw; Add-Log 'OpenClaw status refreshed.' } `
    { try { Restart-OpenClaw } catch { Add-Log "OpenClaw restart error: $($_.Exception.Message)" } }

# ── Quick actions ─────────────────────────────────────────────────────────────
$actionBar = New-Object System.Windows.Forms.Panel
$actionBar.Size      = New-Object System.Drawing.Size(652,46)
$actionBar.Location  = New-Object System.Drawing.Point(14,298)
$actionBar.BackColor = $C.BgCard
$actionBar.Add_Paint({
    param($s,$e)
    $pen = New-Object System.Drawing.Pen($C.Border,1)
    $e.Graphics.DrawRectangle($pen,0,0,($s.Width-1),($s.Height-1))
    $pen.Dispose()
})
$form.Controls.Add($actionBar)

$btnStartBoth  = New-FlatButton 'Start Both'  -W 150 -H 32 -Bg $C.BgGreen -Fg $C.Green
$btnStopBoth   = New-FlatButton 'Stop Both'   -W 150 -H 32 -Bg $C.BgRed   -Fg $C.Red
$btnRefresh    = New-FlatButton 'Refresh All' -W 150 -H 32
$btnAutoToggle = New-FlatButton 'Auto: ON'    -W 150 -H 32 -Bg $C.BgBlue  -Fg $C.Blue

$btnStartBoth.Location  = New-Object System.Drawing.Point(2,7)
$btnStopBoth.Location   = New-Object System.Drawing.Point(164,7)
$btnRefresh.Location    = New-Object System.Drawing.Point(326,7)
$btnAutoToggle.Location = New-Object System.Drawing.Point(488,7)

$btnStartBoth.Add_Click({
    try { Start-Hermes; Start-OpenClaw } catch { Add-Log "Start both error: $($_.Exception.Message)" }
})
$btnStopBoth.Add_Click({
    try { Stop-OpenClaw; Stop-Hermes } catch { Add-Log "Stop both error: $($_.Exception.Message)" }
})
$btnRefresh.Add_Click({
    Refresh-Hermes; Refresh-OpenClaw; Add-Log 'All statuses refreshed.'
})
$btnAutoToggle.Add_Click({
    $script:autoEnabled = -not $script:autoEnabled
    if ($script:autoEnabled) {
        $btnAutoToggle.Text = 'Auto: ON'; $btnAutoToggle.ForeColor = $C.Blue; $btnAutoToggle.BackColor = $C.BgBlue
        $script:badgeAuto.Text = ' AUTO ON '; $script:mainTimer.Start()
    } else {
        $btnAutoToggle.Text = 'Auto: OFF'; $btnAutoToggle.ForeColor = $C.TxtMuted; $btnAutoToggle.BackColor = $C.BgBtn
        $script:badgeAuto.Text = ' AUTO OFF '; $script:mainTimer.Stop()
    }
})

$actionBar.Controls.Add($btnStartBoth); $actionBar.Controls.Add($btnStopBoth)
$actionBar.Controls.Add($btnRefresh);   $actionBar.Controls.Add($btnAutoToggle)

# ── Log panel ─────────────────────────────────────────────────────────────────
$logPanel = New-Object System.Windows.Forms.Panel
$logPanel.Size      = New-Object System.Drawing.Size(652,196)
$logPanel.Location  = New-Object System.Drawing.Point(14,356)
$logPanel.BackColor = $C.BgCard
$logPanel.Add_Paint({
    param($s,$e)
    $pen = New-Object System.Drawing.Pen($C.Border,1)
    $e.Graphics.DrawRectangle($pen,0,0,($s.Width-1),($s.Height-1))
    $pen.Dispose()
})
$form.Controls.Add($logPanel)

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text      = 'LOG'
$lblLog.AutoSize  = $true
$lblLog.Font      = New-Object System.Drawing.Font('Segoe UI',7,[System.Drawing.FontStyle]::Bold)
$lblLog.ForeColor = $C.TxtMuted
$lblLog.Location  = New-Object System.Drawing.Point(12,10)
$logPanel.Controls.Add($lblLog)

$btnClearLog = New-FlatButton 'Clear' -W 60 -H 22
$btnClearLog.Location = New-Object System.Drawing.Point(510,8)
$btnClearLog.Add_Click({ $logBox.Clear() })
$logPanel.Controls.Add($btnClearLog)

$btnExportLog = New-FlatButton 'Export' -W 66 -H 22
$btnExportLog.Location = New-Object System.Drawing.Point(580,8)
$btnExportLog.Add_Click({
    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter   = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
    $sfd.FileName = "agent-control-log-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
    if ($sfd.ShowDialog() -eq 'OK') {
        [System.IO.File]::WriteAllText($sfd.FileName, $logBox.Text, [System.Text.UTF8Encoding]::new($false))
        Add-Log "Log exported → $($sfd.FileName)"
    }
})
$logPanel.Controls.Add($btnExportLog)

$logBox.Multiline   = $true
$logBox.ScrollBars  = 'Vertical'
$logBox.ReadOnly    = $true
$logBox.WordWrap    = $false
$logBox.BackColor   = $C.BgLog
$logBox.ForeColor   = $C.TxtPri
$logBox.BorderStyle = 'None'
$logBox.Font        = New-Object System.Drawing.Font('Consolas',8.5)
$logBox.Size        = New-Object System.Drawing.Size(628,148)
$logBox.Location    = New-Object System.Drawing.Point(12,38)
$logPanel.Controls.Add($logBox)

# ── Auto-refresh timer ────────────────────────────────────────────────────────
$script:mainTimer = New-Object System.Windows.Forms.Timer
$script:mainTimer.Interval = $script:autoRefreshMs
$script:mainTimer.Add_Tick({
    # Background services need monitoring even when hidden
    Refresh-Hermes; Refresh-OpenClaw
})
$script:mainTimer.Start()

# ── System tray ───────────────────────────────────────────────────────────────
# Load custom icon if available, fallback to system icon
$iconPath = Join-Path $script:AppRoot 'Agent-Control-Icon.ico'
$script:appIcon = if (Test-Path $iconPath) {
    New-Object System.Drawing.Icon($iconPath)
} else {
    [System.Drawing.SystemIcons]::Application
}

$script:trayIcon = New-Object System.Windows.Forms.NotifyIcon
$script:trayIcon.Icon    = $script:appIcon
$script:trayIcon.Text    = 'Agent Control'
$script:trayIcon.Visible = $true

# Also set the window icon
$form.Icon = $script:appIcon

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$trayMenu.BackColor = $C.BgCard; $trayMenu.ForeColor = $C.TxtPri

# Status headers (non-clickable, updated dynamically)
$script:trayHermesItem = $trayMenu.Items.Add('Hermes: —')
$script:trayHermesItem.Enabled = $false
$script:trayHermesItem.ForeColor = $C.TxtMuted
$script:trayOpenClawItem = $trayMenu.Items.Add('OpenClaw: —')
$script:trayOpenClawItem.Enabled = $false
$script:trayOpenClawItem.ForeColor = $C.TxtMuted
$null = $trayMenu.Items.Add('-')

$mShow     = $trayMenu.Items.Add('Show')
$mRefresh  = $trayMenu.Items.Add('Refresh All')
$null      = $trayMenu.Items.Add('-')
$mStartAll = $trayMenu.Items.Add('Start Both')
$mStopAll  = $trayMenu.Items.Add('Stop Both')
$null      = $trayMenu.Items.Add('-')
$mSettings = $trayMenu.Items.Add('Settings...')
$null      = $trayMenu.Items.Add('-')
$mQuit     = $trayMenu.Items.Add('Quit')

$mShow.Add_Click({     $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })
$mRefresh.Add_Click({  Refresh-Hermes; Refresh-OpenClaw; Add-Log 'All statuses refreshed (tray).' })
$mStartAll.Add_Click({ try { Start-Hermes; Start-OpenClaw } catch {} })
$mStopAll.Add_Click({  try { Stop-OpenClaw; Stop-Hermes }   catch {} })
$mSettings.Add_Click({ Show-SettingsDialog })
$mQuit.Add_Click({     $script:forceClose = $true; $script:trayIcon.Visible = $false; $form.Close() })

$script:trayIcon.ContextMenuStrip = $trayMenu
$script:trayIcon.Add_DoubleClick({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })
$script:trayIcon.Add_BalloonTipClicked({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })

# Track whether we've already shown the hide-to-tray hint (show only once)
$script:hideHintShown = $false

# Close button -> hide to tray (only Quit from tray menu actually exits)
$script:forceClose = $false
$form.Add_FormClosing({
    param($s, $e)
    if (-not $script:forceClose) {
        $e.Cancel = $true
        $form.Hide()
        if (-not $script:hideHintShown) {
            $script:trayIcon.ShowBalloonTip(2000, 'Agent Control', 'Running in the system tray. Right-click the icon to quit.', 'Info')
            $script:hideHintShown = $true
        }
    }
})

# Minimize button -> also hide to tray
$form.Add_Resize({
    if ($form.WindowState -eq 'Minimized') {
        $form.Hide()
        if (-not $script:hideHintShown) {
            $script:trayIcon.ShowBalloonTip(1500, 'Agent Control', 'Running in the system tray.', 'Info')
            $script:hideHintShown = $true
        }
    }
})

# ── Keyboard shortcuts ────────────────────────────────────────────────────────
$form.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq 'F5') {
        Refresh-Hermes; Refresh-OpenClaw; Add-Log 'All statuses refreshed (F5).'
        $e.Handled = $true
    }
    if ($e.Control -and $e.KeyCode -eq 'L') {
        $logBox.Clear(); $e.Handled = $true
    }
})

# ── Startup ────────────────────────────────────────────────────────────────────
$form.Add_Shown({
    if ($StartMinimized) {
        # Already minimized by WindowState; Resize event will hide to tray.
        # Show startup balloon only once.
        if (-not $script:hideHintShown) {
            $script:trayIcon.ShowBalloonTip(2000, 'Agent Control', 'Running in the system tray. Double-click to open.', 'Info')
            $script:hideHintShown = $true
        }
        Add-Log 'Started minimized to system tray.'
    }
    Add-Log "Ready.  Auto-refresh every $($script:autoRefreshSeconds)s.  F5 = refresh  ·  Ctrl+L = clear log"
    foreach ($warning in $script:SettingsWarnings) { Add-Log "Settings warning: $warning" }
    $diag = Get-EnvironmentDiagnostics
    Add-Log ("Diagnostics: wsl.exe $(if ($diag.WslExeFound) {'found'} else {'MISSING'}), " +
             "openclaw $(if ($diag.OpenClawCliFound) {'found'} else {'MISSING'}).")
    # Sync startup shortcut with current setting
    Set-StartupWithWindows -Enable $script:Settings.StartWithWindows
    Refresh-Hermes
    Refresh-OpenClaw
    Refresh-Versions
})

$form.Add_FormClosed({
    $script:mainTimer.Stop(); $script:mainTimer.Dispose()
    $script:trayIcon.Visible = $false
    $script:trayIcon.Dispose()
    # Dispose the shared app icon once (both tray and form reference it)
    if ($script:appIcon) { $script:appIcon.Dispose() }
})

# Start minimized to tray if requested
if ($StartMinimized) {
    $form.WindowState = 'Minimized'
    # Do NOT call $form.Hide() here. Let the Resize event handle it after
    # Application.Run() shows the form. The message loop keeps the process alive.
}

[System.Windows.Forms.Application]::Run($form)
