using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using ArtemisOS.Frontend;

internal static class FrontendCoreTests
{
    private static int failed;
    private static string fixture;
    private static readonly byte[] Png = Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1ioAAAAASUVORK5CYII=");
    private static string Self { get { return Process.GetCurrentProcess().MainModule.FileName; } }

    private static void Check(bool ok, string message) { if (!ok) throw new Exception(message); }
    private static void Reject(Action action, string message)
    {
        bool rejected = false;
        try { action(); } catch (ArgumentException) { rejected = true; }
        Check(rejected, message);
    }
    private static void Test(string name, Action action)
    {
        try { action(); Console.WriteLine("PASS: " + name); }
        catch (Exception ex) { failed++; Console.WriteLine("FAIL: " + name + ": " + ex); }
    }
    private static string[] Child(params string[] args) { return new[] { "--child" }.Concat(args).ToArray(); }
    private static Process StartSleeper()
    {
        return Process.Start(new ProcessStartInfo(Self, CommandLine.Join(Child("sleep"))) { UseShellExecute = false, CreateNoWindow = true });
    }
    private static void StopChild(Process p) { try { if (!p.HasExited) p.Kill(); p.WaitForExit(3000); } finally { p.Dispose(); } }
    private static string[][] ReadAdbLog(string path)
    {
        return File.ReadAllLines(path).Select(line => line.Split('|').Select(x => Encoding.UTF8.GetString(Convert.FromBase64String(x))).ToArray()).ToArray();
    }
    private static void WithAdb(string name, Action<DeviceClient, string> test)
    {
        string adb = Path.Combine(fixture, name + " adb.exe"); File.Copy(Self, adb);
        string log = Path.Combine(fixture, name + ".log");
        string[] variables = { "ARTEMIS_FRONTEND_TEST_ADB_LOG", "ARTEMIS_FRONTEND_TEST_ADB_GATE", "ARTEMIS_FRONTEND_TEST_FAIL_COMMAND", "ARTEMIS_FRONTEND_TEST_IGNORE_ROTATION", "ARTEMIS_FRONTEND_TEST_BAD_ROTATION" };
        Dictionary<string, string> saved = variables.ToDictionary(v => v, Environment.GetEnvironmentVariable);
        try {
            foreach (string v in variables) Environment.SetEnvironmentVariable(v, null);
            Environment.SetEnvironmentVariable(variables[0], log);
            test(new DeviceClient(adb, "emulator-5554"), log);
        } finally { foreach (var entry in saved) Environment.SetEnvironmentVariable(entry.Key, entry.Value); }
    }
    private static void SetBeforeCommand(DeviceClient client, Action check)
    {
        var field = typeof(DeviceClient).GetField("BeforeCommand");
        Check(field != null, "BeforeCommand guard is not implemented.");
        field.SetValue(client, check);
    }
    private static int FakeAdb(string[] args)
    {
        string log = Environment.GetEnvironmentVariable("ARTEMIS_FRONTEND_TEST_ADB_LOG");
        File.AppendAllText(log, String.Join("|", args.Select(x => Convert.ToBase64String(Encoding.UTF8.GetBytes(x)))) + Environment.NewLine);
        if (args.Length < 3 || args[0] != "-s" || args[1] != "emulator-5554") return 73;
        string command = String.Join(" ", args.Skip(2));
        string block = Environment.GetEnvironmentVariable("ARTEMIS_FRONTEND_TEST_ADB_GATE");
        if (command == "get-state" && !String.IsNullOrEmpty(block)) {
            var deadline = DateTime.UtcNow.AddSeconds(5);
            while (!File.Exists(block) && DateTime.UtcNow < deadline) Thread.Sleep(10);
            if (!File.Exists(block)) return 74;
        }
        if (command == Environment.GetEnvironmentVariable("ARTEMIS_FRONTEND_TEST_FAIL_COMMAND")) { Console.Error.Write("fixture wm failure"); return 5; }
        if (args.Length == 4 && args[2] == "shell" && args[3].Contains("\n")) {
            string bash = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Git", "bin", "bash.exe");
            if (!File.Exists(bash)) { Console.Error.Write("Git Bash is required by the developer-only rotation transaction test."); return 79; }
            string wrapper = "wm() { '" + Self.Replace('\\', '/').Replace("'", "'\\''") + "' --fake-wm \"$@\"; }\n";
            CommandResult script = ProcessRunner.Run(bash, new[] { "--noprofile", "--norc", "-c", wrapper + args[3] }, 15000);
            Console.Out.Write(script.Output); Console.Error.Write(script.Error); return script.ExitCode;
        }
        if (command == "exec-out screencap -p") { Console.OpenStandardOutput().Write(Png, 0, Png.Length); return 0; }
        string statePath = log + ".rotation";
        if (command.StartsWith("shell wm user-rotation -d 0 lock ")) {
            File.WriteAllText(log + ".user", "lock " + args[args.Length - 1]);
            if (Environment.GetEnvironmentVariable("ARTEMIS_FRONTEND_TEST_IGNORE_ROTATION") != "1") File.WriteAllText(statePath, args[args.Length - 1]);
        }
        if (command == "shell wm user-rotation -d 0 free") File.WriteAllText(log + ".user", "free");
        if (command.StartsWith("shell wm fixed-to-user-rotation -d 0 ")) File.WriteAllText(log + ".fixed", args[args.Length - 1]);
        if (command == "shell wm fixed-to-user-rotation -d 0") Console.WriteLine(File.Exists(log + ".fixed") ? File.ReadAllText(log + ".fixed") : "default");
        else if (command == "shell wm user-rotation -d 0") Console.WriteLine(File.Exists(log + ".user") ? File.ReadAllText(log + ".user") : "lock 1"); // The locked setting can disagree with the actual display.
        else if (command == "shell dumpsys window displays") {
            int rotation = File.Exists(statePath) ? Int32.Parse(File.ReadAllText(statePath)) : 0;
            Console.WriteLine("WINDOW MANAGER DISPLAY CONTENTS\n  Display: mDisplayId=2 rootTasks=1\n    mRotation=ROTATION_270 mUserRotation=ROTATION_270");
            if (Environment.GetEnvironmentVariable("ARTEMIS_FRONTEND_TEST_BAD_ROTATION") != "1") Console.WriteLine("  Display: mDisplayId=0 rootTasks=1\n    overrideConfig={1.0 ?mcc0mnc [zh_CN] ldltr sw360dp w360dp h800dp 320dpi nrml long port finger -keyb/v/h -nav/h winConfig={ mRotation=ROTATION_0} s.1}\n      overrideConfig={0.0 ?mcc0mnc winConfig={ mRotation=undefined} s.1}\n    mRotation=" + rotation + " mDeferredRotationPauseCount=0\n    mUserRotationMode=USER_ROTATION_LOCKED mUserRotation=ROTATION_90");
        }
        else if (command == "shell settings get system user_rotation") Console.WriteLine("3");
        else Console.WriteLine("Success");
        return 0;
    }
    private static int RunChild(string[] args)
    {
        string mode = args[1];
        if (mode == "echo") foreach (string arg in args.Skip(2)) Console.WriteLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(arg)));
        if (mode == "io")
        {
            string chunk = new string('x', 4096);
            for (int i = 0; i < 128; i++) { Console.Out.Write(chunk); Console.Error.Write(chunk); }
            Console.Out.Write("OUT-END"); Console.Error.Write("ERR-END");
        }
        if (mode == "sleep") Thread.Sleep(15000);
        if (mode == "png" || mode == "png-error" || mode == "png-sleep")
        {
            Stream stdout = Console.OpenStandardOutput(); stdout.Write(Png, 0, Png.Length); stdout.Flush();
            if (mode == "png-sleep") Thread.Sleep(15000);
            if (mode == "png-error") { Console.Error.Write("capture failed"); return 4; }
        }
        if (mode == "bad-png") Console.Write("this is not a PNG");
        return 0;
    }
    private static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--child") return RunChild(args);
        if (args.Length > 0 && args[0] == "--fake-wm") return FakeAdb(new[] { "-s", "emulator-5554", "shell", "wm" }.Concat(args.Skip(1)).ToArray());
        if (args.Length > 0 && args[0] == "-s") return FakeAdb(args);
        fixture = args[0];
        Test("Windows native argument roundtrip, including empty, quotes, Unicode and shell characters", delegate {
            string[] values = { "", "plain", "with spaces", "中文文件", "C:\\space dir\\", "a\\\"b", "quoted\"text", "$(echo unsafe); &|<>%PATH%", "a\tline", "a\nline" };
            CommandResult r = ProcessRunner.Run(Self, Child("echo").Concat(values), 10000);
            Check(r.Success, r.Error);
            string[] actual = r.Output.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries).Select(x => Encoding.UTF8.GetString(Convert.FromBase64String(x))).ToArray();
            // Empty argv is represented by an empty Base64 line, so retain its position separately.
            string normalized = r.Output.Replace("\r\n", "\n");
            string[] encoded = normalized.Substring(0, normalized.Length - 1).Split('\n');
            Check(encoded.Length == values.Length, "An empty argument or a boundary was lost.");
            for (int i = 0; i < values.Length; i++) Check(Encoding.UTF8.GetString(Convert.FromBase64String(encoded[i])) == values[i], "Wrong argument at " + i);
            Check(actual.Length == values.Length - 1, "Unexpected child output.");
        });
        Test("Serial validation rejects foreign devices and injection", delegate {
            foreach (string serial in new[] { "emulator-5554", "emulator-5584" }) CommandLine.ValidateSerial(serial);
            foreach (string serial in new[] { "emulator-5555", "emulator-5552", "emulator-5586", "device123", "emulator-5554\n", "emulator-5554 -s other", "EMULATOR-5554", "emulator-05554", "" })
                Reject(delegate { CommandLine.ValidateSerial(serial); }, "Accepted " + serial);
        });
        Test("Both redirected streams are drained without deadlock", delegate {
            CommandResult r = ProcessRunner.Run(Self, Child("io"), 10000);
            Check(r.Success && r.Output.EndsWith("OUT-END") && r.Error.EndsWith("ERR-END"), "One redirected pipe blocked or lost output.");
        });
        Test("Timeout terminates its own process while preserving an unrelated sibling", delegate {
            using (Process sibling = StartSleeper())
            {
                try { Stopwatch watch = Stopwatch.StartNew(); CommandResult r = ProcessRunner.Run(Self, Child("sleep"), 200); Check(r.TimedOut && !r.Success && watch.ElapsedMilliseconds < 5000 && !sibling.HasExited, "Timeout ownership or bound violated."); }
                finally { if (!sibling.HasExited) { sibling.Kill(); sibling.WaitForExit(3000); } }
            }
        });
        Test("Missing executable is a failed result", delegate {
            CommandResult r = ProcessRunner.Run(Path.Combine(fixture, "missing.exe"), new string[0], 1000);
            Check(!r.Success && !r.TimedOut && !String.IsNullOrEmpty(r.Error), "Missing executable was not reported.");
        });
        Test("PNG is atomically replaced only after successful complete command", delegate {
            string path = Path.Combine(fixture, "截图.png"); byte[] original = Encoding.UTF8.GetBytes("keep existing file"); File.WriteAllBytes(path, original);
            foreach (string mode in new[] { "bad-png", "png-error", "png-sleep" })
            {
                CommandResult bad = ProcessRunner.RunBinary(Self, Child(mode), mode == "png-sleep" ? 200 : 10000, path);
                Check(!bad.Success && File.ReadAllBytes(path).SequenceEqual(original), "Failed capture replaced existing destination: " + mode);
            }
            CommandResult good = ProcessRunner.RunBinary(Self, Child("png"), 10000, path);
            Check(good.Success && File.ReadAllBytes(path).SequenceEqual(Png), good.Error);
            Check(Directory.GetFiles(fixture, "*.tmp").Length == 0, "Capture left a temporary file.");
        });
        Test("Process identity uses executable path and exact creation time", delegate {
            ProcessIdentity me = ProcessIdentity.Capture(Process.GetCurrentProcess().Id);
            Check(me.IsCurrent() && me.ParentPid > 0 && !String.IsNullOrEmpty(me.CommandLine), "Current identity not confirmed.");
            me.StartTimeUtcTicks++; Check(!me.IsCurrent(), "A reused identity passed timestamp validation.");
            me = ProcessIdentity.Capture(Process.GetCurrentProcess().Id); me.Path = Path.Combine(fixture, "foreign.exe"); Check(!me.IsCurrent(), "A foreign path passed identity validation.");
            Process child = StartSleeper(); ProcessIdentity identity;
            try { identity = ProcessIdentity.Capture(child.Id); } finally { StopChild(child); }
            Check(!identity.IsCurrent(), "An exited process passed identity validation.");
        });
        Test("Device operations remain serial-scoped and preserve shell-sensitive filenames", delegate {
            string adb = Path.Combine(fixture, "fixture adb.exe"); File.Copy(Self, adb);
            string log = Path.Combine(fixture, "adb.log"); string previous = Environment.GetEnvironmentVariable("ARTEMIS_FRONTEND_TEST_ADB_LOG");
            Environment.SetEnvironmentVariable("ARTEMIS_FRONTEND_TEST_ADB_LOG", log);
            try
            {
                DeviceClient d = new DeviceClient(adb, "emulator-5554");
                Check(d.KeyAsync(3).Result.Success, "Key failed.");
                string screenshot = Path.Combine(fixture, "device.png"); Check(d.ScreenshotAsync(screenshot).Result.Success && File.ReadAllBytes(screenshot).SequenceEqual(Png), "Screenshot lost binary output.");
                string apk = Path.Combine(fixture, "测试 app.apk"); File.WriteAllText(apk, "fixture"); Check(d.InstallAsync(apk).Result.Success, "Install failed.");
                string import = Path.Combine(fixture, "a' $(touch bad);图.jpg"); File.WriteAllText(import, "fixture"); Check(d.ImportAsync(import).Result.Success, "Import failed.");
                Check(d.RotateAsync().Result.Success, "Rotate failed.");
                string[][] commands = ReadAdbLog(log);
                Check(commands.All(c => c.Length > 2 && c[0] == "-s" && c[1] == "emulator-5554" && !c.Contains("kill-server")), "Device isolation violated.");
                Check(commands.Any(c => c.Skip(2).SequenceEqual(new[] { "shell", "input", "keyevent", "3" })), "Key argv was malformed.");
                Check(commands.Any(c => c.Skip(2).SequenceEqual(new[] { "install", "-r", apk })), "Install path or replace flag lost.");
                Check(commands.Any(c => c.Skip(2).SequenceEqual(new[] { "push", import, "/sdcard/Download/a' $(touch bad);图.jpg" })), "Import path was shell-expanded.");
                Check(commands.Any(c => c.Length == 4 && c[2] == "shell" && c[3] == "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d 'file:///sdcard/Download/a%27%20%24%28touch%20bad%29%3B%E5%9B%BE.jpg'"), "Media scanner URI was not escaped and shell-quoted.");
                Check(commands.Any(c => c.Skip(2).SequenceEqual(new[] { "shell", "wm", "fixed-to-user-rotation", "-d", "0", "enabled" })), "Rotation did not override app-requested portrait orientation.");
                Check(commands.Any(c => c.Skip(2).SequenceEqual(new[] { "shell", "wm", "user-rotation", "-d", "0", "lock", "1" })), "Rotation used a stale lock setting instead of the actual default display.");
            }
            finally { Environment.SetEnvironmentVariable("ARTEMIS_FRONTEND_TEST_ADB_LOG", previous); }
        });
        Test("Queued device work is rejected after ownership changes", delegate {
            WithAdb("guard-queued", delegate(DeviceClient d, string log) {
                int valid = 1;
                SetBeforeCommand(d, delegate { if (Interlocked.CompareExchange(ref valid, 0, 0) == 0) throw new InvalidOperationException("fixture backend changed"); });
                string release = log + ".release"; Environment.SetEnvironmentVariable("ARTEMIS_FRONTEND_TEST_ADB_GATE", release);
                Task<CommandResult> first = d.ExecuteAsync("get-state");
                var deadline = DateTime.UtcNow.AddSeconds(4);
                while (!File.Exists(log) && DateTime.UtcNow < deadline) Thread.Sleep(10);
                Check(File.Exists(log), "The first command did not enter the fixture.");
                Task<CommandResult> queued = d.KeyAsync(3);
                Interlocked.Exchange(ref valid, 0); File.WriteAllText(release, "release");
                Check(first.Result.Success, "The original running command failed.");
                bool refused = false; try { var ignored = queued.Result; } catch (AggregateException ex) { refused = ex.GetBaseException() is InvalidOperationException; }
                Check(refused && ReadAdbLog(log).Length == 1, "Queued command reached the replacement device.");
            });
        });
        Test("Multi-step import revalidates before every ADB command", delegate {
            WithAdb("guard-import", delegate(DeviceClient d, string log) {
                SetBeforeCommand(d, delegate { if (File.Exists(log)) throw new InvalidOperationException("fixture backend changed after mkdir"); });
                string file = Path.Combine(fixture, "guard import.jpg"); File.WriteAllText(file, "fixture");
                bool refused = false; try { var ignored = d.ImportAsync(file).Result; } catch (AggregateException ex) { refused = ex.GetBaseException() is InvalidOperationException; }
                Check(refused && ReadAdbLog(log).Length == 1, "The import pushed or scanned a replacement device.");
            });
        });
        Test("Screenshot revalidates immediately before its binary process", delegate {
            WithAdb("guard-screenshot", delegate(DeviceClient d, string log) {
                int checks = 0;
                SetBeforeCommand(d, delegate { if (Interlocked.Increment(ref checks) > 1) throw new InvalidOperationException("fixture backend changed"); });
                string path = Path.Combine(fixture, "guard screenshot.png"); File.WriteAllText(path, "preserve");
                bool refused = false; try { var ignored = d.ScreenshotAsync(path).Result; } catch (AggregateException ex) { refused = ex.GetBaseException() is InvalidOperationException; }
                Check(refused && !File.Exists(log) && File.ReadAllText(path) == "preserve", "Binary capture bypassed its final guard.");
            });
        });
        Test("Default display rotation parser excludes encoder displays and user lock settings", delegate {
            Type parser = typeof(DeviceClient).Assembly.GetType("ArtemisOS.Frontend.RotationState");
            Check(parser != null, "The default display rotation parser is not implemented.");
            var parse = parser.GetMethod("ParseDefaultDisplayRotation");
            for (int rotation = 0; rotation < 4; rotation++) {
                string text = "  Display: mDisplayId=2\n    mRotation=ROTATION_270\n  Display: mDisplayId=0\n    mRotation=ROTATION_" + (rotation * 90) + " mUserRotation=ROTATION_90\n  Display: mDisplayId=3\n    mRotation=ROTATION_180\n";
                Check((int)parse.Invoke(null, new object[] { text }) == rotation, "Read a mirror or user-lock rotation.");
                Check((int)parse.Invoke(null, new object[] { "Display: mDisplayId=0\n mRotation=" + rotation + "\n" }) == rotation, "Numeric rotation was not read.");
            }
            foreach (string invalid in new[] { "Display: mDisplayId=2\n mRotation=0\n", "Display: mDisplayId=0\n mUserRotation=1\n", "Display: mDisplayId=0\n overrideConfig={winConfig={ mRotation=ROTATION_0} s.1}\n", "Display: mDisplayId=0\n mRotation=7\n", "Display: mDisplayId=0\n mRotation=0\nDisplay: mDisplayId=0\n mRotation=1\n", "Display: mDisplayId=0\n mRotation=0\n mRotation=1\n", "Display: mDisplayId=0\n mRotation=0 mRotation=1\n" }) {
                bool refused = false; try { parse.Invoke(null, new object[] { invalid }); } catch (System.Reflection.TargetInvocationException ex) { refused = ex.InnerException is InvalidDataException; }
                Check(refused, "Ambiguous/missing default rotation was accepted: " + invalid);
            }
        });
        Test("Default rotation ignores real nested overrideConfig rotation fields", delegate {
            for (int rotation = 0; rotation < 4; rotation++) {
                string dump = "WINDOW MANAGER DISPLAY CONTENTS\n  Display: mDisplayId=2 rootTasks=0\n    overrideConfig={winConfig={ mRotation=ROTATION_270} s.1}\n    mRotation=3 mDeferredRotationPauseCount=0\n  Display: mDisplayId=0 rootTasks=1\n    overrideConfig={1.0 ?mcc0mnc [zh_CN] winConfig={ mRotation=ROTATION_0} s.1}\n      overrideConfig={0.0 ?mcc0mnc winConfig={ mRotation=undefined} s.1}\n    mRotation=" + rotation + " mDeferredRotationPauseCount=0\n    mUserRotationMode=USER_ROTATION_LOCKED mUserRotation=ROTATION_90\n";
                Check(RotationState.ParseDefaultDisplayRotation(dump) == rotation, "Nested configuration shadowed the actual default display rotation.");
            }
        });
        Test("Rotation toggles actual display axes and restore releases app orientation", delegate {
            WithAdb("rotation-toggle", delegate(DeviceClient d, string log) {
                Check(d.RotateAsync().Result.Success, "Default portrait display did not become landscape.");
                Check(d.RotateAsync().Result.Success, "Default landscape display did not return to portrait.");
                var restore = typeof(DeviceClient).GetMethod("RestoreRotationAsync"); Check(restore != null, "RestoreRotationAsync is not implemented.");
                Check(((Task<CommandResult>)restore.Invoke(d, null)).Result.Success, "Restore rotation failed.");
                string[] commands = ReadAdbLog(log).Select(c => String.Join(" ", c.Skip(2))).ToArray();
                Check(commands.Count(c => c == "shell wm user-rotation -d 0 lock 1") == 1 && commands.Count(c => c == "shell wm user-rotation -d 0 lock 0") == 1, "Axes did not toggle using the actual display.");
                Check(commands.Contains("shell wm fixed-to-user-rotation -d 0 default") && commands.Contains("shell wm user-rotation -d 0 free"), "Restore left the app locked to the frontend override.");
            });
        });
        Test("Malformed, rejected and ineffective rotation changes are failures", delegate {
            WithAdb("rotation-failed", delegate(DeviceClient d, string log) {
                Environment.SetEnvironmentVariable("ARTEMIS_FRONTEND_TEST_FAIL_COMMAND", "shell wm fixed-to-user-rotation -d 0 enabled");
                Check(!d.RotateAsync().Result.Success && File.ReadAllText(log + ".fixed") == "default", "Rejected WM command was reported successful or left a fixed override.");
                Environment.SetEnvironmentVariable("ARTEMIS_FRONTEND_TEST_FAIL_COMMAND", null);
                Environment.SetEnvironmentVariable("ARTEMIS_FRONTEND_TEST_BAD_ROTATION", "1");
                Check(!d.RotateAsync().Result.Success, "A mirror-only dump was reported successful.");
                Environment.SetEnvironmentVariable("ARTEMIS_FRONTEND_TEST_BAD_ROTATION", null);
                Environment.SetEnvironmentVariable("ARTEMIS_FRONTEND_TEST_IGNORE_ROTATION", "1");
                Check(!d.RotateAsync().Result.Success, "A successful WM exit with unchanged physical rotation was reported successful.");
            });
        });
        Test("Failed rotation lock rolls back both original persistent modes", delegate {
            WithAdb("rotation-rollback", delegate(DeviceClient d, string log) {
                File.WriteAllText(log + ".fixed", "disabled"); File.WriteAllText(log + ".user", "free");
                Environment.SetEnvironmentVariable("ARTEMIS_FRONTEND_TEST_FAIL_COMMAND", "shell wm user-rotation -d 0 lock 1");
                CommandResult result = d.RotateAsync().Result;
                Check(!result.Success, "Failed lock was reported successful.");
                Check(File.ReadAllText(log + ".fixed") == "disabled" && File.ReadAllText(log + ".user") == "free", "Failed lock left a persistent rotation override.");
                Check(ReadAdbLog(log).Any(c => c.Length == 4 && c[2] == "shell" && c[3].Contains("\n")), "The two rotation writes were not one guarded ADB operation.");
            });
        });
        Test("Cancelling before the rotation batch leaves both modes unchanged", delegate {
            WithAdb("rotation-cancel-before-write", delegate(DeviceClient d, string log) {
                File.WriteAllText(log + ".fixed", "disabled"); File.WriteAllText(log + ".user", "free");
                SetBeforeCommand(d, delegate { if (File.Exists(log) && ReadAdbLog(log).Length >= 3) throw new InvalidOperationException("fixture closed before rotation batch"); });
                bool refused = false; try { var ignored = d.RotateAsync().Result; } catch (AggregateException ex) { refused = ex.GetBaseException() is InvalidOperationException; }
                Check(refused && ReadAdbLog(log).Length == 3 && !File.Exists(log + ".rotation") && File.ReadAllText(log + ".fixed") == "disabled" && File.ReadAllText(log + ".user") == "free", "Cancellation split or started the persistent rotation writes.");
            });
        });
        Test("Ineffective rotation restores the original locked mode", delegate {
            WithAdb("rotation-ineffective-rollback", delegate(DeviceClient d, string log) {
                File.WriteAllText(log + ".fixed", "enabled_if_no_auto_rotation"); File.WriteAllText(log + ".user", "lock 3");
                Environment.SetEnvironmentVariable("ARTEMIS_FRONTEND_TEST_IGNORE_ROTATION", "1");
                Check(!d.RotateAsync().Result.Success, "An ineffective rotation succeeded.");
                Check(File.ReadAllText(log + ".fixed") == "enabled_if_no_auto_rotation" && File.ReadAllText(log + ".user") == "lock 3", "Verification failure did not restore the original lock.");
            });
        });
        Test("Invalid original fixed mode is rejected before any rotation write", delegate {
            WithAdb("rotation-mode-invalid", delegate(DeviceClient d, string log) {
                File.WriteAllText(log + ".fixed", "enabled; echo unsafe");
                Check(!d.RotateAsync().Result.Success && !File.Exists(log + ".user") && !File.Exists(log + ".rotation"), "An unvalidated fixed mode reached a writing command.");
            });
        });
        Test("Viewer is scoped, conservative and has no shared ADB shutdown", delegate {
            string[] v = ViewerArguments.Build("emulator-5554", "ArtemisOS 测试");
            Check(v.Take(2).SequenceEqual(new[] { "-s", "emulator-5554" }) && v.Contains("--window-title=ArtemisOS 测试"), "Viewer identity/title missing.");
            foreach (string required in new[] { "--window-borderless", "--no-audio", "--video-codec=h264", "--video-encoder=c2.android.avc.encoder", "--max-size=1280", "--max-fps=20", "--video-bit-rate=4M", "--render-driver=direct3d", "--pause-on-exit=false" }) Check(v.Contains(required), "Unsafe viewer default: " + required);
            Check(!v.Contains("--kill-adb-on-close") && !v.Contains("--no-cleanup"), "Viewer can damage another ADB session or leave its server.");
        });
        Test("Paths support incomplete fixtures and read version.ini", delegate {
            string root = Path.Combine(fixture, "未安装 fixture"); FrontendPaths p = new FrontendPaths(root);
            Check(p.ViewerExe == Path.Combine(root, "update", "frontend", "runtime", "scrcpy.exe") && p.ConfigureScript == Path.Combine(root, "configure.ps1"), "Delivery paths mismatch.");
            Check(!Directory.Exists(root), "Path construction changed the filesystem.");
            Directory.CreateDirectory(root); File.WriteAllText(Path.Combine(root, "version.ini"), "[ArtemisOS]\r\nVersion=1.2.3\r\n"); Check(p.Version == "1.2.3", "Version was not read from installation.");
        });
        Console.WriteLine("Frontend core tests: " + (failed == 0 ? "PASS" : failed + " FAILED"));
        return failed == 0 ? 0 : 1;
    }
}
