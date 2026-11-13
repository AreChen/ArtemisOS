using System;
using System.ComponentModel;
using System.IO;
using System.Reflection;
using System.Windows.Forms;
using ArtemisOS.Frontend;

internal static class FrontendMenuTests
{
    private const BindingFlags Instance = BindingFlags.Instance | BindingFlags.NonPublic;
    [STAThread]
    private static int Main(string[] args)
    {
        try {
            Application.EnableVisualStyles();
            var options = new FrontendOptions { Root = args[0] };
            using (var form = new ShellForm(options)) {
                // OnClosed(ItemClicked) runs before WinForms finishes reparenting
                // the dropdown. Its handle must remain usable at that boundary.
                using (var constructed = (ContextMenuStrip)Invoke(form, "CreateMoreMenu")) {
                    ItemClickedClosed(constructed);
                    IntPtr handle = constructed.Handle;
                    Check(!constructed.IsDisposed && handle != IntPtr.Zero, "ItemClicked disposed the dropdown before framework dispatch completed.");
                }
                var menu = (ContextMenuStrip)Invoke(form, "PrepareMoreMenu");
                int[] handlers = ClickHandlerCounts(menu);
                for (int i = 0; i < 12; i++) {
                    ItemClickedClosed(menu);
                    Check(menu.Handle != IntPtr.Zero && !menu.IsDisposed, "A closed menu cannot be reused.");
                    Check(Object.ReferenceEquals(menu, Invoke(form, "PrepareMoreMenu")), "The shell replaced its menu instead of reusing it.");
                    int[] again = ClickHandlerCounts(menu);
                    for (int n = 0; n < again.Length; n++) Check(again[n] == handlers[n], "Menu reuse added click handlers.");
                }
                Check(!menu.Items["reconnect"].Enabled && !menu.Items["restart"].Enabled && !menu.Items["restoreRotation"].Enabled,
                    "Unavailable session commands stayed enabled.");
                var session = new FrontendSession(options);
                typeof(ShellForm).GetField("session", Instance).SetValue(form, session);
                // ShowMore itself runs inside RunAction, whose busy flag is set
                // while this menu is being prepared.
                typeof(ShellForm).GetField("busy", Instance).SetValue(form, true);
                Invoke(form, "PrepareMoreMenu");
                Check(menu.Items["reconnect"].Enabled && menu.Items["restart"].Enabled && !menu.Items["restoreRotation"].Enabled,
                    "Reconnect/restart must remain available while the display is disconnected.");
                typeof(FrontendSession).GetProperty("Ready").GetSetMethod(true).Invoke(session, new object[] { true });
                Invoke(form, "PrepareMoreMenu");
                Check(menu.Items["restoreRotation"].Enabled, "Menu reuse did not refresh the ready state.");
                options.AttachSerial = "emulator-5554";
                Invoke(form, "PrepareMoreMenu");
                Check(!menu.Items["restart"].Enabled, "An attached development instance must not be restarted.");
                typeof(ShellForm).GetField("closing", Instance).SetValue(form, true);
                Invoke(form, "PrepareMoreMenu");
                Check(!menu.Items["reconnect"].Enabled && !menu.Items["restart"].Enabled && !menu.Items["restoreRotation"].Enabled,
                    "Closing did not refresh command availability.");
                form.Dispose();
                Check(menu.IsDisposed, "The shell did not dispose its owned menu.");
            }
            using (var form = new ShellForm(options)) {
                IntPtr handle = form.Handle; // Create a hidden owner; never Show or start its session.
                var menu = (ContextMenuStrip)Invoke(form, "PrepareMoreMenu");
                menu.Items[menu.Items.Count - 1].PerformClick();
                Check(!form.IsDisposed, "Exit disposed the owner inside menu click dispatch.");
                Application.DoEvents();
                Check(form.IsDisposed, "Deferred exit did not close its owner after dispatch.");
            }
            Console.WriteLine("PASS: ItemClicked close preserves the handle; twelve reuse cycles keep click handlers stable; commands refresh; exit defers owner close; disposal releases the menu.");
            return 0;
        } catch (Exception ex) {
            Console.WriteLine("FAIL menu: " + ex.GetBaseException());
            return 1;
        }
    }
    private static object Invoke(ShellForm form, string name) { return typeof(ShellForm).GetMethod(name, Instance).Invoke(form, null); }
    private static void ItemClickedClosed(ContextMenuStrip menu)
    {
        typeof(ToolStripDropDown).GetMethod("OnClosed", Instance).Invoke(menu,
            new object[] { new ToolStripDropDownClosedEventArgs(ToolStripDropDownCloseReason.ItemClicked) });
    }
    private static int[] ClickHandlerCounts(ContextMenuStrip menu)
    {
        object key = typeof(ToolStripItem).GetField("EventClick", BindingFlags.Static | BindingFlags.NonPublic).GetValue(null);
        var result = new int[menu.Items.Count];
        for (int i = 0; i < result.Length; i++) {
            var events = (EventHandlerList)typeof(Component).GetProperty("Events", Instance).GetValue(menu.Items[i], null);
            Delegate handler = events[key];
            result[i] = handler == null ? 0 : handler.GetInvocationList().Length;
        }
        return result;
    }
    private static void Check(bool condition, string message) { if (!condition) throw new Exception("ASSERT: " + message); }
}
