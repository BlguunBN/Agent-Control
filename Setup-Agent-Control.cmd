@echo off
setlocal
set "PWSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PWSH%" set "PWSH=powershell.exe"
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-Agent-Control.ps1" %*
pause
