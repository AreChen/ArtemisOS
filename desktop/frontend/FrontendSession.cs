using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace ArtemisOS.Frontend
{
    internal sealed class SessionRecord
    {
        public string State, ActualRenderer, Error;
        public int EmulatorPid;
        public long EmulatorTicks;
    }

    internal sealed class FrontendSession : IDisposable
    {
        private readonly FrontendOptions options;
        private readonly object gate = new object(), logGate = new object();
        private readonly CancellationTokenSource cancellation = new CancellationTokenSource();
        private readonly SemaphoreSlim viewerGate = new SemaphoreSlim(1, 1);
        private readonly SemaphoreSlim reconnectGate = new SemaphoreSlim(1, 1);
        private readonly DisplayRecovery displayRecovery = new DisplayRecovery();
        private readonly string sessionId = Guid.NewGuid().ToString("N");
        private readonly long frontendTicks = Process.GetCurrentProcess().StartTime.ToUniversalTime().Ticks;
        private readonly string logPath;
        private Process viewer, launcher;
        private ProcessIdentity backendIdentity, backendChildIdentity;
        private SessionRecord record;
        private Task startTask, stopTask;
        private Task displayRecoveryTask;
        private bool displayRecovering;
        private int recoveryGeneration;
        private TaskCompletionSource<bool> updateDecision;
        private NamedPipeServerStream pipe;
        private volatile bool stopping, updating, disposed, textureReady;
        private bool frameFaultReported;
        private IntPtr viewerWindow;

        public readonly FrontendPaths Paths;
        public readonly DeviceClient Device;
        public event Action<string, string> StatusChanged;
        public event Action<IntPtr, int> ViewerReady;
        public event Action<Size> VideoSizeChanged;
        public event Action<string> ViewerDisconnected;
        public event Action CloseRequested;
        public bool Ready { get; private set; }
        public bool ViewerShouldActivate { get; private set; }
        public bool Updating { get { return updating; } }
        public string Serial { get { return "emulator-" + options.Port; } }
        public string LogPath { get { return logPath; } }

        public FrontendSession(FrontendOptions options)
        {
            this.options = options;
            Paths = new FrontendPaths(options.Root);
            Device = new DeviceClient(Paths.Adb, Serial);
            Device.BeforeCommand = ValidateDevice;
            Directory.CreateDirectory(Paths.LogsDir);
            Directory.CreateDirectory(Paths.RuntimeDir);
            logPath = Path.Combine(Paths.LogsDir, "frontend-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + "-" + sessionId.Substring(0, 8) + ".log");
        }

        public Task StartAsync()
        {
            lock (gate) {
                if (startTask == null) startTask = StartCoreAsync();
                return startTask;
            }
        }

        private async Task StartCoreAsync()
        {
            try {
                foreach (string path in new[] { Paths.Adb, Paths.ViewerExe, Path.Combine(Path.GetDirectoryName(Paths.ViewerExe), "scrcpy-server") })
                    if (!File.Exists(path)) throw new FileNotFoundException("缺少前端运行文件：" + path);
                Publish("正在启动", "准备 Android 运行环境…");
                if (options.AttachSerial == null) {
                    await StartBackendAsync();
                    StartUpdateChannel();
                } else {
                    backendChildIdentity = await Task.Run(() => FindBackendChild(null));
                    if (backendChildIdentity == null) throw new IOException("无法确认测试实例属于当前安装目录。");
                    var state = await Device.ExecuteAsync("get-state");
                    if (!state.Success || state.Output.Trim() != "device") throw new IOException("指定的测试设备尚未连接。");
                    Log("Development attach: backend lifecycle remains external.");
                }
                cancellation.Token.ThrowIfCancellationRequested();
                await StartViewerAsync();
            } catch (OperationCanceledException) { Log("Startup cancelled."); }
            catch (Exception ex) {
                Log(ex.ToString());
                Publish("启动未完成", ex.Message);
                Ready = false;
                // The form stays visible with the error and a retry action. Cleanup
                // is owned by StopAsync, so failure never hides a live backend.
                var handler = ViewerDisconnected;
                if (!stopping && handler != null) handler(ex.Message);
            }
        }

        private async Task StartBackendAsync()
        {
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
            string recovery = Path.Combine(Paths.Root, "update", "recovery.ps1");
            if (File.Exists(recovery)) {
                var recovered = await Task.Run(() => ProcessRunner.Run(powershell,
                    new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", recovery }, 30000));
                if (!recovered.Success) throw new IOException("上次更新恢复未完成，请查看更新日志。" + recovered.Error);
            }
            cancellation.Token.ThrowIfCancellationRequested();
            var arguments = new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", Paths.LaunchScript,
                "-Graphics", options.Graphics, "-Port", options.Port.ToString(), "-ExternalDisplay", "-SessionId", sessionId,
                "-FrontendPid", Process.GetCurrentProcess().Id.ToString(), "-FrontendStartTimeUtcTicks", frontendTicks.ToString() };
            var info = new ProcessStartInfo(powershell, CommandLine.Join(arguments));
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WorkingDirectory = Paths.Root;
            info.RedirectStandardOutput = info.RedirectStandardError = true;
            launcher = new Process { StartInfo = info };
            launcher.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null) Log("launch: " + e.Data); };
            launcher.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null) Log("launch error: " + e.Data); };
            if (!launcher.Start()) throw new IOException("无法运行 Android 启动器。");
            launcher.BeginOutputReadLine();
            launcher.BeginErrorReadLine();
            var deadline = DateTime.UtcNow.AddMinutes(16);
            while (DateTime.UtcNow < deadline) {
                cancellation.Token.ThrowIfCancellationRequested();
                record = ReadRecord();
                if (record != null) {
                    if (record.State == "failed") throw new IOException(String.IsNullOrEmpty(record.Error) ? "Android 初始化失败，请查看运行日志。" : record.Error);
                    if (record.State == "ready") {
                        backendIdentity = await Task.Run(() => ValidateBackend(record));
                        backendChildIdentity = await Task.Run(() => FindBackendChild(backendIdentity.Pid));
                        if (backendChildIdentity == null) throw new IOException("无法确认 Android 后台实例归属。");
                        Log("Android ready: " + record.ActualRenderer);
                        return;
                    }
                    Publish("正在启动", "Android 正在初始化，首次运行可能需要稍等…");
                } else if (launcher.HasExited) {
                    throw new IOException("Android 启动器已退出，未创建会话。详细信息：" + logPath);
                }
                await Task.Delay(500, cancellation.Token);
            }
            throw new TimeoutException("Android 启动时间超过预期。可以关闭后重试；用户数据会保留。");
        }

        private SessionRecord ReadRecord()
        {
            string path = Path.Combine(Paths.RuntimeDir, sessionId + ".json");
            if (!File.Exists(path)) return null;
            var data = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(path));
            Func<string, string> value = key => data.ContainsKey(key) && data[key] != null ? Convert.ToString(data[key]) : "";
            if (value("schemaVersion") != "1" || value("sessionId") != sessionId ||
                !String.Equals(Path.GetFullPath(value("installRoot")).TrimEnd('\\', '/'), Paths.Root.TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase) ||
                value("serial") != Serial || value("frontendPid") != Process.GetCurrentProcess().Id.ToString() ||
                value("frontendStartTimeUtcTicks") != frontendTicks.ToString())
                throw new InvalidDataException("启动器会话身份不匹配，已停止接入。");
            return new SessionRecord {
                State = value("state"), ActualRenderer = value("actualRenderer"), Error = value("error"),
                EmulatorPid = Int32.Parse(value("emulatorPid")), EmulatorTicks = Int64.Parse(value("emulatorStartTimeUtcTicks"))
            };
        }

        private ProcessIdentity ValidateBackend(SessionRecord candidate)
        {
            var id = TryCapture(candidate.EmulatorPid);
            string expected = Path.Combine(Paths.Root, "sdk", "emulator", "emulator.exe");
            if (id == null || !String.Equals(id.Path, expected, StringComparison.OrdinalIgnoreCase) ||
                id.StartTimeUtcTicks != candidate.EmulatorTicks || !id.IsCurrent())
                throw new IOException("Android 后台进程身份已变化，无法安全操作。");
            return id;
        }

        public async Task ReconnectAsync()
        {
            await ReconnectCoreAsync(true);
        }

        private async Task ReconnectCoreAsync(bool activate)
        {
            await reconnectGate.WaitAsync(cancellation.Token);
            try {
            Exception failure = null;
            try {
            CheckRunning();
            await ValidateDeviceAsync();
            await StopViewerAsync();
            var state = await Device.ExecuteAsync("get-state");
            CheckRunning();
            await ValidateDeviceAsync();
            if (!state.Success || state.Output.Trim() != "device") throw new IOException("Android 已断开。请使用“重启模拟器”恢复。");
            await StartViewerAsync(activate);
            } catch (Exception ex) { failure = ex; }
            if (failure != null) {
                // Cleanup belongs to this serialized attempt. Never stop a
                // replacement created by a concurrent manual reconnect.
                await StopViewerAsync();
                System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(failure).Throw();
            }
            } finally { reconnectGate.Release(); }
        }

        public Task RecoverDisplayAsync(string reason)
        {
            lock (gate) {
                if (stopping || updating || disposed) return Task.FromResult(false);
                if (displayRecovering) return displayRecoveryTask;
                displayRecovery.BeginEpisode();
                if (!displayRecovery.TryRecover(DateTime.UtcNow)) {
                    Ready = false;
                    var failed = ViewerDisconnected;
                    if (failed != null) failed("画面恢复多次失败，Android 数据仍保留。请在显示器稳定后点击“重新连接”。");
                    return Task.FromResult(false);
                }
                displayRecovering = true;
                displayRecoveryTask = RecoverDisplayCoreAsync(reason, ++recoveryGeneration);
                return displayRecoveryTask;
            }
        }

        private async Task RecoverDisplayCoreAsync(string reason, int generation)
        {
            try {
            while (true) {
                Ready = false;
                Log("Display recovery: " + reason);
                var disconnected = ViewerDisconnected;
                if (disconnected != null) disconnected("显示环境发生变化，正在重新连接画面；Android 继续运行。");
                Publish("正在恢复画面", "重新建立显示连接，保留 Android 和应用状态…");
                Exception failure;
                try {
                    // Let the display topology and DPI settle before creating the
                    // replacement SDL renderer. This never restarts the backend.
                    await Task.Delay(1000, cancellation.Token);
                    await ReconnectCoreAsync(false);
                    lock (gate) {
                        if (!frameFaultReported) {
                            // Release the episode atomically with the last
                            // fault check, so the next failure cannot be lost.
                            displayRecovering = false;
                            return;
                        }
                    }
                    throw new IOException("重连后的显示端仍无法更新视频帧。");
                } catch (OperationCanceledException) { return; }
                catch (Exception ex) { failure = ex; }
                Log("Display recovery failed: " + failure.Message);
                if (stopping || updating || disposed) return;
                Ready = false;
                lock (gate) { if (displayRecovery.TryRecover(DateTime.UtcNow)) continue; }
                var failed = ViewerDisconnected;
                if (failed != null) failed("画面重连失败：" + failure.Message + " 可稍后手动重新连接，Android 数据仍保留。");
                return;
            }
            } finally { lock (gate) { if (recoveryGeneration == generation) displayRecovering = false; } }
        }

        private async Task StartViewerAsync(bool activate = true)
        {
            await viewerGate.WaitAsync(cancellation.Token);
            try {
            CheckRunning();
            Publish("正在连接画面", "独立显示窗口正在就绪…");
            string title = "ArtemisOS Display " + sessionId;
            var args = new List<string>(ViewerArguments.Build(Serial, title, ViewerArguments.ReadMaxFps(Paths.Root)));
            args.Add("--window-x=-30000");
            args.Add("--window-y=-30000");
            args.Add("--window-width=360");
            args.Add("--window-height=800");
            args.Add("--render-fit=letterbox");
            var info = new ProcessStartInfo(Paths.ViewerExe, CommandLine.Join(args));
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.RedirectStandardOutput = info.RedirectStandardError = true;
            info.WorkingDirectory = Path.GetDirectoryName(Paths.ViewerExe);
            info.EnvironmentVariables["ADB"] = Paths.Adb;
            info.EnvironmentVariables["SCRCPY_SERVER_PATH"] = Path.Combine(Path.GetDirectoryName(Paths.ViewerExe), "scrcpy-server");
            info.EnvironmentVariables["SCRCPY_ICON_DIR"] = Paths.AssetsDir;
            var process = new Process { StartInfo = info, EnableRaisingEvents = true };
            process.OutputDataReceived += ViewerOutput;
            process.ErrorDataReceived += ViewerOutput;
            process.Exited += delegate {
                lock (gate) {
                if (stopping || updating || process != viewer) return;
                Ready = false;
                int code = -1;
                try { code = process.ExitCode; } catch (InvalidOperationException) { }
                Log("Viewer exit " + code);
                var handler = ViewerDisconnected;
                if (handler != null) handler(code == 2 ? "设备连接中断。Android 数据仍保留，可以尝试重新连接。" : "显示窗口已退出。可以重新连接画面，或重启模拟器。");
                }
            };
            lock (gate) {
                viewer = process;
                textureReady = false;
                displayRecovery.ResetFrames(); frameFaultReported = false;
            }
            if (!process.Start()) throw new IOException("无法启动独立显示窗口。");
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            IntPtr processHandle = process.Handle; // retain the exact process object even if WMI is temporarily unavailable
            var deadline = DateTime.UtcNow.AddSeconds(30);
            while (DateTime.UtcNow < deadline) {
                CheckRunning();
                if (process.HasExited) throw new IOException("显示窗口启动失败，详情见前端日志。");
                IntPtr window = NativeDisplay.FindViewer(process.Id, title);
                if (window != IntPtr.Zero && textureReady) {
                    lock (gate) {
                        CheckRunning();
                        if (frameFaultReported) throw new IOException("显示端初始化后无法更新视频帧。");
                    viewerWindow = window;
                    ViewerShouldActivate = activate;
                    Ready = true;
                    var connected = ViewerReady;
                    if (connected != null) connected(window, process.Id);
                    string renderer = record == null ? "独立显示 · 测试连接" : record.ActualRenderer;
                    Publish("已连接", String.IsNullOrWhiteSpace(renderer) ? "Android 已就绪" : renderer);
                    }
                    return;
                }
                await Task.Delay(150, cancellation.Token);
            }
            throw new TimeoutException("显示窗口没有及时出现，请重新连接。");
            } finally { viewerGate.Release(); }
        }

        private void ViewerOutput(object sender, DataReceivedEventArgs e)
        {
            lock (gate) {
                if (e.Data == null || sender != viewer || stopping || updating || disposed) return;
                if (frameFaultReported && e.Data.IndexOf("ERROR: Frame update failed", StringComparison.Ordinal) >= 0) return;
                bool recover = displayRecovery.Observe(e.Data, DateTime.UtcNow);
                if (recover) frameFaultReported = true;
            Log(e.Data);
            if (recover) {
                Task recovery = RecoverDisplayAsync("连续视频帧更新失败，重建显示器连接。");
                return;
            }
            var match = Regex.Match(e.Data, @"Texture:\s*(\d+)x(\d+)");
            if (match.Success) {
                textureReady = true;
                var handler = VideoSizeChanged;
                if (handler != null) handler(new Size(Int32.Parse(match.Groups[1].Value), Int32.Parse(match.Groups[2].Value)));
            }
            }
        }

        private async Task StopViewerAsync()
        {
            await viewerGate.WaitAsync();
            try {
            Process process;
            lock (gate) {
                process = viewer;
                viewer = null; // Late output and intentional exit cannot fault the replacement viewer.
                viewerWindow = IntPtr.Zero;
                Ready = false;
            }
            if (process == null) return;
            try { await Task.Run(delegate {
                try {
                    if (process.HasExited) return;
                    IntPtr window = NativeDisplay.FindViewer(process.Id, "ArtemisOS Display " + sessionId);
                    if (window != IntPtr.Zero) NativeDisplay.PostMessage(window, 0x0010, IntPtr.Zero, IntPtr.Zero);
                    if (!process.WaitForExit(3000)) {
                        NativeDisplay.StopOwned(process);
                        if (!process.WaitForExit(3000)) throw new IOException("显示进程仍未退出，已取消更新交接。");
                    }
                } catch (InvalidOperationException) { }
            }); } catch { lock (gate) { viewer = process; } throw; }
            process.Dispose();
            } finally { viewerGate.Release(); }
        }

        public Task StopAsync()
        {
            lock (gate) {
                if (stopTask == null || stopTask.IsFaulted || stopTask.IsCanceled) stopTask = StopCoreAsync();
                return stopTask;
            }
        }

        private async Task StopCoreAsync()
        {
            // A user close during OTA preparation must not destroy the pipe
            // before the updater knows whether it owns the running backend.
            while (true) {
                Task<bool> pending;
                lock (gate) {
                    pending = updateDecision == null ? null : updateDecision.Task;
                    if (pending == null || pending.IsCompleted) { stopping = true; break; }
                }
                if (await Task.WhenAny(pending, Task.Delay(15000)) != pending)
                    throw new IOException("更新交接仍在进行，请稍后再关闭。");
                await pending;
            }
            cancellation.Cancel();
            ClosePipe();
            Ready = false;
            Publish(updating ? "正在更新" : "正在关闭", updating ? "正在交接给更新程序…" : "正在保存状态并关闭 Android…");
            var wrappers = new List<ProcessIdentity>();
            if (!updating && options.AttachSerial == null && !options.KeepBackend && launcher != null) {
                wrappers.AddRange(await Task.Run(() => FindLauncherChildren(launcher)));
                // Stop our own PowerShell process before waiting: cancelling the C#
                // polling loop alone does not cancel a delayed native launch.
                if (!launcher.HasExited) await Task.Run(() => NativeDisplay.StopOwned(launcher));
                wrappers.AddRange(await Task.Run(() => FindLauncherChildren(launcher)));
            }
            if (startTask != null) await Task.WhenAny(startTask, Task.Delay(10000));
            await StopViewerAsync();
            if (!updating && options.AttachSerial == null && !options.KeepBackend) {
                try {
                    if (record == null) record = ReadRecord();
                    if (backendIdentity == null && record != null && record.EmulatorPid > 0) {
                        var candidate = await Task.Run(() => TryCapture(record.EmulatorPid));
                        if (candidate != null && candidate.StartTimeUtcTicks == record.EmulatorTicks &&
                            String.Equals(candidate.Path, Path.Combine(Paths.Root, "sdk", "emulator", "emulator.exe"), StringComparison.OrdinalIgnoreCase) &&
                            launcher != null && candidate.ParentPid == launcher.Id) backendIdentity = candidate;
                    }
                    if (backendIdentity != null) wrappers.Add(backendIdentity);
                    var children = new List<ProcessIdentity>();
                    if (backendChildIdentity != null) children.Add(backendChildIdentity);
                    foreach (var wrapper in wrappers) {
                        var child = await Task.Run(() => FindBackendChild(wrapper.Pid));
                        if (child != null) children.Add(child);
                    }
                    bool killedGracefully = false;
                    foreach (var child in children) {
                        if (!NativeDisplay.Matches(child)) continue;
                        if (!killedGracefully) {
                            // Shutdown is already bound to the verified child;
                            // do not wait behind a long UI install/import queue.
                            await Task.Run(() => ProcessRunner.Run(Paths.Adb, new[] { "-s", Serial, "emu", "kill" }, 5000));
                            killedGracefully = true;
                        }
                        await WaitForExitAsync(child, 10000);
                        if (NativeDisplay.Matches(child)) await Task.Run(() => NativeDisplay.StopIdentity(child));
                    }
                    foreach (var wrapper in wrappers) {
                        await Task.Run(() => NativeDisplay.StopIdentity(wrapper));
                        // Covers a QEMU created between enumeration and terminating
                        // the verified wrapper; no new child can appear after this.
                        var lateChild = await Task.Run(() => FindBackendChild(wrapper.Pid));
                        if (lateChild != null) await Task.Run(() => NativeDisplay.StopIdentity(lateChild));
                    }
                } catch (Exception ex) { Log("Shutdown: " + ex.Message); throw; }
            }
            ClosePipe();
            Publish(updating ? "正在更新" : "已关闭", "");
        }

        private List<ProcessIdentity> FindLauncherChildren(Process ownLauncher)
        {
            var found = new List<ProcessIdentity>();
            long since = ownLauncher.StartTime.ToUniversalTime().Ticks;
            using (var query = new System.Management.ManagementObjectSearcher("SELECT ProcessId FROM Win32_Process WHERE ParentProcessId=" + ownLauncher.Id)) {
                using (var results = query.Get()) foreach (System.Management.ManagementObject row in results) using (row) {
                    var id = TryCapture(Convert.ToInt32(row["ProcessId"]));
                    if (id != null && id.StartTimeUtcTicks >= since &&
                        String.Equals(id.Path, Path.Combine(Paths.Root, "sdk", "emulator", "emulator.exe"), StringComparison.OrdinalIgnoreCase)) found.Add(id);
                }
            }
            return found;
        }

        private ProcessIdentity FindBackendChild(int? parentPid)
        {
            string where = parentPid.HasValue ? "ParentProcessId=" + parentPid.Value : "Name='qemu-system-x86_64-headless.exe' OR Name='qemu-system-x86_64.exe'";
            using (var query = new System.Management.ManagementObjectSearcher("SELECT ProcessId FROM Win32_Process WHERE " + where)) {
                using (var results = query.Get()) foreach (System.Management.ManagementObject row in results) {
                    using (row) {
                        var child = TryCapture(Convert.ToInt32(row["ProcessId"]));
                        string prefix = Path.Combine(Paths.Root, "sdk", "emulator") + Path.DirectorySeparatorChar;
                        if (child != null && child.Path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) &&
                            Regex.IsMatch(Path.GetFileName(child.Path), @"^qemu-system-x86_64(?:-headless)?\.exe$", RegexOptions.IgnoreCase) &&
                            Regex.IsMatch(child.CommandLine ?? "", @"(?:^|\s)-port\s+" + options.Port + @"(?:\s|$)") && child.IsCurrent()) return child;
                    }
                }
            }
            return null;
        }

        private static async Task WaitForExitAsync(ProcessIdentity identity, int milliseconds)
        {
            var end = DateTime.UtcNow.AddMilliseconds(milliseconds);
            while (DateTime.UtcNow < end && NativeDisplay.Matches(identity)) await Task.Delay(250);
        }

        private static ProcessIdentity TryCapture(int pid)
        {
            try { return ProcessIdentity.Capture(pid); }
            catch (ArgumentException) { return null; }
            catch (InvalidOperationException) { return null; }
        }

        public Task ValidateDeviceAsync()
        {
            return Task.Run((Action)ValidateDevice);
        }

        private void ValidateDevice()
        {
            CheckRunning();
            if (!NativeDisplay.Matches(backendChildIdentity))
                throw new IOException("原 Android 实例已退出。请重启模拟器，已拒绝接入端口上可能出现的其他设备。");
        }

        private void CheckRunning()
        {
            cancellation.Token.ThrowIfCancellationRequested();
            if (stopping || updating) throw new OperationCanceledException();
        }

        private void StartUpdateChannel()
        {
            Task.Run(async delegate {
                while (!stopping && !updating) {
                    NamedPipeServerStream active = null;
                    try {
                        var security = new PipeSecurity();
                        security.SetAccessRuleProtection(true, false);
                        security.AddAccessRule(new PipeAccessRule(WindowsIdentity.GetCurrent().User, PipeAccessRights.FullControl, AccessControlType.Allow));
                        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
                        string name = "ArtemisOS-Frontend-" + Program.RootHash(Paths.Root) + "-" + sessionId;
                        active = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Message,
                            PipeOptions.Asynchronous, 4096, 4096, security);
                        lock (gate) { if (stopping) { active.Dispose(); return; } pipe = active; }
                        await active.WaitForConnectionAsync(cancellation.Token);
                        using (var reader = new StreamReader(active, Encoding.UTF8, false, 1024, true))
                        using (var writer = new StreamWriter(active, new UTF8Encoding(false), 1024, true) { AutoFlush = true }) {
                            Task<string> request = reader.ReadLineAsync();
                            if (await Task.WhenAny(request, Task.Delay(5000, cancellation.Token)) != request) continue;
                            if (await request != "prepare-update:" + sessionId) { await writer.WriteLineAsync("rejected"); continue; }
                            lock (gate) {
                                CheckRunning();
                                updateDecision = new TaskCompletionSource<bool>();
                                updating = true;
                            }
                            Publish("正在更新", "更新程序正在接管 Android…");
                            await StopViewerAsync();
                            await writer.WriteLineAsync("ready:" + sessionId);
                            lock (gate) { updateDecision.TrySetResult(true); }
                            var close = CloseRequested;
                            if (close != null) close();
                        }
                    } catch (OperationCanceledException) { return; }
                    catch (ObjectDisposedException) { return; }
                    catch (Exception ex) {
                        Log("Update channel: " + ex.Message);
                        if (updating && !stopping) {
                            updating = false;
                            Publish("更新未完成", ex.Message);
                        }
                    }
                    finally {
                        lock (gate) {
                            if (updateDecision != null && !updateDecision.Task.IsCompleted) {
                                updating = false;
                                updateDecision.TrySetResult(false);
                            }
                        }
                        if (active != null) active.Dispose();
                        lock (gate) { if (pipe == active) pipe = null; }
                    }
                    if (!stopping && !updating) await Task.Delay(1000);
                }
            });
        }

        private void ClosePipe()
        {
            lock (gate) { if (pipe != null) { pipe.Dispose(); pipe = null; } }
        }

        private void Publish(string title, string detail)
        {
            var handler = StatusChanged;
            if (handler != null) handler(title, detail);
        }

        public void Log(string message)
        {
            lock (logGate) {
                try { File.AppendAllText(logPath, DateTime.Now.ToString("o") + " " + message + Environment.NewLine, new UTF8Encoding(false)); }
                catch (IOException) { }
            }
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            cancellation.Cancel();
            ClosePipe();
            cancellation.Dispose();
            if (launcher != null) launcher.Dispose();
        }
    }
}
