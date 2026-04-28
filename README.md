# Agent Control

Agent Control is a small Windows tray-style control panel for two services:

- Hermes on WSL, checked through `systemctl --user`
- OpenClaw on Windows, checked through a localhost TCP listener on `127.0.0.1:18789`

## What is in the repo

- `Agent-Control.ps1` - main Windows Forms UI
- `Agent-Control.cmd` - launcher for the UI
- `Agent-Control-Launcher.cs` - hidden launcher for the compiled entry point
- `Setup-Agent-Control.ps1` - installs the app and creates shortcuts
- `Setup-Agent-Control.cmd` - launcher for the setup script

## Setup

1. Run `Setup-Agent-Control.cmd`
2. The setup script installs the files to `%LOCALAPPDATA%\Agent-Control`
3. It writes `Agent-Control.settings.json`
4. It creates shortcuts on the Desktop and in the Start Menu

## Run

- Open `Agent-Control.cmd`
- Or use the shortcut created by setup

## Configuration

The app loads `Agent-Control.settings.json` from the same folder as the script.

Available settings:

- `HermesDistro` - WSL distro name for Hermes
- `OpenClawPort` - TCP port watched for OpenClaw
- `AutoRefreshSeconds` - refresh interval for the UI

If the config file is missing, the app creates one with default values on first launch.
