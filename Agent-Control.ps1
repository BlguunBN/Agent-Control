Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# ── App configuration ───────────────────────────────────────────────────────
$script:AppRoot     = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:SettingsPath = Join-Path $script:AppRoot 'Agent-Control.settings.json'
$script:SettingsWarnings = @()

function Get-DefaultSettings {
    [pscustomobject]@{
        HermesDistro      = $null
        OpenClawPort      = 18789
        AutoRefreshSeconds = 15
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
        $raw = Get-Content -Path $script:SettingsPath -Raw -ErrorAction Stop
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
                $script:SettingsWarnings += "Invalid OpenClawPort '$($data.OpenClawPort)' in settings; using default $($settings.OpenClawPort)."
            }
        }

        if ($props -contains 'AutoRefreshSeconds') {
            $seconds = 0
            if ([int]::TryParse([string]$data.AutoRefreshSeconds, [ref]$seconds) -and $seconds -ge 1 -and $seconds -le 3600) {
                $settings.AutoRefreshSeconds = $seconds
            } else {
                $script:SettingsWarnings += "Invalid AutoRefreshSeconds '$($data.AutoRefreshSeconds)' in settings; using default $($settings.AutoRefreshSeconds)."
            }
        }
    } catch {
        # Leave defaults in place; the setup script can repair the file later.
        $script:SettingsWarnings += "Failed to parse settings file; using defaults. $($_.Exception.Message)"
    }
    return $settings
}

# ── System paths ────────────────────────────────────────────────────────────
$wslExe        = Join-Path $env:SystemRoot 'System32\wsl.exe'
$cmdExe        = Join-Path $env:SystemRoot 'System32\cmd.exe'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

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
    if ($env:HERMES_WSL_DISTRO -and ($distros -contains $env:HERMES_WSL_DISTRO)) { return $env:HERMES_WSL_DISTRO }
    if ($distros -contains 'Ubuntu') { return 'Ubuntu' }
    if ($distros.Count -eq 1) { return $distros[0] }
    if ($distros.Count -gt 0) { return $distros[0] }
    return if ($Preferred) { $Preferred } else { 'Ubuntu' }
}

$script:Settings = Load-AgentControlSettings
$distro        = Resolve-HermesDistro $script:Settings.HermesDistro
$openClawPort  = if ($script:Settings.OpenClawPort) { [int]$script:Settings.OpenClawPort } else { 18789 }
$autoRefreshSeconds = if ($script:Settings.AutoRefreshSeconds) { [int]$script:Settings.AutoRefreshSeconds } else { 15 }
$autoRefreshMs = [Math]::Max(1000, $autoRefreshSeconds * 1000)
if (-not (Test-Path $script:SettingsPath)) {
    $script:Settings.HermesDistro = $distro
    $script:Settings.OpenClawPort = $openClawPort
    $script:Settings.AutoRefreshSeconds = $autoRefreshSeconds
    Save-AgentControlSettings $script:Settings
}

# ── OLED dark palette ────────────────────────────────────────────────────────
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
    Border    = rgb 43  47  62
    TxtPri    = rgb 239 242 247
    TxtMuted  = rgb 132 139 155
    Green     = rgb 74  222 128
    Red       = rgb 248 113 113
    Orange    = rgb 251 146 60
    Blue      = rgb 99  102 241
}

# ── Log box declared early so Add-Log can reference it ──────────────────────
$logBox = New-Object System.Windows.Forms.TextBox
$script:autoEnabled = $true

# ── Core helpers ─────────────────────────────────────────────────────────────
function Add-Log {
    param([string]$Message)
    $stamp = Get-Date -Format 'HH:mm:ss'
    $logBox.AppendText("[$stamp] $Message`r`n")
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
}

# ── Async helper ──────────────────────────────────────────────────────────────
# Runs $Work in a Start-Job background process, then calls $Done on the UI
# thread once the job completes. Uses $script:asyncJobs keyed by timer .Tag to
# avoid PS 5.1 closure-capture issues with Add_Tick handlers.
$script:asyncJobs = @{}
function Invoke-Async {
    param(
        [scriptblock]$Work,
        [object[]]$WorkArgs = @(),
        [scriptblock]$Done  = {}
    )
    $id  = [System.Guid]::NewGuid().ToString()
    $job = Start-Job -ScriptBlock $Work -ArgumentList $WorkArgs
    $script:asyncJobs[$id] = @{ Job = $job; Done = $Done }
    $poll          = New-Object System.Windows.Forms.Timer
    $poll.Interval = 500
    $poll.Tag      = $id
    $poll.Add_Tick({
        param($sender, $e)
        $id    = $sender.Tag
        $entry = $script:asyncJobs[$id]
        if (-not $entry -or $entry.Job.State -eq 'Running') { return }
        $sender.Stop(); $sender.Dispose()
        $res = @()
        try { $res = @(Receive-Job -Job $entry.Job -ErrorAction SilentlyContinue) } catch {}
        try { Remove-Job  -Job $entry.Job -Force  -ErrorAction SilentlyContinue } catch {}
        $script:asyncJobs.Remove($id) | Out-Null
        try { & $entry.Done $res } catch {}
    })
    $poll.Start()
}

# ── Service state updaters ────────────────────────────────────────────────────
$script:hermesStatusLabel   = $null
$script:hermesDot           = $null
$script:openClawStatusLabel = $null
$script:openClawDot         = $null
$script:hermesRefreshBusy   = $false
$script:openClawRefreshBusy = $false

function Set-HermesState {
    param([string]$Text,[System.Drawing.Color]$Color)
    $script:hermesStatusLabel.Text      = $Text
    $script:hermesStatusLabel.ForeColor = $Color
    $script:hermesDot.Tag = $Color
    $script:hermesDot.Invalidate()
}

function Set-OpenClawState {
    param([string]$Text,[System.Drawing.Color]$Color)
    $script:openClawStatusLabel.Text      = $Text
    $script:openClawStatusLabel.ForeColor = $Color
    $script:openClawDot.Tag = $Color
    $script:openClawDot.Invalidate()
}

function Refresh-Hermes {
    if ($script:hermesRefreshBusy) { return }
    $script:hermesRefreshBusy = $true
    Set-HermesState '...' $C.TxtMuted
    $wsl = $wslExe; $dist = $distro
    Invoke-Async -Work {
        param($exe, $d)
        $maxRetries = 2; $retryDelay = 2
        $wslReady = $true; $exit = 1; $output = ''
        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            $proc = & $exe -d $d -- bash -lc 'systemctl --user is-active hermes-gateway' 2>&1
            $exit = $LASTEXITCODE
            $output = (($proc | Out-String) -replace "`0", '').Trim()
            if ($output -match '(?i)failed to attach disk|access is denied|createinstance|mountdisk') {
                $wslReady = $false; break
            }
            if ($exit -eq 0 -or $output -eq 'active') { break }
            Start-Sleep -Seconds $retryDelay
        }
        # Get restart count to detect crash loops
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
            if ($r.NRestarts -ge 5) {
                Set-HermesState "Crash-looping ($($r.NRestarts) restarts)" $C.Orange
            } else {
                Set-HermesState 'Active (systemd)' $C.Green
            }
        }
        elseif ($r.Output -match '(?i)inactive|failed|dead|stopped') { Set-HermesState 'Not active' $C.Red }
        else { Set-HermesState 'Unknown' $C.Orange }
    }
}

function Get-OpenClawListener {
    param([int]$Port)
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $conn) { return $null }
    $owner = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
    $ownerPath = $null
    try { $ownerPath = $owner.Path } catch {}
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
    $path = if ($Listener.Path) { $Listener.Path.ToLowerInvariant() } else { '' }

    if ($cmd -match 'openclaw') { return $true }
    if ($path -match 'openclaw') { return $true }
    if (($name -eq 'openclaw') -or ($name -eq 'openclaw.exe')) { return $true }
    if ($name -eq 'node' -and $cmd -match 'gateway') { return $true }
    return $false
}

function Get-EnvironmentDiagnostics {
    $wslExists = Test-Path $wslExe
    $cmdExists = Test-Path $cmdExe
    $openClawCli = $false
    if ($cmdExists) {
        try {
            $null = & $cmdExe /c 'where openclaw' 2>$null
            $openClawCli = ($LASTEXITCODE -eq 0)
        } catch {
            $openClawCli = $false
        }
    }
    [pscustomobject]@{
        WslExeFound     = $wslExists
        CmdExeFound     = $cmdExists
        OpenClawCliFound = $openClawCli
    }
}

function Refresh-OpenClaw {
    if ($script:openClawRefreshBusy) { return }
    $script:openClawRefreshBusy = $true
    Set-OpenClawState '...' $C.TxtMuted
    $port = $openClawPort; $cmd = $cmdExe
    Invoke-Async -Work {
        param($c, $p)
        $conn = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($conn) {
            $owner = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
            return [pscustomobject]@{
                Type        = 'listener'
                Pid         = $conn.OwningProcess
                ProcessName = if ($owner) { $owner.ProcessName } else { $null }
            }
        }
        $proc = & $c /c 'openclaw gateway status' 2>&1
        [pscustomobject]@{ Type = 'status'; Output = ($proc | Out-String).Trim() }
    } -WorkArgs @($cmd, $port) -Done {
        param($res)
        $script:openClawRefreshBusy = $false
        $r = if ($res) { $res[0] } else { $null }
        if (-not $r) { Set-OpenClawState 'Unknown' $C.Orange; return }
        if ($r.Type -eq 'listener') {
            $name = if ($r.ProcessName) { $r.ProcessName } else { 'listener' }
            Set-OpenClawState "Listening on :$openClawPort ($name PID $($r.Pid))" $C.Green
        }
        elseif ($r.Output -match '(?i)disabled|stopped|not running|failed') { Set-OpenClawState 'Not listening' $C.Red }
        else { Set-OpenClawState 'Unknown' $C.Orange }
    }
}

function Start-Hermes {
    Add-Log 'Starting Hermes gateway...'
    Set-HermesState 'Starting...' $C.Orange
    $wsl = $wslExe; $dist = $distro
    Invoke-Async -Work {
        param($exe, $d)
        $proc = & $exe -d $d -- bash -lc 'systemctl --user start hermes-gateway' 2>&1
        $exit = $LASTEXITCODE
        $output = (($proc | Out-String) -replace "`0", '').Trim()
        $wslReady = $true
        if ($exit -ne 0 -and $output -match '(?i)failed to attach disk|access is denied|createinstance|mountdisk') {
            $wslReady = $false
        }
        [pscustomobject]@{
            ExitCode = $exit
            Output   = $output
            WslReady = $wslReady
        }
    } -WorkArgs @($wsl, $dist) -Done {
        param($res)
        $r = if ($res) { $res[0] } else { $null }
        if ($r -and $r.ExitCode -eq 0) {
            Add-Log 'Hermes start sent; verifying status...'
        }
        elseif ($r -and -not $r.WslReady) {
            Add-Log "Hermes gateway start failed: WSL distro '$dist' is unavailable. $($r.Output)"
        }
        else {
            Add-Log "Hermes gateway start failed: $(if ($r) { $r.Output } else { 'no result' })"
        }
        Refresh-Hermes
    }
}

function Stop-Hermes {
    Add-Log 'Stopping Hermes gateway...'
    Set-HermesState 'Stopping...' $C.Orange
    $wsl = $wslExe; $dist = $distro
    Invoke-Async -Work {
        param($exe, $d)
        $proc = & $exe -d $d -- bash -lc 'systemctl --user stop hermes-gateway' 2>&1
        $exit = $LASTEXITCODE
        $output = (($proc | Out-String) -replace "`0", '').Trim()
        $wslReady = $true
        if ($exit -ne 0 -and $output -match '(?i)failed to attach disk|access is denied|createinstance|mountdisk') {
            $wslReady = $false
        }
        [pscustomobject]@{
            ExitCode = $exit
            Output   = $output
            WslReady = $wslReady
        }
    } -WorkArgs @($wsl, $dist) -Done {
        param($res)
        $r = if ($res) { $res[0] } else { $null }
        if ($r -and $r.ExitCode -eq 0) {
            Add-Log 'Hermes gateway stopped successfully.'
        }
        elseif ($r -and -not $r.WslReady) {
            Add-Log "Hermes gateway stop failed: WSL distro '$dist' is unavailable. $($r.Output)"
        }
        else {
            Add-Log "Hermes gateway stop failed: $(if ($r) { $r.Output } else { 'no result' })"
        }
        Refresh-Hermes
    }
}

function Start-OpenClaw {
    # Verify CLI is available first
    $null = & $cmdExe /c 'where openclaw' 2>$null
    if ($LASTEXITCODE -ne 0) {
        Add-Log 'OpenClaw CLI not found in PATH. Cannot start.'
        Set-OpenClawState 'CLI missing' $C.Red
        return
    }
    $port = $openClawPort; $cmd = $cmdExe
    $listener = Get-OpenClawListener -Port $port
    if ($listener) {
        $name = if ($listener.ProcessName) { $listener.ProcessName } else { 'listener' }
        Add-Log "OpenClaw already listening ($name PID $($listener.Pid))."
        Refresh-OpenClaw; return
    }
    Add-Log 'Starting OpenClaw gateway (takes ~15s to be ready)...'
    Set-OpenClawState 'Starting...' $C.Orange
    Invoke-Async -Work {
        param($c, $p)
        $out  = & $c /c 'openclaw gateway start' 2>&1
        $exit = $LASTEXITCODE
        $startMsg = ($out | Out-String).Trim()
        # Poll up to 35 s for the gateway to begin listening
        $deadline  = (Get-Date).AddSeconds(35)
        $listening = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            $conn = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($conn) { $listening = $true; break }
        }
        $pid2 = if ($listening) {
            (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1).OwningProcess
        } else { 0 }
        [pscustomobject]@{ ExitCode = $exit; StartMsg = $startMsg; Listening = $listening; ListenPid = $pid2 }
    } -WorkArgs @($cmd, $port) -Done {
        param($res)
        $r = if ($res) { $res[0] } else { $null }
        if ($r -and $r.Listening) {
            Add-Log "OpenClaw is listening (PID $($r.ListenPid))."
        } elseif ($r -and $r.ExitCode -eq 0) {
            Add-Log "OpenClaw start returned success, but it is still not listening after 35s. $($r.StartMsg)"
        } else {
            Add-Log "OpenClaw start failed: $(if ($r) { $r.StartMsg } else { 'no result' })"
        }
        Refresh-OpenClaw
    }
}

function Stop-OpenClaw {
    $port = $openClawPort; $cmd = $cmdExe
    $listener = Get-OpenClawListener -Port $port
    if (-not $listener) { Add-Log 'OpenClaw is not listening.'; Refresh-OpenClaw; return }
    $listenerPid = $listener.Pid
    Add-Log "Stopping OpenClaw (PID $listenerPid)..."
    Set-OpenClawState 'Stopping...' $C.Orange
    Invoke-Async -Work {
        param($c, $p)
        $logs = [System.Collections.Generic.List[string]]::new()
        function Get-Listener([int]$Port) {
            $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $conn) { return $null }
            $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
            $procName = if ($proc) { $proc.ProcessName } else { $null }
            $cmdLine = $null
            try {
                $w = Get-CimInstance Win32_Process -Filter "ProcessId = $($conn.OwningProcess)" -ErrorAction SilentlyContinue
                if ($w) { $cmdLine = $w.CommandLine }
            } catch {}
            [pscustomobject]@{
                Pid         = $conn.OwningProcess
                ProcessName = $procName
                CommandLine = $cmdLine
            }
        }
        function Is-ExpectedGateway($l) {
            if (-not $l) { return $false }
            $name = if ($l.ProcessName) { $l.ProcessName.ToLowerInvariant() } else { '' }
            $cmdLine = if ($l.CommandLine) { $l.CommandLine.ToLowerInvariant() } else { '' }
            if ($cmdLine -match 'openclaw') { return $true }
            if (($name -eq 'openclaw') -or ($name -eq 'openclaw.exe')) { return $true }
            if ($name -eq 'node' -and $cmdLine -match 'gateway') { return $true }
            return $false
        }
        try {
            # Stop the scheduled task so it does not auto-restart
            $taskOut = & $c /c 'openclaw gateway stop' 2>&1
            $logs.Add("Task stop: $(($taskOut | Out-String).Trim())")
            # Kill the detached node process that openclaw gateway stop leaves alive
            $listener2 = Get-Listener -Port $p
            if ($listener2) {
                if (-not (Is-ExpectedGateway $listener2)) {
                    $logs.Add("Safety stop: process on port $p does not look like OpenClaw (PID $($listener2.Pid), name '$($listener2.ProcessName)'). Skipping kill.")
                } else {
                    $killOut = & $c /c "taskkill /F /PID $($listener2.Pid) /T" 2>&1 | Out-String
                    $killOut.Trim() -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { $logs.Add($_) }
                }
                Start-Sleep -Seconds 1
                $listener2 = Get-Listener -Port $p
            }
        } catch { $logs.Add("Error: $($_.Exception.Message)") }
        [pscustomobject]@{ Logs = $logs.ToArray(); StillRunning = ($null -ne $listener2) }
    } -WorkArgs @($cmd, $port) -Done {
        param($res)
        $r = if ($res) { $res[0] } else { $null }
        if ($r) {
            foreach ($l in $r.Logs) { Add-Log $l }
            if ($r.StillRunning) { Add-Log 'OpenClaw is still listening.' }
            else { Add-Log 'OpenClaw is no longer listening.' }
        }
        Refresh-OpenClaw
    }
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
    param([int]$X,[int]$Y,[int]$W=298,[int]$H=178,[System.Drawing.Color]$Accent)
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

# ════════════════════════════════════════════════════════════════════════════
#  FORM
# ════════════════════════════════════════════════════════════════════════════
$form = New-Object System.Windows.Forms.Form
$form.Text            = 'Agent Control'
$form.Size            = New-Object System.Drawing.Size(680,574)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox     = $false
$form.BackColor       = $C.BgForm
$form.ForeColor       = $C.TxtPri
$form.Font            = New-Object System.Drawing.Font('Segoe UI',9)

# ── Header bar ───────────────────────────────────────────────────────────────
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
$headerMeta.Size      = New-Object System.Drawing.Size(250,30)
$headerMeta.Location  = New-Object System.Drawing.Point(412,18)
$headerMeta.BackColor = $C.BgHeader
$header.Controls.Add($headerMeta)

$badgeMode = New-ChipLabel 'PORT-FIRST' $C.Blue $C.BgBlue
$badgeMode.Location = New-Object System.Drawing.Point(0,0)
$headerMeta.Controls.Add($badgeMode)

$badgeAuto = New-ChipLabel 'AUTO ON' $C.Green $C.BgGreen
$badgeAuto.Location = New-Object System.Drawing.Point(110,0)
$headerMeta.Controls.Add($badgeAuto)

$form.Controls.Add($header)

# ── Service cards ────────────────────────────────────────────────────────────
$cardH  = New-ServiceCard 14  74 320 186 -Accent $C.Blue
$cardOC = New-ServiceCard 346 74 320 186 -Accent $C.Green
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

    @{ Dot = $dot; Status = $lStatus }
}

$hermesWidgets   = Add-CardContent $cardH  'HERMES'   "WSL $distro  ·  systemd service"
$openClawWidgets = Add-CardContent $cardOC 'OPENCLAW' "Windows  ·  TCP :$openClawPort"

$script:hermesDot           = $hermesWidgets.Dot
$script:hermesStatusLabel   = $hermesWidgets.Status
$script:openClawDot         = $openClawWidgets.Dot
$script:openClawStatusLabel = $openClawWidgets.Status

function Add-CardButtons {
    param($card,[scriptblock]$OnStart,[scriptblock]$OnStop,[scriptblock]$OnStatus)
    $bStart  = New-FlatButton 'Start'  -W 90 -H 30 -Bg $C.BgGreen -Fg $C.Green
    $bStop   = New-FlatButton 'Stop'   -W 90 -H 30 -Bg $C.BgRed   -Fg $C.Red
    $bStatus = New-FlatButton 'Status' -W 86 -H 30
    $bStart.Location  = New-Object System.Drawing.Point(14,114)
    $bStop.Location   = New-Object System.Drawing.Point(110,114)
    $bStatus.Location = New-Object System.Drawing.Point(206,114)
    $bStart.Add_Click($OnStart)
    $bStop.Add_Click($OnStop)
    $bStatus.Add_Click($OnStatus)
    $card.Controls.Add($bStart)
    $card.Controls.Add($bStop)
    $card.Controls.Add($bStatus)
}

Add-CardButtons $cardH `
    { try { Start-Hermes }   catch { Add-Log "Hermes start error: $($_.Exception.Message)"   } } `
    { try { Stop-Hermes }    catch { Add-Log "Hermes stop error: $($_.Exception.Message)"    } } `
    { Refresh-Hermes; Add-Log 'Hermes gateway status refreshed.' }

Add-CardButtons $cardOC `
    { try { Start-OpenClaw } catch { Add-Log "OpenClaw start error: $($_.Exception.Message)" } } `
    { try { Stop-OpenClaw }  catch { Add-Log "OpenClaw stop error: $($_.Exception.Message)"  } } `
    { Refresh-OpenClaw; Add-Log 'OpenClaw listener status refreshed.' }

# ── Quick actions ────────────────────────────────────────────────────────────
$actionBar = New-Object System.Windows.Forms.Panel
$actionBar.Size      = New-Object System.Drawing.Size(652,46)
$actionBar.Location  = New-Object System.Drawing.Point(14,272)
$actionBar.BackColor = $C.BgCard
$actionBar.Add_Paint({
    param($s,$e)
    $pen = New-Object System.Drawing.Pen($C.Border,1)
    $e.Graphics.DrawRectangle($pen,0,0,($s.Width-1),($s.Height-1))
    $pen.Dispose()
})
$form.Controls.Add($actionBar)

$btnStartBoth  = New-FlatButton 'Start Both'  -W 154 -H 32 -Bg $C.BgGreen -Fg $C.Green
$btnStopBoth   = New-FlatButton 'Stop Both'   -W 154 -H 32 -Bg $C.BgRed   -Fg $C.Red
$btnRefresh    = New-FlatButton 'Refresh All' -W 154 -H 32
$btnAutoToggle = New-FlatButton 'Auto: ON'    -W 154 -H 32 -Bg $C.BgBlue  -Fg $C.Blue

$btnStartBoth.Location  = New-Object System.Drawing.Point(0,7)
$btnStopBoth.Location   = New-Object System.Drawing.Point(166,7)
$btnRefresh.Location    = New-Object System.Drawing.Point(332,7)
$btnAutoToggle.Location = New-Object System.Drawing.Point(498,7)

$btnStartBoth.Add_Click({
    try { Start-Hermes; Start-OpenClaw }
    catch { Add-Log "Start both error: $($_.Exception.Message)" }
})
$btnStopBoth.Add_Click({
    try { Stop-OpenClaw; Stop-Hermes }
    catch { Add-Log "Stop both error: $($_.Exception.Message)" }
})
$btnRefresh.Add_Click({
    Refresh-Hermes; Refresh-OpenClaw; Add-Log 'All statuses refreshed.'
})
$btnAutoToggle.Add_Click({
    $script:autoEnabled = -not $script:autoEnabled
    if ($script:autoEnabled) {
        $btnAutoToggle.Text      = 'Auto: ON'
        $btnAutoToggle.ForeColor = $C.Blue
        $btnAutoToggle.BackColor = $C.BgBlue
        $badgeAuto.Text = 'AUTO ON'
        $timer.Start()
    } else {
        $btnAutoToggle.Text      = 'Auto: OFF'
        $btnAutoToggle.ForeColor = $C.TxtMuted
        $btnAutoToggle.BackColor = $C.BgBtn
        $badgeAuto.Text = 'AUTO OFF'
        $timer.Stop()
    }
})

$actionBar.Controls.Add($btnStartBoth)
$actionBar.Controls.Add($btnStopBoth)
$actionBar.Controls.Add($btnRefresh)
$actionBar.Controls.Add($btnAutoToggle)

# ── Log panel ────────────────────────────────────────────────────────────────
$logPanel = New-Object System.Windows.Forms.Panel
$logPanel.Size      = New-Object System.Drawing.Size(652,186)
$logPanel.Location  = New-Object System.Drawing.Point(14,328)
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

$btnClear = New-FlatButton 'Clear' -W 60 -H 22
$btnClear.Location = New-Object System.Drawing.Point(580,8)
$btnClear.Add_Click({ $logBox.Clear() })
$logPanel.Controls.Add($btnClear)

$logBox.Multiline   = $true
$logBox.ScrollBars  = 'Vertical'
$logBox.ReadOnly    = $true
$logBox.WordWrap    = $false
$logBox.BackColor   = $C.BgLog
$logBox.ForeColor   = $C.TxtPri
$logBox.BorderStyle = 'None'
$logBox.Font        = New-Object System.Drawing.Font('Consolas',8.5)
$logBox.Size        = New-Object System.Drawing.Size(628,140)
$logBox.Location    = New-Object System.Drawing.Point(12,36)
$logPanel.Controls.Add($logBox)

# ── Auto-refresh timer (15 s) ────────────────────────────────────────────────
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $autoRefreshMs
$timer.Add_Tick({
    if ($form.WindowState -eq 'Minimized') { return }
    Refresh-Hermes
    Refresh-OpenClaw
})
$timer.Start()

# ── Startup ───────────────────────────────────────────────────────────────────
$form.Add_Shown({
    Add-Log "Ready.  Auto-refresh every $autoRefreshSeconds s."
    foreach ($warning in $script:SettingsWarnings) { Add-Log "Settings warning: $warning" }
    $diag = Get-EnvironmentDiagnostics
    Add-Log "Diagnostics: wsl.exe $(if ($diag.WslExeFound) { 'found' } else { 'missing' }), cmd.exe $(if ($diag.CmdExeFound) { 'found' } else { 'missing' }), openclaw CLI $(if ($diag.OpenClawCliFound) { 'found' } else { 'missing' })."

    Refresh-Hermes
    Refresh-OpenClaw
})

$form.Add_FormClosed({ $timer.Stop(); $timer.Dispose() })

[void]$form.ShowDialog()
