using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

internal static class OtaRepairLauncher
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            string script;
            using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("repair.ps1"))
            using (var reader = new StreamReader(stream, Encoding.UTF8, true))
                script = reader.ReadToEnd();

            var command = new StringBuilder("& {\n").Append(script).Append("\n}");
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i] == "-NoUi" || args[i] == "-NoRestart")
                    command.Append(' ').Append(args[i]);
                else if (args[i] == "-InstallRoot" && i + 1 < args.Length)
                    command.Append(" -InstallRoot '").Append(args[++i].Replace("'", "''")).Append('\'');
                else
                    throw new ArgumentException("Invalid repair-tool argument.");
            }

            string encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(command.ToString()));
            string powerShell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                "WindowsPowerShell", "v1.0", "powershell.exe");
            var start = new ProcessStartInfo(powerShell,
                "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand " + encoded);
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.WindowStyle = ProcessWindowStyle.Hidden;
            using (Process process = Process.Start(start))
            {
                process.WaitForExit();
                return process.ExitCode;
            }
        }
        catch (Exception error)
        {
            MessageBox.Show("无法启动 ArtemisOS 更新修复：" + error.Message,
                "ArtemisOS 15 更新修复", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 1;
        }
    }
}
