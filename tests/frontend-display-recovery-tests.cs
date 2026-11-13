using System;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using ArtemisOS.Frontend;

internal static class FrontendDisplayRecoveryTests
{
    private static void Check(bool ok, string message) { if (!ok) throw new Exception(message); }
    [STAThread]
    private static int Main(string[] args)
    {
        try {
            var now = new DateTime(2026,11,12,0,0,0,DateTimeKind.Utc);
            var slow = new DisplayRecovery();
            for(int i=0;i<3;i++) Check(slow.TryRecover(now.AddSeconds(31*i)),"Slow failures still allow three attempts.");
            Check(!slow.TryRecover(now.AddSeconds(93)),"A single slow recovery episode must stop after three attempts, even across minute windows.");
            var recovery = new DisplayRecovery();
            Check(!recovery.Observe("INFO: Texture: 576x1280",now),"A healthy or static screen must not trigger recovery.");
            Check(!recovery.Observe("ERROR: Frame update failed",now),"One failure must not restart the viewer.");
            Check(!recovery.Observe("ERROR: Frame update failed",now.AddSeconds(3)),"An isolated old failure must expire.");
            Check(!recovery.Observe("ERROR: Frame update failed",now.AddSeconds(3.1)),"Two recent failures must not restart the viewer.");
            Check(recovery.Observe("ERROR: Frame update failed",now.AddSeconds(3.2)),"Three recent renderer failures must trigger recovery.");
            recovery.ResetFrames();
            Check(!recovery.Observe("ERROR: Frame update failed",now.AddSeconds(4)),"A replacement viewer starts a new failure count.");
            for(int i=0;i<3;i++) Check(recovery.TryRecover(now.AddSeconds(i)),"Three attempts must be available.");
            Check(!recovery.TryRecover(now.AddSeconds(59)),"Persistent failure must not cause an endless restart loop.");
            recovery.BeginEpisode();
            Check(recovery.TryRecover(now.AddMinutes(1)),"The bounded retry window must expire.");

            // Exercise the real shell message handler, with no Android or SDL
            // processes. Merely creating its handle does not run Shown/startup.
            Directory.CreateDirectory(args[0]);
            File.WriteAllText(Path.Combine(args[0],"launch.ps1"),"# isolated layout fixture");
            Application.EnableVisualStyles();
            using(var shell = new ShellForm(new FrontendOptions {Root=args[0]})) {
                IntPtr handle=shell.Handle;
                MethodInfo wndproc=typeof(ShellForm).GetMethod("WndProc",BindingFlags.Instance|BindingFlags.NonPublic);
                IntPtr rect=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(NativeDisplay.NativeRect)));
                try {
                    foreach(int dpi in new[]{144,96,192,120,96}) {
                        var bounds=new NativeDisplay.NativeRect {Left=100,Top=100,Right=100+454*dpi/96,Bottom=100+928*dpi/96};
                        Marshal.StructureToPtr(bounds,rect,false);
                        var message=Message.Create(handle,0x2e0,new IntPtr(dpi|(dpi<<16)),rect);
                        wndproc.Invoke(shell,new object[]{message});
                        double scale=(double)typeof(ShellForm).GetField("scale",BindingFlags.Instance|BindingFlags.NonPublic).GetValue(shell);
                        var layout=(FrontendLayout)typeof(ShellForm).GetField("layout",BindingFlags.Instance|BindingFlags.NonPublic).GetValue(shell);
                        Check(Math.Abs(scale-dpi/96.0)<0.001,"WM_DPICHANGED must update the shell DPI.");
                        Check(layout.Video.Bottom<=layout.Footer.Top && layout.Video.Right<layout.Toolbar.Left,"DPI reflow must keep video inside its allotted region.");
                    }
                    wndproc.Invoke(shell,new object[]{Message.Create(handle,0x7e,IntPtr.Zero,IntPtr.Zero)});
                    var timer=(Timer)typeof(ShellForm).GetField("displayChangeTimer",BindingFlags.Instance|BindingFlags.NonPublic).GetValue(shell);
                    Check(timer.Enabled && timer.Interval==1000,"Display changes must schedule a coalesced layout/display refresh.");
                } finally {Marshal.FreeHGlobal(rect);}
            }
            Console.WriteLine("PASS: renderer failure threshold, bounded retries, static-screen isolation, five DPI transitions and display-change debounce.");
            return 0;
        } catch(Exception ex) {Console.WriteLine("FAIL: "+ex.GetBaseException().Message);return 1;}
    }
}
