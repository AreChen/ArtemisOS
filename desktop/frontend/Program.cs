using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace ArtemisOS.Frontend
{
    internal sealed class FrontendOptions
    {
        public string Root, Graphics = "auto", AttachSerial;
        public int Port = 5554;
        public bool KeepBackend;

        public static FrontendOptions Parse(string[] args)
        {
            var options = new FrontendOptions();
            for (int i = 0; i < args.Length; i++) {
                string key = args[i];
                if (key == "--keep-backend") { options.KeepBackend = true; continue; }
                if (i + 1 >= args.Length) throw new ArgumentException("缺少参数：" + key);
                string value = args[++i];
                switch (key) {
                    case "--root": options.Root = Path.GetFullPath(value).TrimEnd('\\', '/'); break;
                    case "--graphics":
                        if (value != "auto" && value != "swiftshader") throw new ArgumentException("未知图形启动方式。");
                        options.Graphics = value; break;
                    case "--port":
                        options.Port = Int32.Parse(value);
                        CommandLine.ValidateSerial("emulator-" + options.Port); break;
                    case "--attach-serial":
                        CommandLine.ValidateSerial(value); options.AttachSerial = value;
                        options.Port = Int32.Parse(value.Substring(9)); break;
                    default: throw new ArgumentException("未知参数：" + key);
                }
            }
            if (String.IsNullOrEmpty(options.Root)) {
                options.Root = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "..", ".."));
            }
            if (!File.Exists(Path.Combine(options.Root, "launch.ps1")))
                throw new FileNotFoundException("请选择完整的 ArtemisOS 安装目录。");
            return options;
        }
    }

    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            try {
                var options = FrontendOptions.Parse(args);
                bool first;
                using (var mutex = new Mutex(true, "Local\\ArtemisOS-Frontend-" + RootHash(options.Root), out first)) {
                    if (!first) {
                        MessageBox.Show("这个安装目录的 ArtemisOS 窗口已经打开，请从任务栏切换。", "ArtemisOS", MessageBoxButtons.OK, MessageBoxIcon.Information);
                        return;
                    }
                    try { using (var form = new ShellForm(options)) Application.Run(form); }
                    finally { mutex.ReleaseMutex(); }
                }
            } catch (Exception ex) {
                MessageBox.Show(ex.Message, "ArtemisOS 启动失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        internal static string RootHash(string root)
        {
            using (var sha = SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(Path.GetFullPath(root).TrimEnd('\\', '/').ToUpperInvariant()))).Replace("-", "").ToLowerInvariant();
        }
    }
}
