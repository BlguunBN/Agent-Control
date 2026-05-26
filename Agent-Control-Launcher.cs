using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        string appDir = Path.GetDirectoryName(Application.ExecutablePath);
        string script = Path.Combine(appDir, "Agent-Control.ps1");

        // Find the best PowerShell available
        string pwsh = FindPowerShell();
        if (pwsh == null)
        {
            MessageBox.Show(
                "PowerShell not found.\n\nPlease install PowerShell 7 from https://aka.ms/powershell or ensure Windows PowerShell is available.",
                "Agent Control — PowerShell Missing",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return;
        }

        if (!File.Exists(script))
        {
            MessageBox.Show(
                string.Format("Script not found:\n{0}", script),
                "Agent Control — Missing File",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return;
        }

        var info = new ProcessStartInfo
        {
            FileName = pwsh,
            Arguments = string.Format("-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"{0}\" -StartMinimized", script),
            WorkingDirectory = appDir,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        };

        try
        {
            Process.Start(info);
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                string.Format("Failed to start Agent Control:\n{0}", ex.Message),
                "Agent Control — Launch Error",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }

    private static string FindPowerShell()
    {
        // Priority: PowerShell 7 (pwsh) > Windows PowerShell (powershell)
        string[] candidates = new string[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"PowerShell\7\pwsh.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), @"PowerShell\7\pwsh.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Microsoft\WindowsApps\pwsh.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\WindowsPowerShell\v1.0\powershell.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"SysWOW64\WindowsPowerShell\v1.0\powershell.exe"),
        };

        foreach (string path in candidates)
        {
            if (File.Exists(path))
                return path;
        }

        // Last resort: search PATH
        string pathEnv = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (string dir in pathEnv.Split(';'))
        {
            if (string.IsNullOrWhiteSpace(dir)) continue;
            foreach (string exe in new string[] { "pwsh.exe", "powershell.exe" })
            {
                string full = Path.Combine(dir.Trim(), exe);
                if (File.Exists(full))
                    return full;
            }
        }

        return null;
    }
}
