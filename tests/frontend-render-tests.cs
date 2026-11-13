using System;
using System.Drawing;
using System.Reflection;
using System.Windows.Forms;
using ArtemisOS.Frontend;

internal static class FrontendRenderTests
{
    [STAThread]
    private static int Main()
    {
        try { return Run(); }
        catch(Exception ex) { Console.WriteLine("FAIL render: "+ex.Message); if(ex.InnerException!=null)Console.WriteLine(ex.InnerException.Message); return 1; }
    }
    private static int Run()
    {
        Application.EnableVisualStyles();
        Type type = typeof(ShellForm).GetNestedType("ToolButton", BindingFlags.NonPublic);
        foreach (string kind in new[] { "back", "home", "recent", "settings", "minimize", "close" }) {
            using (Control button = (Control)Activator.CreateInstance(type, new object[] { kind }))
            using (Bitmap first = new Bitmap(42, 42))
            using (Bitmap second = new Bitmap(42, 42)) {
                button.Size = new Size(42, 42);
                Paint(type, button, first, Color.Magenta);
                Paint(type, button, second, Color.Lime);
                for (int y = 0; y < 42; y++) for (int x = 0; x < 42; x++)
                    if (first.GetPixel(x,y).ToArgb() != second.GetPixel(x,y).ToArgb())
                        throw new Exception("ASSERT: " + kind + " paint depends on stale buffer contents at " + x + "," + y);
            }
        }
        Console.WriteLine("PASS: six real toolbar/header controls fully repaint independent of stale buffer contents.");
        return 0;
    }
    private static void Paint(Type type, Control control, Bitmap target, Color seed)
    {
        using (Graphics graphics = Graphics.FromImage(target)) {
            graphics.Clear(seed);
            type.GetMethod("OnPaint",BindingFlags.NonPublic|BindingFlags.Instance).Invoke(control,
                new object[] {new PaintEventArgs(graphics,new Rectangle(0,0,42,42))});
        }
    }
}
