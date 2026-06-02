<p align="center">
  <img src="https://img.shields.io/badge/status-active-brightgreen" alt="Status">
  <img src="https://img.shields.io/github/license/BlguunBN/Agent-Control" alt="License">
  <img src="https://img.shields.io/badge/platform-Windows%20%7C%20WSL-blue" alt="Platform">
  <img src="https://img.shields.io/badge/powershell-5.1%2B-5391FE" alt="PowerShell">
  <br>
  <img src="https://img.shields.io/badge/Hermes-v0.12%2B-8B5CF6" alt="Hermes">
  <img src="https://img.shields.io/badge/OpenClaw-2026.4%2B-10B981" alt="OpenClaw">
</p>

<h1 align="center">🤖 Agent Control</h1>
<p align="center"><i>A dark-themed Windows control panel for Hermes (WSL) and OpenClaw (Windows) — start, stop, and monitor your AI agents without opening a terminal.</i></p>

<p align="center">
  <b>Start both agents · Stop both agents · One-click status · Auto-refresh</b>
</p>

---

## ✨ Features

- 🎛️ **Dual-agent control** — Start/Stop/**Restart**/Status for both Hermes and OpenClaw in one window
- 🔍 **Smart auto-detection** — Auto-discovers WSL distros, Hermes installation, and OpenClaw CLI
- 🩺 **Crash-loop detection** — Detects when Hermes is restart-cycling and warns you (orange) instead of showing a false green "Active"
- 🕒 **Auto-refresh** — Updates status every 15s (configurable). Pauses when minimized
- 🎨 **OLED dark theme** — Easy on the eyes, matches modern terminal aesthetics
- 📋 **Live log panel** — Timestamped activity log for all actions + **export to file**
- 🔒 **Safety checks** — Validates port-owning processes before killing, guards against missing CLIs
- 🪶 **Lightweight** — Pure PowerShell 5.1 with Windows Forms. No dependencies to install
- 🚀 **One-click setup** — `Setup-Agent-Control.ps1` detects, installs, and configures everything
- ⚙️ **In-app settings** — Change WSL distro, port, and refresh interval without editing JSON
- 🔔 **System tray** — Minimize to tray; balloon notifications on status changes. Tray icon changes color dynamically (green=all good, orange=warning, red=down). Hover tooltip shows live agent states. Right-click menu includes quick actions and a Settings shortcut.
- 🏁 **Start with Windows** — Optional auto-start minimized to tray on Windows login
- 🩺 **HTTP health check** — OpenClaw status verifies gateway HTTP response, not just TCP port
- 🏷️ **Version detection** — Auto-detects and shows installed Hermes and OpenClaw versions
- ⌨️ **Keyboard shortcuts** — F5 = Refresh All, Ctrl+L = Clear log

## 📸 Preview

```
┌─────────────────────────────────────────────────────────────┐
│  Agent Control                                     🔵 AUTO  │
│  Hermes (WSL)  •  OpenClaw (Windows)              PORT-FIRST │
├─────────────────────────────────────────────────────────────┤
│  ┌──────────────────┐  ┌──────────────────┐                 │
│  │ 🔵 HERMES        │  │ 🟢 OPENCLAW      │                 │
│  │ WSL Ubuntu       │  │ Windows TCP:18789 │                 │
│  │                  │  │                  │                 │
│  │ Active (systemd) │  │ Listening on     │                 │
│  │                  │  │ :18789 (node)    │                 │
│  │ [Start]  [Stop]  │  │ [Start]  [Stop]  │                 │
│  │ [Status] [Restart]  [Status] [Restart] │                 │
│  └──────────────────┘  └──────────────────┘                 │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ [Start Both] [Stop Both] [Refresh All] [Auto: ON]   │   │
│  └──────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ LOG                                              [Clear]│   │
│  │ [10:52:48] Ready. Auto-refresh every 15s.              │   │
│  │ [10:52:48] Diagnostics: wsl.exe ✓, cmd.exe ✓,         │   │
│  │            openclaw ✓                                  │   │
│  │ [10:52:49] Hermes: Active (systemd)                    │   │
│  │ [10:52:49] OpenClaw: Listening on :18789 (node)        │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## 🚀 Quick Start

### Option 1: One-click setup (recommended)

```cmd
git clone https://github.com/BlguunBN/Agent-Control.git
cd agent-control
Setup-Agent-Control.cmd
```

The setup script will:
1. **Detect** — Check your system for WSL, Hermes, OpenClaw, Node.js, and Git
2. **Report** — Show exactly what's installed and what's missing
3. **Install** — Offer to install missing components automatically:
   - WSL2 + Ubuntu (if not present)
   - Hermes inside WSL (via official install script)
   - OpenClaw on Windows (via `npm install -g openclaw`)
4. **Configure** — Copy the GUI, write settings, create desktop and Start Menu shortcuts

### Option 2: Fully automatic (no prompts)

```cmd
Setup-Agent-Control.cmd -AutoInstall
```

Installs everything missing without asking — useful for provisioning new machines.

### Option 3: Manual setup

1. Make sure you have [WSL](https://learn.microsoft.com/en-us/windows/wsl/install) with a Linux distro
2. Install [Hermes](https://github.com/NousResearch/hermes-agent) inside WSL
3. Install [OpenClaw](https://github.com/openclaw) on Windows
4. Run `Setup-Agent-Control.cmd` (or just launch `Agent-Control.cmd`)

## 🤖 Set Up with an AI Agent

Paste the prompt below into any AI coding assistant (Claude Code, GitHub Copilot, Cursor, etc.) and it will walk you through the full installation — detecting what you have, installing what you need, and launching the app.

````markdown
I want to set up **Agent Control** on my Windows machine — a GUI control panel for managing Hermes (WSL) and OpenClaw (Windows) AI agents.

Repo: https://github.com/BlguunBN/Agent-Control

Please help me through the setup end-to-end:

1. **Clone the repo** (if I haven't already):
   ```cmd
   git clone https://github.com/BlguunBN/Agent-Control.git
   cd Agent-Control
   ```

2. **Run the setup script** — it auto-detects everything:
   ```cmd
   Setup-Agent-Control.cmd
   ```
   Or fully automatic (no prompts):
   ```cmd
   Setup-Agent-Control.cmd -AutoInstall
   ```

3. **What the setup checks for:**
   - Windows 10/11 with WSL2
   - A WSL Linux distro (Ubuntu recommended) with Hermes installed (`hermes --version`)
   - OpenClaw on Windows (`npm install -g openclaw`)
   - Node.js (required by OpenClaw)

4. **If anything is missing**, guide me through installing it:
   - WSL2: `wsl --install` (requires restart)
   - Hermes in WSL: follow the official Hermes install script inside the distro
   - OpenClaw: `npm install -g openclaw`
   - Node.js: download from https://nodejs.org

5. **Settings file** (`Agent-Control.settings.json`, auto-created):
   ```json
   {
       "HermesDistro":       "Ubuntu",
       "OpenClawPort":       18789,
       "AutoRefreshSeconds": 15,
       "StartWithWindows":   false
   }
   ```
   If my WSL distro has a different name (run `wsl --list --quiet` to check), update `HermesDistro` to match. If my distro name contains "hermes", it will be auto-selected.

6. **Launch the app** once setup is complete:
   ```cmd
   Agent-Control.cmd
   ```
   Or double-click `Agent Control GUI.exe` for a no-window launch that starts minimized to the system tray.

7. **Common problems to check if something isn't working:**
   - Hermes shows "Active" but crash-looping → check `wsl -d Ubuntu -- systemctl --user show hermes-gateway -p NRestarts --value`; reset with `systemctl --user reset-failed hermes-gateway`
   - OpenClaw not detected → run `where openclaw` in cmd; reinstall with `npm install -g openclaw`
   - "Access is denied" stopping OpenClaw → relaunch Agent Control as Administrator
   - Tray icon missing → the app may be minimized; check the system tray overflow area

Please check my system, run the relevant commands, and fix any issues you find.
````

## 🖱️ Usage

### Controls

| Button | What it does |
|--------|-------------|
| **Start** | Starts the selected agent |
| **Stop** | Stops the selected agent |
| **Status** | Refreshes the selected agent's status |
| **Restart** | Stops then starts the selected agent in one click |
| **Start Both** | Starts Hermes + OpenClaw in sequence |
| **Stop Both** | Stops OpenClaw + Hermes in sequence |
| **Refresh All** | Refreshes both agent statuses |
| **Auto: ON/OFF** | Toggles the auto-refresh timer |
| **Settings** | Opens in-app settings dialog |
| **Export** (log) | Saves the current log to a .txt file |

### Keyboard shortcuts

| Key | Action |
|-----|--------|
| **F5** | Refresh all statuses |
| **Ctrl+L** | Clear the log |

### Status indicators

| Status | Meaning |
|--------|---------|
| 🟢 **Active (systemd)** | Hermes gateway is running normally |
| 🟠 **Crash-looping (N restarts)** | Hermes keeps restarting (N ≥ 5 restarts detected) |
| 🔴 **Not active** | Gateway is stopped / in failed state |
| 🔴 **WSL unavailable** | WSL distro can't be reached |
| 🟢 **Listening on :port** | OpenClaw gateway is accepting connections |
| 🔴 **Not listening** | Nothing is listening on the OpenClaw port |
| 🔴 **CLI missing** | `openclaw` command not found in PATH |

## 🔧 Configuration

Settings are stored in `Agent-Control.settings.json` (auto-created in the app folder):

```json
{
    "HermesDistro":       "Ubuntu",
    "OpenClawPort":       18789,
    "AutoRefreshSeconds": 15,
    "StartWithWindows":   false
}
```

| Setting | Default | Description |
|---------|---------|-------------|
| `HermesDistro` | `Ubuntu` | WSL distro name where Hermes is installed |
| `OpenClawPort` | `18789` | TCP port to watch for OpenClaw |
| `AutoRefreshSeconds` | `15` | Status refresh interval (1–3600) |
| `StartWithWindows` | `false` | Auto-start minimized to tray on Windows login |

### Override via environment

Set `HERMES_WSL_DISTRO` before launching the app to override the WSL distro without editing the settings file.

## 🔍 Detection Logic

When you run `Setup-Agent-Control.ps1`, it checks across your system:

```
┌─ OS ───────────────────┐
│ Windows 10/11 build     │──→ WSL install method
└─────────────────────────┘

┌─ WSL ──────────────────┐
│ wsl --list --quiet      │──→ Available distros
└─────────────────────────┘

┌─ HERMES ───────────────┐
│ For each WSL distro:   │
│  ├─ hermes --version   │──→ CLI installed?
│  ├─ systemctl is-active│──→ Gateway running?
│  └─ NRestarts          │──→ Crash-looping?
└─────────────────────────┘

┌─ OPENCLAW ─────────────┘
│  ├─ PATH / npm-global  │──→ CLI installed?
│  └─ TCP :18789         │──→ Gateway listening?
└─────────────────────────┘
```

## 🛠️ Development

### Prerequisites

- Windows 10/11 with PowerShell 5.1+
- (Optional) [csc.exe](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/compiler-options/) to recompile the C# launcher

### Build the launcher EXE

If you modify `Agent-Control-Launcher.cs`, recompile the hidden launcher:

```cmd
:: From a Visual Studio Developer Command Prompt:
csc.exe -target:winexe -out:"Agent Control GUI.exe" Agent-Control-Launcher.cs

:: Or from PowerShell:
Add-Type -TypeDefinition (Get-Content Agent-Control-Launcher.cs -Raw) -OutputAssembly "Agent Control GUI.exe" -OutputType WindowsApplication
```

### Project Structure

```
Agent-Control/
├── Agent-Control.ps1                 # Main GUI (Windows Forms)
├── Agent-Control.cmd                 # Launcher (visible window)
├── Agent-Control.vbs                 # Launcher (hidden, legacy)
├── Agent-Control-Launcher.cs         # C# launcher source
├── Agent Control GUI.exe             # Compiled launcher
├── Agent-Control.settings.json       # User settings (gitignored)
├── Setup-Agent-Control.ps1           # Setup + detector + installer
├── Setup-Agent-Control.cmd           # Setup launcher
└── README.md
```

### Coding conventions

- PowerShell 5.1 compatible (no `using` statements, `ForEach-Object`, script-scoped variables with `$script:`)
- Windows Forms only (no WPF dependency)
- Async background jobs with `Start-Job` + polling timer (never block the UI thread)
- OLED dark palette in `$C` hash table at the top of `Agent-Control.ps1`

## ⚠️ Troubleshooting

### "Access is denied" when stopping OpenClaw

OpenClaw may be running with elevated privileges. Try launching Agent Control as Administrator before clicking Stop, or use `taskkill /F /PID <pid>` from an elevated terminal.

### Hermes shows "Active" but isn't responding

The gateway can be systemd-active but crash-looping behind the scenes. Check the restart count: `wsl -d Ubuntu -- systemctl --user show hermes-gateway -p NRestarts --value`. Agent Control now warns you when NRestarts ≥ 5.

### Gateway keeps restarting

We added restart limits to the systemd service. If the gateway has failed 5 times within 10 minutes, systemd stops retrying. Reset it manually:
```cmd
wsl -d Ubuntu -- systemctl --user reset-failed hermes-gateway
wsl -d Ubuntu -- systemctl --user restart hermes-gateway
```

### OpenClaw not detected

Run `where openclaw` from a command prompt. If not found, install it:
```cmd
npm install -g openclaw
```

## 📄 License

MIT — do whatever you want with it.

---

<p align="center">
  Built because clicking Start/Stop in a terminal is boring.<br>
  <a href="https://github.com/BlguunBN/Agent-Control/issues">Report an issue</a> ·
  <a href="https://github.com/BlguunBN/Agent-Control/discussions">Start a discussion</a>
</p>
