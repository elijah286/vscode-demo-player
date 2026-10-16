using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Forms;

internal static class Launcher
{
    private static string Quote(string value)
    {
        var result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char character in value)
        {
            if (character == '\\') { slashes++; continue; }
            if (character == '"') result.Append('\\', slashes * 2 + 1);
            else result.Append('\\', slashes);
            result.Append(character);
            slashes = 0;
        }
        return result.Append('\\', slashes * 2).Append('"').ToString();
    }

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            string root = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(root, "Start-InstalledPlayer.ps1");
            if (!File.Exists(script)) throw new FileNotFoundException("The installation is incomplete. Reinstall VS Code Demo Player.", script);
            var arguments = new StringBuilder("-NoProfile -STA -ExecutionPolicy Bypass -File ").Append(Quote(script));
            foreach (string argument in args) arguments.Append(' ').Append(Quote(argument));
            var start = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe"),
                Arguments = arguments.ToString(),
                WorkingDirectory = root,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using (Process process = Process.Start(start))
            {
                if (process == null) throw new InvalidOperationException("The application could not be started.");
            }
            return 0;
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "VS Code Demo Player - startup failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
