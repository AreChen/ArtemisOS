using System;
using System.Collections;
using System.IO;
using System.Reflection;
using System.Threading.Tasks;
using System.Windows.Forms;

internal static class FrontendControlsTests
{
    [STAThread]
    private static int Main(string[] args)
    {
        try {
            Application.EnableVisualStyles();
            Directory.CreateDirectory(args[1]);
            File.WriteAllText(Path.Combine(args[1], "launch.ps1"), "# isolated test installation");
            Assembly product = Assembly.LoadFrom(Path.GetFullPath(args[0]));
            Type optionsType = product.GetType("ArtemisOS.Frontend.FrontendOptions", true);
            object options = optionsType.GetMethod("Parse").Invoke(null, new object[] { new[] { "--root", args[1], "--port", "5554" } });
            Type sessionType = product.GetType("ArtemisOS.Frontend.FrontendSession", true);
            Type shellType = product.GetType("ArtemisOS.Frontend.ShellForm", true);
            using (IDisposable session = (IDisposable)Activator.CreateInstance(sessionType, new[] { options }))
            using (Form shell = (Form)Activator.CreateInstance(shellType, new[] { options })) {
                sessionType.GetField("<Ready>k__BackingField", BindingFlags.NonPublic | BindingFlags.Instance).SetValue(session, true);
                shellType.GetField("session", BindingFlags.NonPublic | BindingFlags.Instance).SetValue(shell, session);
                shellType.GetMethod("UpdateButtons", BindingFlags.NonPublic | BindingFlags.Instance).Invoke(shell, null);
                int disabled = 0;
                Control volume = null;
                foreach (Control item in (IEnumerable)shellType.GetField("tools", BindingFlags.NonPublic | BindingFlags.Instance).GetValue(shell)) {
                    item.EnabledChanged += delegate { if (!item.Enabled) disabled++; };
                    if (item.AccessibleName == "音量 +") volume = item;
                }
                if (volume == null) throw new Exception("Volume button missing.");
                typeof(Button).GetMethod("OnClick", BindingFlags.NonPublic | BindingFlags.Instance).Invoke(volume, new object[] { EventArgs.Empty });
                if (disabled != 0) throw new Exception("Volume click disabled " + disabled + " toolbar controls, causing flicker.");
            }
            Console.WriteLine("PASS: a real volume-button click keeps the toolbar enabled while its command is pending.");
            return 0;
        } catch (Exception ex) {
            Console.WriteLine("FAIL controls: " + ex.GetBaseException().Message);
            return 1;
        }
    }
}
