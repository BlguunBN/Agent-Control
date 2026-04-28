Set shell = CreateObject("WScript.Shell")
scriptPath = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName) & "\\Agent-Control.ps1"
cmd = """" & CreateObject("WScript.Shell").ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe" & """ -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """" & scriptPath & """""
shell.Run cmd, 0, False
