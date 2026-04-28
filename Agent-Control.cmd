@echo off
setlocal
set "PWSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PWSH%" set "PWSH=powershell.exe"
start "Agent Control" "%PWSH%" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Agent-Control.ps1"
