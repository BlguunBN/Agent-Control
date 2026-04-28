# Agent Control

Small Windows control panel for:

- **Hermes** on WSL via `systemctl --user`
- **OpenClaw** on Windows via localhost TCP listener `127.0.0.1:18789`

## Easy setup

1. Run `Setup-Agent-Control.cmd`
2. It installs the files to `%LOCALAPPDATA%\Agent-Control`
3. It writes `Agent-Control.settings.json`
4. It creates shortcuts on the Desktop and Start Menu

## Run it

- Open `Agent-Control.cmd`
- Or use the shortcut created by setup

## Configuration

The app auto-loads `Agent-Control.settings.json` from the same folder as the script.

Useful settings:

- `HermesDistro` — WSL distro name for Hermes
- `OpenClawPort` — TCP port to watch for OpenClaw
- `AutoRefreshSeconds` — refresh interval for the UI

If the config file is missing, the app creates one with sensible defaults on first launch.
