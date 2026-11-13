using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;

namespace ArtemisOS.Frontend
{
    internal static class NativeDisplay
    {
        private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr parameter);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int count);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr hwnd, uint command);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)] private static extern IntPtr SetWindowLongPtr64(IntPtr hwnd, int index, IntPtr value);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongW", SetLastError = true)] private static extern int SetWindowLong32(IntPtr hwnd, int index, int value);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr64(IntPtr hwnd, int index);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] private static extern int GetWindowLong32(IntPtr hwnd, int index);
        [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);
        [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wparam, IntPtr lparam);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
        [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr hwnd);
        [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int length);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateProcess(IntPtr process, uint code);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder path, ref int length);

        private static string ProcessPath(Process process)
        {
            var text = new StringBuilder(32768);
            int length = text.Capacity;
            if (!QueryFullProcessImageName(process.Handle, 0, text, ref length)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return text.ToString();
        }

        public static bool Matches(ProcessIdentity identity)
        {
            if (identity == null) return false;
            try {
                using (var process = Process.GetProcessById(identity.Pid)) {
                    IntPtr handle = process.Handle;
                    return !process.HasExited && process.StartTime.ToUniversalTime().Ticks == identity.StartTimeUtcTicks &&
                        String.Equals(ProcessPath(process), identity.Path, StringComparison.OrdinalIgnoreCase);
                }
            } catch (ArgumentException) { return false; }
            catch (InvalidOperationException) { return false; }
        }

        public static void StopIdentity(ProcessIdentity identity)
        {
            if (identity == null) return;
            try {
                using (var process = Process.GetProcessById(identity.Pid)) {
                    IntPtr handle = process.Handle; // bind the kernel object before checking; no PID-reuse gap
                    if (process.HasExited || process.StartTime.ToUniversalTime().Ticks != identity.StartTimeUtcTicks ||
                        !String.Equals(ProcessPath(process), identity.Path, StringComparison.OrdinalIgnoreCase)) return;
                    StopOwned(process);
                }
            } catch (ArgumentException) { }
            catch (InvalidOperationException) { }
        }

        public static void StopOwned(Process process)
        {
            // Only accepts the Process object returned by our own Start(), or an
            // object bound and checked above. Never reopens a process by PID here.
            if (!process.HasExited && !TerminateProcess(process.Handle, 1)) {
                if (!process.HasExited) throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }

        public static double Scale(IntPtr hwnd)
        {
            try { return Math.Max(96, GetDpiForWindow(hwnd)) / 96.0; }
            catch (EntryPointNotFoundException) { return 1; }
        }

        public static IntPtr FindViewer(int pid, string title)
        {
            IntPtr found = IntPtr.Zero;
            EnumWindows(delegate(IntPtr hwnd, IntPtr unused) {
                uint id;
                GetWindowThreadProcessId(hwnd, out id);
                if (id != pid || !IsWindowVisible(hwnd)) return true;
                var text = new StringBuilder(512);
                GetWindowText(hwnd, text, text.Capacity);
                if (text.ToString() != title) return true;
                found = hwnd;
                return false;
            }, IntPtr.Zero);
            return found;
        }

        public static void Own(IntPtr viewer, int pid, IntPtr shell)
        {
            uint actual;
            GetWindowThreadProcessId(viewer, out actual);
            if (actual != pid || !IsWindow(shell)) throw new InvalidOperationException("显示窗口身份已发生变化。");
            // GWLP_HWNDPARENT sets the owner of a top-level window. The SDL window
            // stays top-level; its HWND and graphics surface are never recreated.
            if (IntPtr.Size == 8) SetWindowLongPtr64(viewer, -8, shell);
            else SetWindowLong32(viewer, -8, shell.ToInt32());
            if (GetWindow(viewer, 4) != shell) throw new Win32Exception("无法关联显示窗口。");
            long style = IntPtr.Size == 8 ? GetWindowLongPtr64(viewer, -20).ToInt64() : GetWindowLong32(viewer, -20);
            style = (style & ~0x40000L) | 0x80L; // one taskbar entry, owned tool window
            if (IntPtr.Size == 8) SetWindowLongPtr64(viewer, -20, new IntPtr(style));
            else SetWindowLong32(viewer, -20, (int)style);
        }

        public static void Position(IntPtr viewer, Rectangle bounds)
        {
            if (!IsWindow(viewer)) return;
            SetWindowPos(viewer, IntPtr.Zero, bounds.X, bounds.Y,
                bounds.Width, bounds.Height, 0x0010 | 0x0004 | 0x0040); // no activation / no z-order / show
        }

        public static void StyleShell(IntPtr hwnd)
        {
            try {
                int yes = 1, rounded = 2;
                DwmSetWindowAttribute(hwnd, 20, ref yes, 4);
                DwmSetWindowAttribute(hwnd, 33, ref rounded, 4);
            } catch (DllNotFoundException) { }
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct NativeRect { public int Left, Top, Right, Bottom; }
    }
}
