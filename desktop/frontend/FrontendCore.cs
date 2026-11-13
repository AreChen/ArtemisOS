using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Management;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace ArtemisOS.Frontend
{
    public static class CommandLine
    {
        // Windows CRT argv quoting. No command interpreter is involved.
        public static string Quote(string value)
        {
            if (value == null) throw new ArgumentNullException("value");
            if (value.IndexOf('\0') >= 0) throw new ArgumentException("参数包含空字符。", "value");
            StringBuilder result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in value)
            {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') result.Append('\\', slashes * 2 + 1);
                else result.Append('\\', slashes);
                result.Append(c); slashes = 0;
            }
            result.Append('\\', slashes * 2).Append('"');
            return result.ToString();
        }
        public static string Join(IEnumerable<string> arguments)
        {
            if (arguments == null) throw new ArgumentNullException("arguments");
            StringBuilder result = new StringBuilder();
            foreach (string argument in arguments)
            {
                if (result.Length != 0) result.Append(' ');
                result.Append(Quote(argument));
            }
            return result.ToString();
        }
        public static void ValidateSerial(string serial)
        {
            if (serial == null || !Regex.IsMatch(serial, @"\Aemulator-[0-9]{4}\z", RegexOptions.CultureInvariant))
                throw new ArgumentException("无效的 ArtemisOS 设备编号。", "serial");
            int port = Int32.Parse(serial.Substring(9), CultureInfo.InvariantCulture);
            if (port < 5554 || port > 5584 || (port & 1) != 0)
                throw new ArgumentException("设备端口必须为 5554 至 5584 之间的偶数。", "serial");
        }
    }

    public sealed class CommandResult
    {
        public int ExitCode;
        public string Output = String.Empty;
        public string Error = String.Empty;
        public bool TimedOut;
        public bool Success { get { return !TimedOut && ExitCode == 0; } }
    }

    public static class ProcessRunner
    {
        public static CommandResult Run(string exe, IEnumerable<string> args, int timeoutMs)
        {
            return RunCore(exe, args, timeoutMs, null);
        }
        public static CommandResult RunBinary(string exe, IEnumerable<string> args, int timeoutMs, string outputPath)
        {
            if (String.IsNullOrWhiteSpace(outputPath)) throw new ArgumentException("请选择截图保存位置。", "outputPath");
            return RunCore(exe, args, timeoutMs, Path.GetFullPath(outputPath));
        }
        private static void KillOwnProcess(Process process)
        {
            try { if (!process.HasExited) process.Kill(); } catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
        }
        private static CommandResult RunCore(string exe, IEnumerable<string> args, int timeoutMs, string outputPath)
        {
            if (String.IsNullOrWhiteSpace(exe)) throw new ArgumentException("缺少程序路径。", "exe");
            if (timeoutMs <= 0) throw new ArgumentOutOfRangeException("timeoutMs");
            string command = CommandLine.Join(args);
            CommandResult result = new CommandResult { ExitCode = -1 };
            string temporary = null;
            FileStream output = null;
            using (Process process = new Process())
            {
                try
                {
                    process.StartInfo = new ProcessStartInfo(exe, command) {
                        UseShellExecute = false, CreateNoWindow = true,
                        RedirectStandardOutput = true, RedirectStandardError = true,
                        StandardOutputEncoding = new UTF8Encoding(false), StandardErrorEncoding = new UTF8Encoding(false)
                    };
                    if (outputPath != null)
                    {
                        string directory = Path.GetDirectoryName(outputPath);
                        Directory.CreateDirectory(directory);
                        temporary = Path.Combine(directory, "." + Path.GetFileName(outputPath) + "." + Guid.NewGuid().ToString("N") + ".tmp");
                        output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                    }
                    Stopwatch watch = Stopwatch.StartNew();
                    process.Start();
                    Task<string> text = output == null ? process.StandardOutput.ReadToEndAsync() : null;
                    Task binary = output != null ? process.StandardOutput.BaseStream.CopyToAsync(output) : null;
                    Task<string> error = process.StandardError.ReadToEndAsync();
                    bool exited = process.WaitForExit(timeoutMs);
                    Task[] readers = new Task[] { text != null ? (Task)text : binary, error };
                    int remaining = (int)Math.Max(1L, timeoutMs - watch.ElapsedMilliseconds);
                    bool drained = exited && Task.WaitAll(readers, remaining);
                    if (!exited || !drained)
                    {
                        result.TimedOut = true;
                        KillOwnProcess(process);
                        process.WaitForExit(1000);
                        Task.WaitAll(readers, 500);
                    }
                    if (text != null && text.Status == TaskStatus.RanToCompletion) result.Output = text.Result;
                    if (error.Status == TaskStatus.RanToCompletion) result.Error = error.Result;
                    result.ExitCode = process.HasExited ? process.ExitCode : -1;
                    if (result.TimedOut) result.Error = (result.Error + Environment.NewLine + "操作超时，已停止本次命令。").Trim();
                    if (output != null) { output.Dispose(); output = null; }
                    if (outputPath != null && result.Success)
                    {
                        byte[] signature = new byte[8];
                        using (FileStream png = File.OpenRead(temporary))
                        {
                            byte[] expected = { 137, 80, 78, 71, 13, 10, 26, 10 };
                            if (png.Read(signature, 0, signature.Length) != signature.Length) throw new InvalidDataException("截图内容不是有效的 PNG 文件。");
                            for (int i = 0; i < expected.Length; i++) if (signature[i] != expected[i]) throw new InvalidDataException("截图内容不是有效的 PNG 文件。");
                        }
                        if (File.Exists(outputPath)) File.Replace(temporary, outputPath, null);
                        else File.Move(temporary, outputPath);
                        temporary = null;
                        result.Output = outputPath;
                    }
                }
                catch (Exception ex)
                {
                    KillOwnProcess(process);
                    result.ExitCode = -1;
                    result.Error = (result.Error + Environment.NewLine + ex.GetBaseException().Message).Trim();
                }
                finally
                {
                    if (output != null) output.Dispose();
                    if (temporary != null) { try { File.Delete(temporary); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
                }
            }
            return result;
        }
    }

    public static class RotationState
    {
        // Android 15 dumps encoder mirror displays beside display 0. Only the
        // default DisplayContent's actual mRotation is authoritative here.
        public static int ParseDefaultDisplayRotation(string output)
        {
            if (String.IsNullOrWhiteSpace(output)) throw new InvalidDataException("无法读取默认屏幕的实际方向。");
            bool inDefault = false;
            int defaultDisplays = 0, rotations = 0, rotation = -1;
            foreach (string line in output.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
            {
                Match display = Regex.Match(line, @"^\s*Display:\s*mDisplayId=(?<id>\d+)(?:\s|$)", RegexOptions.CultureInvariant);
                if (display.Success)
                {
                    inDefault = display.Groups["id"].Value == "0";
                    if (inDefault && ++defaultDisplays != 1) throw new InvalidDataException("默认屏幕方向信息重复，已拒绝修改。");
                    continue;
                }
                // Window/container overrideConfig lines also embed mRotation,
                // including undefined values. DisplayRotation prints the actual
                // value as the first field on its own indented line.
                if (!inDefault || !Regex.IsMatch(line, @"^\s*mRotation=", RegexOptions.CultureInvariant)) continue;
                foreach (Match field in Regex.Matches(line, @"(?:^|\s)mRotation=(?<value>\S+)", RegexOptions.CultureInvariant))
                {
                    if (++rotations != 1) throw new InvalidDataException("默认屏幕方向信息不明确，已拒绝修改。");
                    switch (field.Groups["value"].Value)
                    {
                        case "0": case "ROTATION_0": rotation = 0; break;
                        case "1": case "ROTATION_90": rotation = 1; break;
                        case "2": case "ROTATION_180": rotation = 2; break;
                        case "3": case "ROTATION_270": rotation = 3; break;
                        default: throw new InvalidDataException("默认屏幕方向值无效，已拒绝修改。");
                    }
                }
            }
            if (defaultDisplays != 1 || rotations != 1) throw new InvalidDataException("无法读取默认屏幕的实际方向。");
            return rotation;
        }
    }

    public sealed class DeviceClient
    {
        private readonly string adb;
        private readonly string serial;
        private readonly SemaphoreSlim queue = new SemaphoreSlim(1, 1);
        public Action BeforeCommand;
        public DeviceClient(string adb, string serial)
        {
            if (String.IsNullOrWhiteSpace(adb)) throw new ArgumentException("缺少 ADB 路径。", "adb");
            CommandLine.ValidateSerial(serial);
            this.adb = Path.GetFullPath(adb); this.serial = serial;
        }
        private string[] Scoped(string[] args)
        {
            string[] scoped = new string[args.Length + 2]; scoped[0] = "-s"; scoped[1] = serial;
            Array.Copy(args, 0, scoped, 2, args.Length); return scoped;
        }
        private void CheckBeforeCommand()
        {
            Action check = BeforeCommand;
            if (check != null) check();
        }
        private CommandResult Execute(string[] args, int timeoutMs)
        {
            CheckBeforeCommand();
            return ProcessRunner.Run(adb, Scoped(args), timeoutMs);
        }
        private async Task<CommandResult> Enqueue(Func<CommandResult> operation)
        {
            await queue.WaitAsync().ConfigureAwait(false);
            try { return await Task.Run(delegate { CheckBeforeCommand(); return operation(); }).ConfigureAwait(false); }
            finally { queue.Release(); }
        }
        public Task<CommandResult> ExecuteAsync(params string[] args)
        {
            if (args == null || args.Length == 0 || String.IsNullOrEmpty(args[0]) || args[0][0] == '-') throw new ArgumentException("缺少设备命令。", "args");
            foreach (string forbidden in new[] { "kill-server", "start-server", "server", "connect", "disconnect", "reconnect", "devices" })
                if (args[0] == forbidden) throw new ArgumentException("前端不执行共享 ADB 服务管理命令。", "args");
            string[] copy = (string[])args.Clone();
            return Enqueue(delegate { return Execute(copy, 30000); });
        }
        public Task<CommandResult> KeyAsync(int keycode)
        {
            if (keycode < 0 || keycode > 1000) throw new ArgumentOutOfRangeException("keycode");
            return ExecuteAsync("shell", "input", "keyevent", keycode.ToString(CultureInfo.InvariantCulture));
        }
        public Task<CommandResult> ScreenshotAsync(string path)
        {
            if (String.IsNullOrWhiteSpace(path)) throw new ArgumentException("请选择截图保存位置。", "path");
            string fullPath = Path.GetFullPath(path);
            return Enqueue(delegate { CheckBeforeCommand(); return ProcessRunner.RunBinary(adb, Scoped(new[] { "exec-out", "screencap", "-p" }), 30000, fullPath); });
        }
        private static string ExistingFile(string path)
        {
            if (String.IsNullOrWhiteSpace(path)) throw new ArgumentException("请选择文件。", "path");
            string fullPath = Path.GetFullPath(path);
            if (!File.Exists(fullPath)) throw new ArgumentException("所选文件不存在。", "path");
            return fullPath;
        }
        public Task<CommandResult> InstallAsync(string path)
        {
            string fullPath = ExistingFile(path);
            if (!String.Equals(Path.GetExtension(fullPath), ".apk", StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("请选择 APK 文件。", "path");
            return Enqueue(delegate { return Execute(new[] { "install", "-r", fullPath }, 180000); });
        }
        private static string EncodeFileName(string name)
        {
            StringBuilder encoded = new StringBuilder();
            foreach (byte b in new UTF8Encoding(false, true).GetBytes(name))
            {
                if ((b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '-' || b == '.' || b == '_' || b == '~') encoded.Append((char)b);
                else encoded.Append('%').Append(b.ToString("X2", CultureInfo.InvariantCulture));
            }
            return encoded.ToString();
        }
        public Task<CommandResult> ImportAsync(string path)
        {
            string fullPath = ExistingFile(path);
            string name = Path.GetFileName(fullPath);
            string remote = "/sdcard/Download/" + name;
            string uri = "file:///sdcard/Download/" + EncodeFileName(name);
            // adb shell joins arguments into a remote shell command. Quote the URI for that shell as well.
            string scan = "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d '" + uri.Replace("'", "'\\''") + "'";
            return Enqueue(delegate {
                CommandResult result = Execute(new[] { "shell", "mkdir", "-p", "/sdcard/Download" }, 30000);
                if (!result.Success) return result;
                result = Execute(new[] { "push", fullPath, remote }, 180000);
                if (!result.Success) return result;
                result = Execute(new[] { "shell", scan }, 30000);
                if (!result.Success) result.Error = "文件已导入，但媒体索引刷新失败。" + Environment.NewLine + result.Error;
                return result;
            });
        }
        public Task<CommandResult> RotateAsync()
        {
            return Enqueue(delegate {
                CommandResult result = Execute(new[] { "shell", "wm", "user-rotation", "-d", "0" }, 30000);
                if (!result.Success) return result;
                string originalUser = result.Output.Trim();
                if (!Regex.IsMatch(originalUser, @"\A(?:free|lock [0-3])\z", RegexOptions.CultureInvariant))
                    return new CommandResult { ExitCode = -1, Error = "无法读取默认屏幕的方向锁定状态。" };
                result = Execute(new[] { "shell", "wm", "fixed-to-user-rotation", "-d", "0" }, 30000);
                if (!result.Success) return result;
                string originalFixed = result.Output.Trim();
                if (!Regex.IsMatch(originalFixed, @"\A(?:default|enabled|disabled|enabled_if_no_auto_rotation)\z", RegexOptions.CultureInvariant))
                    return new CommandResult { ExitCode = -1, Error = "无法读取默认屏幕的应用方向控制模式。" };
                int current;
                result = ReadDefaultDisplayRotation(out current);
                if (!result.Success) return result;
                int target = current == 0 || current == 2 ? 1 : 0;
                // All substituted values are the strictly validated enums above
                // or a computed rotation. The writes and rollback use one ADB
                // transport, so cancellation cannot split enabled from lock.
                string restore = BuildRotationRestoreScript(originalFixed, originalUser);
                string script = "artemis_rotation_status=0\nwm fixed-to-user-rotation -d 0 enabled && wm user-rotation -d 0 lock " + target.ToString(CultureInfo.InvariantCulture)
                    + " || artemis_rotation_status=$?\nif [ \"$artemis_rotation_status\" -ne 0 ]; then\n" + restore + "exit \"$artemis_rotation_status\"\nfi\nexit 0\n";
                result = Execute(new[] { "shell", script }, 30000);
                if (!result.Success)
                {
                    if (result.Error.Contains("ARTEMIS_ROTATION_RESTORE_FAILED")) result.Error += Environment.NewLine + RotationRestoreAdvice;
                    else if (!result.Error.Contains("ARTEMIS_ROTATION_RESTORED")) return RestoreRotationAfterFailure(result, restore);
                    return result;
                }
                // Rotation is asynchronous. A successful wm exit alone does not
                // prove an app-forced orientation has actually changed.
                try
                {
                    for (int attempt = 0; attempt < 5; attempt++)
                    {
                        if (attempt > 0) Thread.Sleep(150);
                        result = ReadDefaultDisplayRotation(out current);
                        if (!result.Success) return RestoreRotationAfterFailure(result, restore);
                        if (current == target) return new CommandResult { ExitCode = 0, Output = "默认屏幕方向已切换。" };
                    }
                }
                catch (Exception ex) { return RestoreRotationAfterFailure(new CommandResult { ExitCode = -1, Error = "旋转后的状态确认中断。" + ex.Message }, restore); }
                return RestoreRotationAfterFailure(new CommandResult { ExitCode = -1, Error = "已发送旋转指令，但默认屏幕的实际方向未改变。" }, restore);
            });
        }
        private const string RotationRestoreAdvice = "无法恢复原方向设置，请在后端正常运行后使用“更多 → 恢复应用方向控制”。";
        private static string BuildRotationRestoreScript(string originalFixed, string originalUser)
        {
            return "wm fixed-to-user-rotation -d 0 " + originalFixed + "\nartemis_restore_fixed=$?\nwm user-rotation -d 0 " + originalUser
                + "\nartemis_restore_user=$?\nif [ \"$artemis_restore_fixed\" -ne 0 ] || [ \"$artemis_restore_user\" -ne 0 ]; then\necho ARTEMIS_ROTATION_RESTORE_FAILED >&2\nexit 1\nfi\necho ARTEMIS_ROTATION_RESTORED >&2\n";
        }
        private CommandResult RestoreRotationAfterFailure(CommandResult failure, string restore)
        {
            try
            {
                CommandResult restored = Execute(new[] { "shell", restore }, 30000);
                failure.Error += Environment.NewLine + (restored.Success ? "已恢复原方向设置。" : restored.Error + Environment.NewLine + RotationRestoreAdvice);
            }
            catch (Exception ex) { failure.Error += Environment.NewLine + ex.Message + Environment.NewLine + RotationRestoreAdvice; }
            return failure;
        }
        private CommandResult ReadDefaultDisplayRotation(out int rotation)
        {
            rotation = -1;
            CommandResult result = Execute(new[] { "shell", "dumpsys", "window", "displays" }, 30000);
            if (!result.Success) return result;
            try { rotation = RotationState.ParseDefaultDisplayRotation(result.Output); return result; }
            catch (InvalidDataException ex) { return new CommandResult { ExitCode = -1, Error = ex.Message }; }
        }
        public Task<CommandResult> RestoreRotationAsync()
        {
            return Enqueue(delegate {
                CommandResult result = Execute(new[] { "shell", "wm", "fixed-to-user-rotation", "-d", "0", "default" }, 30000);
                if (!result.Success) return result;
                return Execute(new[] { "shell", "wm", "user-rotation", "-d", "0", "free" }, 30000);
            });
        }
    }

    public sealed class ProcessIdentity
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder path, ref int length);
        public int Pid, ParentPid;
        public string Path, CommandLine;
        public long StartTimeUtcTicks;
        public static ProcessIdentity Capture(int pid)
        {
            if (pid <= 0) throw new ArgumentOutOfRangeException("pid");
            using (Process process = Process.GetProcessById(pid))
            {
                // MainModule may still be null while a newly-created process loads its DLLs.
                StringBuilder image = new StringBuilder(32768); int imageLength = image.Capacity;
                if (!QueryFullProcessImageName(process.Handle, 0, image, ref imageLength))
                    throw new InvalidOperationException("无法确认进程路径，已拒绝操作。", new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()));
                string path = System.IO.Path.GetFullPath(image.ToString());
                long started = process.StartTime.ToUniversalTime().Ticks;
                EnumerationOptions options = new EnumerationOptions { Timeout = TimeSpan.FromSeconds(3), ReturnImmediately = false };
                using (ManagementObjectSearcher searcher = new ManagementObjectSearcher("root\\CIMV2", "SELECT ExecutablePath, CommandLine, ParentProcessId FROM Win32_Process WHERE ProcessId=" + pid.ToString(CultureInfo.InvariantCulture), options))
                using (ManagementObjectCollection matches = searcher.Get())
                {
                    foreach (ManagementObject match in matches)
                    using (match)
                    {
                        string wmiPath = match["ExecutablePath"] as string;
                        string command = match["CommandLine"] as string;
                        if (String.IsNullOrWhiteSpace(wmiPath) || String.IsNullOrWhiteSpace(command) || !String.Equals(path, System.IO.Path.GetFullPath(wmiPath), StringComparison.OrdinalIgnoreCase) || process.HasExited || process.StartTime.ToUniversalTime().Ticks != started)
                            throw new InvalidOperationException("无法确认进程归属，已拒绝操作。");
                        return new ProcessIdentity { Pid = pid, ParentPid = Convert.ToInt32(match["ParentProcessId"], CultureInfo.InvariantCulture), Path = path, CommandLine = command, StartTimeUtcTicks = started };
                    }
                }
                throw new InvalidOperationException("无法读取进程元数据，已拒绝操作。");
            }
        }
        public bool IsCurrent()
        {
            if (Pid <= 0 || StartTimeUtcTicks <= 0 || String.IsNullOrWhiteSpace(Path)) return false;
            try
            {
                ProcessIdentity current = Capture(Pid);
                return current.StartTimeUtcTicks == StartTimeUtcTicks && String.Equals(current.Path, System.IO.Path.GetFullPath(Path), StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
        }
    }

    public static class ViewerArguments
    {
        public const int DefaultMaxFps = 60;
        public const int MaximumMaxFps = 240;

        public static int ReadMaxFps(string root)
        {
            string path = System.IO.Path.Combine(root, "data", "preferences.ini");
            string value = null;
            try {
                if (!System.IO.File.Exists(path)) return DefaultMaxFps;
                foreach (string line in System.IO.File.ReadAllLines(path)) {
                    int split = line.IndexOf('=');
                    if (split > 0 && String.Equals(line.Substring(0, split), "max_fps", StringComparison.OrdinalIgnoreCase))
                        value = line.Substring(split + 1);
                }
            }
            catch (System.IO.IOException) { return DefaultMaxFps; }
            catch (UnauthorizedAccessException) { return DefaultMaxFps; }
            int parsed;
            if (value == null || !System.Text.RegularExpressions.Regex.IsMatch(value, @"\A[1-9][0-9]{0,2}\z") ||
                !Int32.TryParse(value, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out parsed) ||
                parsed < 1 || parsed > MaximumMaxFps) return DefaultMaxFps;
            return parsed;
        }

        public static string[] Build(string serial, string title)
        {
            return Build(serial, title, DefaultMaxFps);
        }

        public static string[] Build(string serial, string title, int maxFps)
        {
            CommandLine.ValidateSerial(serial);
            if (String.IsNullOrWhiteSpace(title)) throw new ArgumentException("缺少窗口标题。", "title");
            if (maxFps < 1 || maxFps > MaximumMaxFps) throw new ArgumentOutOfRangeException("maxFps");
            return new[] { "-s", serial, "--window-title=" + title, "--window-borderless", "--no-audio", "--video-codec=h264", "--video-encoder=c2.android.avc.encoder", "--max-size=1280", "--max-fps=" + maxFps.ToString(System.Globalization.CultureInfo.InvariantCulture), "--video-bit-rate=4M", "--render-driver=direct3d", "--pause-on-exit=false" };
        }
    }

    public sealed class FrontendPaths
    {
        public readonly string Root, Adb, LaunchScript, ConfigureScript, ViewerExe, AssetsDir, RuntimeDir, LogsDir;
        public FrontendPaths(string root)
        {
            if (String.IsNullOrWhiteSpace(root)) throw new ArgumentException("缺少安装目录。", "root");
            Root = System.IO.Path.GetFullPath(root);
            if (Root.Length > System.IO.Path.GetPathRoot(Root).Length) Root = Root.TrimEnd(System.IO.Path.DirectorySeparatorChar, System.IO.Path.AltDirectorySeparatorChar);
            Adb = System.IO.Path.Combine(Root, "sdk", "platform-tools", "adb.exe");
            LaunchScript = System.IO.Path.Combine(Root, "launch.ps1"); ConfigureScript = System.IO.Path.Combine(Root, "configure.ps1");
            ViewerExe = System.IO.Path.Combine(Root, "update", "frontend", "runtime", "scrcpy.exe"); AssetsDir = System.IO.Path.Combine(Root, "update", "frontend", "assets");
            RuntimeDir = System.IO.Path.Combine(Root, "data", "runtime"); LogsDir = System.IO.Path.Combine(Root, "data", "logs", "frontend");
        }
        public string Version
        {
            get
            {
                try { foreach (string line in File.ReadAllLines(System.IO.Path.Combine(Root, "version.ini"))) { Match match = Regex.Match(line.Trim(), @"\AVersion=(\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?)\z", RegexOptions.CultureInvariant); if (match.Success) return match.Groups[1].Value; } }
                catch (IOException) { } catch (UnauthorizedAccessException) { }
                return "0.0.0";
            }
        }
    }
}
