using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace ArtemisOS.Frontend
{
    internal static class SessionFixture
    {
        private static string Root;
        private static string UnrelatedRoot;
        private static readonly string Self = Assembly.GetExecutingAssembly().Location;
        [STAThread]
        private static int Main(string[] args)
        {
            string name = Path.GetFileName(Self);
            if (name == "emulator.exe" || name == "qemu-system-x86_64-headless.exe" || name == "adb.exe" || name == "scrcpy.exe")
                return Fake(name, args);
            Root = Path.GetFullPath(args[1]);
            try { Test(args[0]).GetAwaiter().GetResult(); Console.WriteLine("PASS session: " + args[0]); return 0; }
            catch (Exception ex) { Console.WriteLine("FAIL session: " + args[0] + " :: " + ex.GetBaseException().Message); return 1; }
            finally { Cleanup(); }
        }

        private static async Task Test(string scenario)
        {
            Prepare(scenario);
            int unrelatedPid=0;
            if(scenario=="normal-isolation") {
                string ownRoot=Root;
                UnrelatedRoot=Root+"-unrelated";
                Root=UnrelatedRoot;Prepare("sentinel");Root=ownRoot;
                var info=new ProcessStartInfo(Path.Combine(UnrelatedRoot,"sdk/emulator/qemu/windows-x86_64/qemu-system-x86_64-headless.exe"),"-port 5578") {UseShellExecute=false,CreateNoWindow=true};
                using(var sentinel=Process.Start(info))unrelatedPid=sentinel.Id;
                await Task.Delay(150);
            }
            using (var session = new FrontendSession(new FrontendOptions { Root = Root, Port = 5554 })) {
                int connected = 0;
                session.ViewerReady += delegate { Interlocked.Increment(ref connected); };
                session.StatusChanged += delegate(string title, string detail) { File.AppendAllText(Path.Combine(Root,"status.log"),title+" "+detail+Environment.NewLine); };
                Task startup = session.StartAsync();
                if (scenario == "cancel-before-receipt" || scenario == "cancel-before-backend") {
                    await WaitFile(scenario == "cancel-before-receipt" ? "emulator.pid" : "launch.marker");
                    await session.StopAsync();
                    await Task.Delay(3000);
                    Assert(!AliveFile("emulator.pid") && !AliveFile("qemu.pid"), "Cancel before receipt must not leave a live emulator or QEMU.");
                    return;
                }
                await Within(startup, 30000, "startup");
                if(scenario=="failed-backend-crashed") {
                    Assert(!session.Ready,"Failed startup is not declared ready.");
                    Assert(!AliveFile("emulator.pid")&&!AliveFile("qemu.pid"),"Failed backend has already exited.");
                    await Within(session.StopAsync(),15000,"close after failed startup with dead backend");
                    return;
                }
                Assert(session.Ready, "Fixture Android must reach ready: " + ReadLastLog());
                Assert(connected == 1, "Viewer ready event once.");
                if (scenario == "backend-crashed") {
                    KillFile("qemu.pid");
                    KillFile("emulator.pid");
                    await Task.Delay(250);
                    await Within(session.StopAsync(),15000,"close after backend crash");
                    Assert(!AliveFile("viewer.pid"), "Closing a crashed backend must stop own viewer.");
                } else if (scenario == "wrapper-crashed") {
                    KillFile("emulator.pid");
                    Assert(AliveFile("qemu.pid"),"QEMU fixture remains alive after wrapper crash.");
                    await Within(session.StopAsync(),20000,"close after wrapper crash");
                    Assert(!AliveFile("viewer.pid") && !AliveFile("qemu.pid"),"Cached verified child identity permits stopping orphaned own QEMU.");
                } else if (scenario == "viewer-crashed") {
                    bool disconnected=false;
                    session.ViewerDisconnected += delegate {disconnected=true;};
                    KillFile("viewer.pid");
                    await Task.Delay(250);
                    Assert(disconnected&&!session.Ready,"Unexpected viewer exit is reported without declaring ready.");
                    Assert(AliveFile("emulator.pid")&&AliveFile("qemu.pid"),"Viewer crash does not kill backend.");
                    await Within(session.StopAsync(),20000,"close after viewer crash");
                    Assert(!AliveFile("qemu.pid"),"Close after viewer crash stops backend.");
                } else if (scenario == "recovery-manual-race") {
                    int backend=Int32.Parse(File.ReadAllText(Path.Combine(Root,"qemu.pid")));
                    File.WriteAllText(Path.Combine(Root,"render-fault-persistent.marker"),"fault");
                    Task recovery=session.RecoverDisplayAsync("fixture renderer failure");
                    await WaitFile("failed-viewer-closing.marker");
                    var reconnectGate=(SemaphoreSlim)typeof(FrontendSession).GetField("reconnectGate",BindingFlags.Instance|BindingFlags.NonPublic).GetValue(session);
                    Assert(reconnectGate.CurrentCount==0,"Failed-viewer cleanup must retain the reconnect gate, so manual recovery cannot be stopped by stale cleanup.");
                    File.Delete(Path.Combine(Root,"render-fault-persistent.marker"));
                    Task manual=session.ReconnectAsync();
                    await Within(manual,15000,"manual reconnect during automatic cleanup");
                    await Within(recovery,15000,"automatic recovery finishes after manual reconnect");
                    Assert(session.Ready&&AliveFile("viewer.pid")&&IsAlive(backend),"Concurrent manual and automatic recovery leave a healthy viewer and the exact Android backend.");
                    await session.StopAsync();
                } else if (scenario == "recovery-coalesced") {
                    int original = Int32.Parse(File.ReadAllText(Path.Combine(Root,"viewer.pid")));
                    Task recovery = session.RecoverDisplayAsync("fixture topology change");
                    for (int i=0; i<10; i++) Assert(Object.ReferenceEquals(recovery,session.RecoverDisplayAsync("duplicate event")),"A display-change burst shares one recovery task.");
                    await Within(recovery,15000,"coalesced recovery");
                    Assert(connected == 2 && session.Ready && !IsAlive(original), "Topology recovery replaces exactly one viewer.");
                    Assert(AliveFile("qemu.pid") && !File.Exists(Path.Combine(Root,"adb-kill.marker")),"Topology recovery preserves Android.");
                    await session.StopAsync();
                } else if (scenario == "recovery-close-race") {
                    Task recovery = session.RecoverDisplayAsync("fixture topology change");
                    await Within(session.StopAsync(),20000,"close during display recovery");
                    await Within(recovery,5000,"cancel recovery");
                    Assert(connected == 1 && !AliveFile("viewer.pid") && !AliveFile("qemu.pid"),"A cancelled recovery must not resurrect a display or backend.");
                } else if (scenario == "renderer-reset") {
                    int original = Int32.Parse(File.ReadAllText(Path.Combine(Root,"viewer.pid")));
                    int backend = Int32.Parse(File.ReadAllText(Path.Combine(Root,"qemu.pid")));
                    File.WriteAllText(Path.Combine(Root,"render-fault.marker"),"fault");
                    var deadline = DateTime.UtcNow.AddSeconds(10);
                    while (connected < 2 && DateTime.UtcNow < deadline) await Task.Delay(50);
                    Assert(connected == 2 && session.Ready, "Repeated frame failures must reconnect the display automatically.");
                    Assert(!IsAlive(original), "Recovery closes the failed viewer.");
                    Assert(IsAlive(backend) && AliveFile("emulator.pid"), "Recovery preserves the exact Android backend.");
                    Assert(!File.Exists(Path.Combine(Root,"adb-kill.marker")), "Recovery must not restart Android.");
                    await session.StopAsync();
                } else if (scenario == "renderer-reset-limit") {
                    File.WriteAllText(Path.Combine(Root,"render-fault-persistent.marker"),"fault");
                    var deadline = DateTime.UtcNow.AddSeconds(15);
                    while (File.ReadAllLines(Path.Combine(Root,"viewer-starts.log")).Length < 4 && DateTime.UtcNow < deadline) await Task.Delay(50);
                    Assert(File.ReadAllLines(Path.Combine(Root,"viewer-starts.log")).Length == 4, "Three automatic display recovery attempts must be available, even if a replacement fails before ready.");
                    await Task.Delay(2500);
                    Assert(File.ReadAllLines(Path.Combine(Root,"viewer-starts.log")).Length == 4 && !session.Ready, "Persistent render failure must stop retrying and report disconnected.");
                    Assert(AliveFile("emulator.pid") && AliveFile("qemu.pid"), "Exhausted display recovery preserves Android.");
                    File.Delete(Path.Combine(Root,"render-fault-persistent.marker"));
                    await session.ReconnectAsync();
                    Assert(session.Ready && File.ReadAllLines(Path.Combine(Root,"viewer-starts.log")).Length == 5, "Manual reconnect remains available after automatic retries stop.");
                    await session.StopAsync();
                } else if (scenario == "reconnect") {
                    int original = Int32.Parse(File.ReadAllText(Path.Combine(Root,"viewer.pid")));
                    await Within(session.ReconnectAsync(),15000,"reconnect");
                    Assert(connected == 2, "Reconnect emits second viewer ready.");
                    Assert(!IsAlive(original), "Old viewer exits before reconnect completes.");
                    Assert(AliveFile("emulator.pid") && AliveFile("qemu.pid"), "Reconnect preserves backend.");
                    Assert(!File.Exists(Path.Combine(Root,"adb-kill.marker")), "Reconnect does not send backend kill.");
                    await session.StopAsync();
                } else if (scenario == "update" || scenario == "update-close-race" || scenario == "recovery-update-race") {
                    string id = (string)typeof(FrontendSession).GetField("sessionId",BindingFlags.Instance|BindingFlags.NonPublic).GetValue(session);
                    bool closeRequested = false;
                    session.CloseRequested += delegate { closeRequested = true; };
                    string pipeName = "ArtemisOS-Frontend-" + Program.RootHash(Root) + "-" + id;
                    Task concurrentClose=null;
                    Task recovery = scenario == "recovery-update-race" ? session.RecoverDisplayAsync("fixture topology change") : null;
                    using (var pipe = new NamedPipeClientStream(".",pipeName,PipeDirection.InOut,PipeOptions.Asynchronous)) {
                        await pipe.ConnectAsync(5000);
                        using (var writer = new StreamWriter(pipe,new UTF8Encoding(false),1024,true) {AutoFlush=true})
                        using (var reader = new StreamReader(pipe,Encoding.UTF8,false,1024,true)) {
                            await writer.WriteLineAsync("prepare-update:" + id);
                            Task<string> responseTask=reader.ReadLineAsync();
                            if(scenario=="update-close-race") {
                                await WaitFile("viewer-closing.marker");
                                Assert(session.Updating,"Updater decision is pending while the viewer closes.");
                                concurrentClose=session.StopAsync();
                            }
                            await Within(responseTask,10000,"update ready response");
                            string response = await responseTask;
                            Assert(response == "ready:"+id,"Updater receives exact ready receipt.");
                        }
                    }
                    if(concurrentClose!=null)await Within(concurrentClose,15000,"concurrent close during update handshake");
                    await Task.Delay(200);
                    if(recovery!=null) {
                        await Within(recovery,5000,"update cancels display recovery");
                        Assert(connected==1,"An updater handoff must not resurrect the display.");
                    }
                    Assert(closeRequested && session.Updating,"Update requests frontend close in Updating state.");
                    await session.StopAsync();
                    Assert(!AliveFile("viewer.pid"),"Update stops own viewer.");
                    Assert(AliveFile("emulator.pid") && AliveFile("qemu.pid"),"Update handshake leaves backend for updater.");
                    Assert(!File.Exists(Path.Combine(Root,"adb-kill.marker")),"Update frontend never sends backend kill.");
                } else {
                    await Within(session.StopAsync(),20000,"normal close");
                    Assert(!AliveFile("viewer.pid") && !AliveFile("qemu.pid"),"Normal close stops own viewer and backend.");
                    if(unrelatedPid!=0)Assert(IsAlive(unrelatedPid),"Normal close never stops another installation's QEMU.");
                }
                string adbLog = File.Exists(Path.Combine(Root,"adb.log")) ? File.ReadAllText(Path.Combine(Root,"adb.log")) : "";
                Assert(!adbLog.Contains("kill-server"),"Shared ADB server is untouched.");
            }
        }

        private static void Prepare(string scenario)
        {
            Directory.CreateDirectory(Root);
            foreach(string rel in new[]{"sdk/emulator/emulator.exe","sdk/emulator/qemu/windows-x86_64/qemu-system-x86_64-headless.exe","sdk/platform-tools/adb.exe","update/frontend/runtime/scrcpy.exe"}) {
                string file=Path.Combine(Root,rel.Replace('/',Path.DirectorySeparatorChar)); Directory.CreateDirectory(Path.GetDirectoryName(file)); File.Copy(Self,file);
            }
            File.WriteAllText(Path.Combine(Root,"update/frontend/runtime/scrcpy-server"),"fixture");
            File.WriteAllText(Path.Combine(Root,"scenario.txt"),scenario);
            File.WriteAllText(Path.Combine(Root,"launch.ps1"), LaunchScript, new UTF8Encoding(true));
        }

        private const string LaunchScript = @"param([string]$Graphics,[int]$Port,[switch]$ExternalDisplay,[string]$SessionId,[int]$FrontendPid,[string]$FrontendStartTimeUtcTicks)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
[IO.File]::WriteAllText((Join-Path $root 'launch.marker'),'started')
if((Get-Content -LiteralPath (Join-Path $root 'scenario.txt') -Raw) -eq 'cancel-before-backend'){Start-Sleep -Milliseconds 2000}
$p=Start-Process -FilePath (Join-Path $root 'sdk\emulator\emulator.exe') -ArgumentList @('-port',$Port,'-fixture-root',('""'+$root+'""')) -PassThru -WindowStyle Hidden
while(-not (Test-Path -LiteralPath (Join-Path $root 'qemu.pid'))){ Start-Sleep -Milliseconds 20 }
if((Get-Content -LiteralPath (Join-Path $root 'scenario.txt') -Raw) -eq 'cancel-before-receipt'){Start-Sleep -Milliseconds 2000}
$data=@{schemaVersion=1;sessionId=$SessionId;installRoot=$root;serial=('emulator-'+$Port);emulatorPid=$p.Id;emulatorStartTimeUtcTicks=($p.StartTime.ToUniversalTime().Ticks.ToString());frontendPid=$FrontendPid;frontendStartTimeUtcTicks=$FrontendStartTimeUtcTicks;state='ready';actualRenderer='Intel fixture Vulkan';error=''}
if((Get-Content -LiteralPath (Join-Path $root 'scenario.txt') -Raw) -eq 'failed-backend-crashed'){
    [IO.File]::WriteAllText((Join-Path $root 'stop.marker'),'stop')
    if(-not $p.WaitForExit(3000)){throw 'Fixture backend exit timed out.'}
    $data.state='failed';$data.error='Fixture failed initialization and backend exited.'
}
$dir=Join-Path $root 'data\runtime'
[IO.Directory]::CreateDirectory($dir)|Out-Null
$temp=Join-Path $dir ($SessionId+'.tmp')
[IO.File]::WriteAllText($temp,($data|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
[IO.File]::Move($temp,(Join-Path $dir ($SessionId+'.json')))
";

        private static int Fake(string name,string[] args)
        {
            Root=FindRoot(Self);
            int pid=Process.GetCurrentProcess().Id;
            if(name=="emulator.exe") {
                File.WriteAllText(Path.Combine(Root,"emulator.pid"),pid.ToString());
                var info=new ProcessStartInfo(Path.Combine(Root,"sdk/emulator/qemu/windows-x86_64/qemu-system-x86_64-headless.exe"),"-port 5554") {UseShellExecute=false,CreateNoWindow=true};
                using(var qemu=Process.Start(info)) qemu.WaitForExit();
                return 0;
            }
            if(name=="qemu-system-x86_64-headless.exe") {
                File.WriteAllText(Path.Combine(Root,"qemu.pid"),pid.ToString());
                while(!File.Exists(Path.Combine(Root,"stop.marker")))Thread.Sleep(30);
                return 0;
            }
            if(name=="adb.exe") {
                File.AppendAllText(Path.Combine(Root,"adb.log"),CommandLine.Join(args)+Environment.NewLine);
                string joined=String.Join(" ",args);
                if(joined.Contains("emu kill")){File.WriteAllText(Path.Combine(Root,"adb-kill.marker"),"kill");File.WriteAllText(Path.Combine(Root,"stop.marker"),"stop");}
                else if(joined.Contains("get-state"))Console.WriteLine("device");
                return 0;
            }
            if(name=="scrcpy.exe") {
                File.WriteAllText(Path.Combine(Root,"viewer.pid"),pid.ToString());
                File.AppendAllText(Path.Combine(Root,"viewer-starts.log"),pid+Environment.NewLine);
                string title="";foreach(string a in args)if(a.StartsWith("--window-title="))title=a.Substring(15);
                Application.EnableVisualStyles();
                var form=new FixtureViewerForm {Text=title,StartPosition=FormStartPosition.Manual,Left=-30000,Top=-30000,Width=240,Height=400,ShowInTaskbar=false};
                if(File.Exists(Path.Combine(Root,"render-fault-persistent.marker"))) {
                    for(int i=0;i<3;i++)Console.Error.WriteLine("ERROR: Frame update failed");
                    Console.Error.Flush();
                }
                Console.WriteLine("INFO: Texture: 576x1280");
                Console.Out.Flush();
                using (var timer = new System.Windows.Forms.Timer { Interval=100 }) {
                    timer.Tick += delegate {
                        string once=Path.Combine(Root,"render-fault.marker");
                        if (!File.Exists(once) && !File.Exists(Path.Combine(Root,"render-fault-persistent.marker"))) return;
                        if (File.Exists(once)) File.Delete(once);
                        for (int i=0; i<3; i++) Console.Error.WriteLine("ERROR: Frame update failed");
                        Console.Error.Flush();
                    };
                    timer.Start();
                Application.Run(form);
                }
                return 0;
            }
            return 3;
        }

        private sealed class FixtureViewerForm : Form
        {
            private bool delayed;
            protected override void OnFormClosing(FormClosingEventArgs e)
            {
                string scenario=File.ReadAllText(Path.Combine(Root,"scenario.txt"));
                bool recoveryCleanup=scenario=="recovery-manual-race"&&File.Exists(Path.Combine(Root,"render-fault-persistent.marker"))&&File.ReadAllLines(Path.Combine(Root,"viewer-starts.log")).Length>1;
                if(!delayed&&(scenario=="update-close-race"||recoveryCleanup)) {
                    delayed=true;
                    e.Cancel=true;
                    File.WriteAllText(Path.Combine(Root,"viewer-closing.marker"),"closing");
                    if(recoveryCleanup)File.WriteAllText(Path.Combine(Root,"failed-viewer-closing.marker"),"closing");
                    var timer=new System.Windows.Forms.Timer {Interval=1000};
                    timer.Tick+=delegate {timer.Stop();timer.Dispose();Close();};
                    timer.Start();
                }
                base.OnFormClosing(e);
            }
        }

        private static string FindRoot(string path)
        {
            var directory=new DirectoryInfo(Path.GetDirectoryName(path));
            while(directory!=null){if(File.Exists(Path.Combine(directory.FullName,"scenario.txt")))return directory.FullName;directory=directory.Parent;}
            throw new IOException("Fixture root not found.");
        }
        private static async Task WaitFile(string name){var end=DateTime.UtcNow.AddSeconds(15);while(DateTime.UtcNow<end){if(File.Exists(Path.Combine(Root,name)))return;await Task.Delay(30);}throw new TimeoutException("Fixture file: "+name);}
        private static async Task Within(Task task,int timeout,string name){if(await Task.WhenAny(task,Task.Delay(timeout))!=task)throw new TimeoutException(name);await task;}
        private static bool AliveFile(string name){string file=Path.Combine(Root,name);return File.Exists(file)&&IsAlive(Int32.Parse(File.ReadAllText(file)));}
        private static bool IsAlive(int pid){try{using(var p=Process.GetProcessById(pid))return !p.HasExited;}catch(ArgumentException){return false;}}
        private static void KillFile(string name)
        {
            string file=Path.Combine(Root,name);if(!File.Exists(file))return;
            try {
                int pid=Int32.Parse(File.ReadAllText(file));
                var identity=ProcessIdentity.Capture(pid);
                string relative=name=="viewer.pid"?"update/frontend/runtime/scrcpy.exe":name=="qemu.pid"?"sdk/emulator/qemu/windows-x86_64/qemu-system-x86_64-headless.exe":"sdk/emulator/emulator.exe";
                if(!String.Equals(identity.Path,Path.GetFullPath(Path.Combine(Root,relative)),StringComparison.OrdinalIgnoreCase)||!identity.IsCurrent())return;
                using(var p=Process.GetProcessById(pid)){if(!p.HasExited){p.Kill();p.WaitForExit(2000);}}
            }catch(ArgumentException){}catch(InvalidOperationException){}
        }
        private static void Assert(bool value,string message){if(!value)throw new Exception(message);}
        private static string ReadLastLog(){string dir=Path.Combine(Root,"data/logs/frontend");if(!Directory.Exists(dir))return "";var files=Directory.GetFiles(dir);return files.Length>0?File.ReadAllText(files[0]):"";}
        private static void Cleanup()
        {
            if(String.IsNullOrEmpty(Root)||!Directory.Exists(Root))return;
            foreach(string name in new[]{"viewer.pid","qemu.pid","emulator.pid"})KillFile(name);
            if(UnrelatedRoot!=null) {
                string ownRoot=Root;Root=UnrelatedRoot;
                foreach(string name in new[]{"viewer.pid","qemu.pid","emulator.pid"})KillFile(name);
                Root=ownRoot;
            }
        }
    }
}
