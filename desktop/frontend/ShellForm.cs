using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace ArtemisOS.Frontend
{
    internal sealed class ShellForm : Form
    {
        private static readonly Color Surface = Color.FromArgb(20, 25, 34);
        private static readonly Color Rail = Color.FromArgb(28, 35, 47);
        private static readonly Color Border = Color.FromArgb(43, 53, 69);
        private static readonly Color Ink = Color.FromArgb(233, 239, 248);
        private static readonly Color Muted = Color.FromArgb(144, 160, 181);
        private static readonly Color Accent = Color.FromArgb(93, 162, 255);
        private readonly FrontendOptions options;
        private readonly List<ToolButton> tools = new List<ToolButton>();
        private readonly ToolTip tips = new ToolTip { InitialDelay = 450, ReshowDelay = 150, AutoPopDelay = 5000 };
        private readonly SemaphoreSlim actions = new SemaphoreSlim(1, 1);
        private readonly ToolButton minimize, close, reconnect;
        private readonly System.Windows.Forms.Timer noticeTimer = new System.Windows.Forms.Timer { Interval = 4500 };
        private readonly System.Windows.Forms.Timer displayChangeTimer = new System.Windows.Forms.Timer { Interval = 1000 };
        private FrontendSession session;
        private FrontendLayout layout;
        private Size videoSize = new Size(720, 1600);
        private IntPtr videoWindow;
        private double scale = 1;
        private bool closing, closeAllowed, busy;
        private bool rotating;
        private int quickPending;
        private string status = "正在启动", detail = "准备 Android 运行环境…", failure, notice, renderer = "独立显示";
        private string version, resources;
        private Image logo;
        private Bitmap headerLogo, loadingLogo;
        private ContextMenuStrip moreMenu;

        public ShellForm(FrontendOptions options)
        {
            this.options = options;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            AutoScaleMode = AutoScaleMode.None;
            BackColor = Surface;
            ForeColor = Ink;
            Font = new Font("Microsoft YaHei UI", 9);
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            KeyPreview = true;
            Text = "ArtemisOS 15";
            var paths = new FrontendPaths(options.Root);
            version = paths.Version;
            Text += " v" + version;
            string icon = Path.Combine(options.Root, "ArtemisOS15.ico");
            if (File.Exists(icon)) {
                Icon = new Icon(icon);
            }
            string brand = Path.Combine(paths.AssetsDir, "scrcpy.png");
            if (File.Exists(brand)) using (var source = Image.FromFile(brand)) logo = new Bitmap(source);
            ReadPreferences();
            minimize = HeaderButton("minimize", "最小化", delegate { WindowState = FormWindowState.Minimized; });
            close = HeaderButton("close", "关闭模拟器", delegate { Close(); });
            AddTool("back", "返回  ·  Esc", () => Key(4));
            AddTool("home", "主屏幕", () => Key(3));
            AddTool("recent", "最近任务", () => Key(187));
            AddTool("volumeup", "音量 +", () => Key(24));
            AddTool("volumedown", "音量 −", () => Key(25));
            AddTool("rotate", "切换横竖屏（手动方向）  ·  Ctrl+R", Rotate);
            AddTool("power", "亮屏 / 息屏", () => Key(26));
            AddTool("screenshot", "截图  ·  Ctrl+S", Screenshot);
            AddTool("install", "安装 APK  ·  Ctrl+I", Install);
            AddTool("import", "导入文件  ·  Ctrl+O", Import);
            AddTool("settings", "配置模拟器", Configure);
            AddTool("more", "更多操作", ShowMore);
            reconnect = new ToolButton("reconnect") { Text = "重新连接", Visible = false, TabStop = true, AccessibleName = "重新连接画面" };
            reconnect.Click += async delegate { await RunAction(async delegate { failure = null; await session.ReconnectAsync(); }); };
            Controls.Add(reconnect);
            noticeTimer.Tick += delegate { noticeTimer.Stop(); notice = null; InvalidateFooter(); };
            displayChangeTimer.Tick += async delegate {
                displayChangeTimer.Stop();
                if (closing || session == null || session.Updating) return;
                scale = NativeDisplay.Scale(Handle);
                FitWindowToVideo(false);
                UpdateLayout();
                if (session.Ready) await session.RecoverDisplayAsync("Windows 显示器、分辨率或 DPI 已改变。");
            };
            Shown += async delegate {
                scale = NativeDisplay.Scale(Handle);
                var area = Screen.FromPoint(Cursor.Position).WorkingArea;
                FitWindowToVideo(true);
                Location = new Point(area.Left + (area.Width - Width) / 2, area.Top + (area.Height - Height) / 2);
                NativeDisplay.StyleShell(Handle);
                UpdateLayout();
                await StartSession();
            };
        }

        private ToolButton HeaderButton(string kind, string hint, Action action)
        {
            var button = new ToolButton(kind) { AccessibleName = hint, TabStop = false };
            tips.SetToolTip(button, hint);
            button.Click += delegate { action(); };
            Controls.Add(button);
            return button;
        }

        private void AddTool(string kind, string hint, Func<Task> action)
        {
            var button = new ToolButton(kind) { AccessibleName = hint, TabStop = true };
            tips.SetToolTip(button, hint);
            button.Click += async delegate {
                if (session != null) session.Log("UI action: " + kind);
                if (IsQuickControl(kind)) await RunQuickAction(action);
                else await RunAction(action);
            };
            tools.Add(button);
            Controls.Add(button);
        }

        private async Task StartSession()
        {
            var current = new FrontendSession(options);
            session = current;
            current.StatusChanged += (title, message) => UI(delegate {
                if (session != current || closing) return;
                status = title; detail = message;
                if (title == "已连接") {
                    failure = null;
                    string actual = message.ToLowerInvariant();
                    string api = actual.Contains("vulkan") ? "Vulkan" : "OpenGL";
                    if (actual.Contains("swiftshader") || actual.Contains("llvmpipe") || actual.Contains("lavapipe")) renderer = "CPU · 软件渲染";
                    else if (actual.Contains("nvidia")) renderer = "NVIDIA · " + api;
                    else if (actual.Contains("intel")) renderer = "Intel · " + api;
                    else if (actual.Contains("amd") || actual.Contains("radeon")) renderer = "AMD · " + api;
                }
                UpdateButtons(); Invalidate();
            });
            current.VideoSizeChanged += size => UI(delegate {
                if (session != current || closing) return;
                bool aspectChanged = Math.Abs(videoSize.Width / (double)videoSize.Height - size.Width / (double)size.Height) > 0.005;
                videoSize = size;
                if (aspectChanged) FitWindowToVideo(false);
                UpdateLayout();
            });
            current.ViewerReady += (window, pid) => UI(delegate {
                if (session != current || closing) return;
                try {
                    NativeDisplay.Own(window, pid, Handle);
                    videoWindow = window;
                    failure = null;
                    reconnect.Visible = false;
                    UpdateLayout();
                    if (current.ViewerShouldActivate) NativeDisplay.SetForegroundWindow(window);
                } catch (Exception ex) { failure = ex.Message; current.Log(ex.ToString()); Invalidate(); }
            });
            current.ViewerDisconnected += message => UI(delegate {
                if (session != current || closing || current.Updating) return;
                if (videoWindow != IntPtr.Zero) NativeDisplay.ShowWindow(videoWindow, 0);
                videoWindow = IntPtr.Zero;
                status = "连接已中断";
                detail = message;
                failure = message;
                reconnect.Visible = true;
                UpdateLayout(); UpdateButtons(); Invalidate();
            });
            current.CloseRequested += () => UI(delegate { if (session == current) Close(); });
            UpdateButtons();
            await current.StartAsync();
        }

        private async Task RunAction(Func<Task> action)
        {
            if (closing || !await actions.WaitAsync(0)) return;
            busy = true;
            UpdateButtons();
            try { await action(); }
            catch (Exception ex) {
                if (closing || (session != null && session.Updating)) return;
                if (session != null) session.Log("Action: " + ex);
                MessageBox.Show(this, ex.Message, "ArtemisOS", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            } finally {
                busy = false;
                actions.Release();
                if (!IsDisposed) UpdateButtons();
            }
        }

        private static bool IsQuickControl(string kind)
        {
            return kind == "back" || kind == "home" || kind == "recent" || kind == "volumeup" ||
                kind == "volumedown" || kind == "rotate" || kind == "power";
        }

        private async Task RunQuickAction(Func<Task> action)
        {
            if (closing || session == null || !session.Ready || quickPending >= 16) return;
            var current = session;
            quickPending++;
            try { await action(); }
            catch (Exception ex) {
                if (closing || current != session || current.Updating) return;
                current.Log("Quick action: " + ex);
                Notify("操作未完成：" + ex.Message);
            } finally { quickPending--; }
        }

        private async Task Key(int key)
        {
            await EnsureDevice();
            Check(await session.Device.KeyAsync(key));
        }

        private async Task Rotate()
        {
            if (rotating) return;
            rotating = true;
            try {
                await EnsureDevice();
                Check(await session.Device.RotateAsync());
                Notify("已切换横竖屏；“更多”中可恢复应用方向控制");
            } finally { rotating = false; }
        }

        private async Task RestoreRotation()
        {
            await EnsureDevice();
            Check(await session.Device.RestoreRotationAsync());
            Notify("已恢复应用方向控制");
        }

        private async Task Screenshot()
        {
            await EnsureDevice();
            string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "ArtemisOS");
            Directory.CreateDirectory(folder);
            string path = Path.Combine(folder, "ArtemisOS-" + DateTime.Now.ToString("yyyyMMdd-HHmmss-fff") + ".png");
            Check(await session.Device.ScreenshotAsync(path));
            Notify("截图已保存到“图片 / ArtemisOS”");
        }

        private async Task Install()
        {
            await EnsureDevice();
            using (var picker = new OpenFileDialog { Title = "选择要安装的 APK", Filter = "Android 应用 (*.apk)|*.apk", CheckFileExists = true, Multiselect = false }) {
                if (picker.ShowDialog(this) != DialogResult.OK) return;
                await EnsureDevice();
                Notify("正在安装 " + Path.GetFileName(picker.FileName) + "…", false);
                Check(await session.Device.InstallAsync(picker.FileName));
                Notify("应用安装完成");
            }
        }

        private async Task Import()
        {
            await EnsureDevice();
            using (var picker = new OpenFileDialog { Title = "导入到 Android 的 Download 文件夹", Filter = "所有文件 (*.*)|*.*", CheckFileExists = true, Multiselect = true }) {
                if (picker.ShowDialog(this) != DialogResult.OK) return;
                int count = 0;
                foreach (string path in picker.FileNames) {
                    await EnsureDevice();
                    Notify("正在导入 " + Path.GetFileName(path) + "…", false);
                    Check(await session.Device.ImportAsync(path));
                    count++;
                }
                Notify("已导入 " + count + " 个文件到 Download");
            }
        }

        private async Task Configure()
        {
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
            var result = await Task.Run(() => ProcessRunner.Run(powershell,
                new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", session.Paths.ConfigureScript }, 86400000));
            Check(result);
            ReadPreferences();
            Invalidate();
            Notify("配置已关闭；更改配置后，请重启模拟器生效");
        }

        private ContextMenuStrip CreateMoreMenu()
        {
            var menu = new ContextMenuStrip { BackColor = Rail, ForeColor = Ink, ShowImageMargin = false, Font = Font };
            menu.Renderer = new ToolStripProfessionalRenderer(new DarkMenuColors());
            var reconnectItem = menu.Items.Add("重新连接画面");
            reconnectItem.Name = "reconnect";
            reconnectItem.Click += async delegate { await RunAction(() => session.ReconnectAsync()); };
            var restart = menu.Items.Add("重启模拟器");
            restart.Name = "restart";
            restart.Click += async delegate { await RunAction(Restart); };
            var autoRotation = menu.Items.Add("恢复应用方向控制");
            autoRotation.Name = "restoreRotation";
            autoRotation.Click += async delegate { await RunQuickAction(RestoreRotation); };
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("打开截图文件夹").Click += delegate {
                string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "ArtemisOS");
                Directory.CreateDirectory(path); OpenFolder(path);
            };
            menu.Items.Add("打开运行日志").Click += delegate { OpenFolder(session.Paths.LogsDir); };
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("退出 ArtemisOS").Click += delegate {
                // WinForms still reparents the dropdown after ItemClicked.
                // Complete that dispatch before closing its owning form.
                if (!IsDisposed && IsHandleCreated) BeginInvoke((Action)Close);
            };
            return menu;
        }

        private ContextMenuStrip PrepareMoreMenu()
        {
            if (moreMenu == null) moreMenu = CreateMoreMenu();
            bool available = session != null && !closing && !session.Updating;
            moreMenu.Items["reconnect"].Enabled = available;
            moreMenu.Items["restart"].Enabled = available && options.AttachSerial == null;
            moreMenu.Items["restoreRotation"].Enabled = available && session.Ready;
            return moreMenu;
        }

        private Task ShowMore()
        {
            var menu = PrepareMoreMenu();
            var anchor = tools[tools.Count - 1];
            menu.Show(anchor, new Point(-200, anchor.Height), ToolStripDropDownDirection.AboveRight);
            return Task.FromResult(0);
        }

        private static void OpenFolder(string path)
        {
            var info = new ProcessStartInfo("explorer.exe", CommandLine.Quote(path)) { UseShellExecute = false };
            Process.Start(info);
        }

        private async Task Restart()
        {
            var previous = session;
            videoWindow = IntPtr.Zero;
            reconnect.Visible = false;
            failure = null;
            status = "正在重启"; detail = "正在保存状态并关闭 Android…"; Invalidate();
            await previous.StopAsync();
            previous.Dispose();
            if (closing) return;
            await StartSession();
        }

        private Task EnsureDevice()
        {
            if (session == null || !session.Ready) throw new InvalidOperationException("请等待 Android 连接完成。");
            return session.ValidateDeviceAsync();
        }

        private static void Check(CommandResult result)
        {
            if (!result.Success) throw new IOException(result.TimedOut ? "操作超时，请检查 Android 是否仍在响应。" :
                String.IsNullOrWhiteSpace(result.Error) ? "操作未完成：" + result.Output : result.Error);
        }

        private void Notify(string text, bool timed = true)
        {
            notice = text;
            noticeTimer.Stop();
            if (timed) noticeTimer.Start();
            InvalidateFooter();
        }

        private void UpdateButtons()
        {
            bool ready = session != null && session.Ready && !closing;
            foreach (var tool in tools)
                tool.Enabled = tool.Kind == "settings" || tool.Kind == "more" ? !closing && !busy : ready && (IsQuickControl(tool.Kind) || !busy);
            reconnect.Enabled = !closing && !busy;
        }

        private void UI(Action action)
        {
            if (IsDisposed || Disposing || !IsHandleCreated) return;
            try { if (InvokeRequired) BeginInvoke(action); else action(); }
            catch (InvalidOperationException) { }
        }

        private void ReadPreferences()
        {
            var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            string file = Path.Combine(options.Root, "data", "preferences.ini");
            if (File.Exists(file)) foreach (string line in File.ReadAllLines(file)) {
                int split = line.IndexOf('=');
                if (split > 0) values[line.Substring(0, split).Trim()] = line.Substring(split + 1).Trim();
            }
            string profile = values.ContainsKey("profile") ? values["profile"] : "medium";
            resources = profile == "high" ? "6 核 / 8 GB" : profile == "low" ? "2 核 / 2.5 GB" : "4 核 / 4 GB";
            string graphics = values.ContainsKey("graphics") ? values["graphics"] : "host";
            renderer = options.Graphics == "swiftshader" || graphics == "software" || graphics == "swangle" || graphics == "swiftshader" || graphics == "lavapipe"
                ? "CPU · 软件渲染" : graphics == "vulkan_intel" ? "Intel · Vulkan" : graphics == "vulkan" ? "GPU · Vulkan" : "硬件加速";
            string resolution = values.ContainsKey("resolution") ? values["resolution"] : "720p";
            switch (resolution) {
                case "900p": videoSize = new Size(900, 2000); break;
                case "1080p": videoSize = new Size(1080, 2400); break;
                case "720x1280": videoSize = new Size(720, 1280); break;
                case "1080x1920": videoSize = new Size(1080, 1920); break;
                case "1280x720": videoSize = new Size(1280, 720); break;
                case "1920x1080": videoSize = new Size(1920, 1080); break;
                default: videoSize = new Size(720, 1600); break;
            }
        }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            if (tools == null || close == null) return;
            UpdateLayout();
        }

        protected override void OnMove(EventArgs e)
        {
            base.OnMove(e);
            PlaceVideo();
        }

        private void UpdateLayout()
        {
            if (ClientSize.Width < 100 || ClientSize.Height < 100) return;
            UpdateLogoCache();
            layout = FrontendLayout.Calculate(ClientSize, scale, videoSize);
            int h = (int)(32 * scale), w = (int)(34 * scale), p = (int)(12 * scale);
            close.Bounds = new Rectangle(ClientSize.Width - p - w, p, w, h);
            minimize.Bounds = new Rectangle(close.Left - w - (int)(2 * scale), p, w, h);
            int item = Math.Min((int)(42 * scale), (layout.Toolbar.Height - (int)(32 * scale)) / tools.Count);
            int y = layout.Toolbar.Top + (int)(4 * scale);
            for (int i = 0; i < tools.Count; i++) {
                if (i == 3 || i == 7) y += (int)(8 * scale);
                if (i == 10) y = Math.Max(y + (int)(8 * scale), layout.Toolbar.Bottom - 2 * item - (int)(6 * scale));
                tools[i].Bounds = new Rectangle(layout.Toolbar.Left + (int)(5 * scale), y, layout.Toolbar.Width - (int)(10 * scale), item);
                y += item;
            }
            reconnect.Bounds = new Rectangle(layout.Video.Left + Math.Max(0, (layout.Video.Width - (int)(142 * scale)) / 2),
                layout.Video.Top + layout.Video.Height / 2 + (int)(70 * scale), (int)(142 * scale), (int)(40 * scale));
            PlaceVideo();
            Invalidate();
        }

        private void UpdateLogoCache()
        {
            if (logo == null) return;
            int size = Math.Max(1, (int)Math.Round(34 * scale));
            if (headerLogo != null && headerLogo.Width == size) return;
            if (headerLogo != null) headerLogo.Dispose();
            if (loadingLogo != null) loadingLogo.Dispose();
            headerLogo = ResizeLogo(logo, size);
            loadingLogo = ResizeLogo(logo, Math.Max(1, (int)Math.Round(52 * scale)));
        }

        private static Bitmap ResizeLogo(Image source, int size)
        {
            var result = new Bitmap(size, size, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
            using (Graphics graphics = Graphics.FromImage(result))
            using (var attributes = new System.Drawing.Imaging.ImageAttributes()) {
                graphics.CompositingMode = CompositingMode.SourceCopy;
                graphics.CompositingQuality = CompositingQuality.HighQuality;
                graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                attributes.SetWrapMode(WrapMode.TileFlipXY);
                graphics.DrawImage(source, new Rectangle(0,0,size,size), 0,0,source.Width,source.Height,GraphicsUnit.Pixel,attributes);
            }
            return result;
        }

        private void FitWindowToVideo(bool initial)
        {
            var area = Screen.FromRectangle(Bounds).WorkingArea;
            int longest = initial || layout == null ? (int)(800 * scale) : Math.Max(layout.Video.Width, layout.Video.Height);
            Size requested = FrontendLayout.WindowForVideo(videoSize, longest, scale);
            while ((requested.Width > area.Width - 40 || requested.Height > area.Height - 40) && longest > 240 * scale) {
                longest -= Math.Max(1, (int)(10 * scale));
                requested = FrontendLayout.WindowForVideo(videoSize, longest, scale);
            }
            int minWidth = Math.Min((int)(320 * scale), requested.Width);
            int minHeight = Math.Min((int)(430 * scale), requested.Height);
            MinimumSize = new Size(minWidth, minHeight);
            Size = requested;
            if (!initial) {
                Left = Math.Max(area.Left, Math.Min(Left, area.Right - Width));
                Top = Math.Max(area.Top, Math.Min(Top, area.Bottom - Height));
            }
        }

        private void PlaceVideo()
        {
            if (layout == null || videoWindow == IntPtr.Zero || !IsHandleCreated || WindowState == FormWindowState.Minimized) return;
            NativeDisplay.Position(videoWindow, RectangleToScreen(layout.Video));
        }

        protected override async void OnFormClosing(FormClosingEventArgs e)
        {
            if (closeAllowed || session == null) { base.OnFormClosing(e); return; }
            e.Cancel = true;
            if (closing) return;
            closing = true;
            videoWindow = IntPtr.Zero;
            UpdateButtons();
            try {
                await session.StopAsync();
                closeAllowed = true;
                Close();
            } catch (Exception ex) {
                closing = false;
                status = "关闭未完成"; detail = failure = ex.Message;
                UpdateButtons(); Invalidate();
                MessageBox.Show(this, ex.Message + "\n\n前端保留打开，以免遗留无法确认归属的后台进程。日志中有详细信息。", "ArtemisOS", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        protected override void WndProc(ref Message m)
        {
            const int WM_NCHITTEST = 0x84, WM_DPICHANGED = 0x2E0, WM_SIZING = 0x214, WM_DISPLAYCHANGE = 0x7E;
            if (m.Msg == WM_SIZING && videoSize.Width > 0 && videoSize.Height > 0) {
                var bounds = (NativeDisplay.NativeRect)Marshal.PtrToStructure(m.LParam, typeof(NativeDisplay.NativeRect));
                int pad = (int)Math.Round(14 * scale);
                int chromeW = (int)Math.Round(52 * scale) + pad * 3;
                int chromeH = (int)Math.Round(65 * scale) + (int)Math.Round(35 * scale) + pad * 2;
                double ratio = videoSize.Width / (double)videoSize.Height;
                int edge = m.WParam.ToInt32();
                if (edge == 3 || edge == 6) {
                    bounds.Right = bounds.Left + (int)Math.Round(Math.Max(1, bounds.Bottom - bounds.Top - chromeH) * ratio) + chromeW;
                } else {
                    int height = (int)Math.Round(Math.Max(1, bounds.Right - bounds.Left - chromeW) / ratio) + chromeH;
                    if (edge == 4 || edge == 5) bounds.Top = bounds.Bottom - height;
                    else bounds.Bottom = bounds.Top + height;
                }
                Marshal.StructureToPtr(bounds, m.LParam, false);
                m.Result = new IntPtr(1);
                return;
            }
            if (m.Msg == WM_DPICHANGED) {
                scale = (m.WParam.ToInt64() & 0xffff) / 96.0;
                var bounds = (NativeDisplay.NativeRect)Marshal.PtrToStructure(m.LParam, typeof(NativeDisplay.NativeRect));
                SetBounds(bounds.Left, bounds.Top, bounds.Right - bounds.Left, bounds.Bottom - bounds.Top);
                UpdateLayout();
                QueueDisplayChange();
                m.Result = IntPtr.Zero;
                return;
            }
            base.WndProc(ref m);
            if (m.Msg == WM_DISPLAYCHANGE) QueueDisplayChange();
            if (m.Msg == WM_NCHITTEST && m.Result.ToInt32() == 1) {
                long point = m.LParam.ToInt64();
                var local = PointToClient(new Point((short)(point & 0xffff), (short)((point >> 16) & 0xffff)));
                int edge = (int)(6 * scale);
                bool left = local.X < edge, right = local.X >= ClientSize.Width - edge;
                bool top = local.Y < edge, bottom = local.Y >= ClientSize.Height - edge;
                int hit = top && left ? 13 : top && right ? 14 : bottom && left ? 16 : bottom && right ? 17 :
                    left ? 10 : right ? 11 : top ? 12 : bottom ? 15 : local.Y < (int)(64 * scale) ? 2 : 1;
                m.Result = new IntPtr(hit);
            }
        }

        private void QueueDisplayChange()
        {
            if (closing || IsDisposed || Disposing) return;
            displayChangeTimer.Stop();
            displayChangeTimer.Start();
        }

        protected override async void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);
            Func<Task> action = null;
            if (e.KeyCode == Keys.Escape) action = () => Key(4);
            if (e.Control && e.KeyCode == Keys.S) action = Screenshot;
            if (e.Control && e.KeyCode == Keys.R) action = Rotate;
            if (e.Control && e.KeyCode == Keys.I) action = Install;
            if (e.Control && e.KeyCode == Keys.O) action = Import;
            if (action != null && session != null && session.Ready) {
                e.Handled = true; e.SuppressKeyPress = true;
                if (e.KeyCode == Keys.Escape || e.KeyCode == Keys.R) await RunQuickAction(action);
                else await RunAction(action);
            }
        }

        private void InvalidateFooter() { if (layout != null) Invalidate(layout.Footer); }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            if (layout == null) return;
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float s = (float)scale;
            using (var pen = new Pen(Border)) g.DrawRectangle(pen, 0, 0, ClientSize.Width - 1, ClientSize.Height - 1);
            using (var line = new Pen(Color.FromArgb(34, 43, 57))) {
                g.DrawLine(line, 14*s, layout.Header.Bottom, ClientSize.Width-14*s, layout.Header.Bottom);
                g.DrawLine(line, 14*s, layout.Footer.Top, ClientSize.Width-14*s, layout.Footer.Top);
            }
            if (headerLogo != null) g.DrawImageUnscaled(headerLogo, (int)Math.Round(18*s), (int)Math.Round(15*s));
            else using (var brand = new SolidBrush(Accent)) g.FillEllipse(brand, 20*s, 18*s, 28*s, 28*s);
            using (var title = new Font("Segoe UI", 16*s, FontStyle.Bold, GraphicsUnit.Pixel))
                TextRenderer.DrawText(g, "ArtemisOS", title, new Rectangle((int)(63*s),(int)(13*s),(int)(160*s),(int)(23*s)), Ink, TextFormatFlags.NoPadding);
            using (var subtitle = new Font("Segoe UI", 10*s, FontStyle.Regular, GraphicsUnit.Pixel))
                TextRenderer.DrawText(g, "ANDROID 15   /   v" + version, subtitle, new Rectangle((int)(64*s),(int)(38*s),(int)(230*s),(int)(17*s)), Muted, TextFormatFlags.NoPadding);
            using (var path = Rounded(layout.Toolbar, (int)(14*s))) {
                using (var brush = new SolidBrush(Rail)) g.FillPath(brush,path);
                using (var pen = new Pen(Border)) g.DrawPath(pen,path);
            }
            using (var black = new SolidBrush(Color.FromArgb(8,12,18))) g.FillRectangle(black,layout.Video);
            if (videoWindow == IntPtr.Zero) PaintPlaceholder(g,s);
            string footer = notice ?? (closing ? "正在关闭 Android…" : status + "  ·  " + renderer);
            using (var text = new Font("Microsoft YaHei UI", 10*s, FontStyle.Regular, GraphicsUnit.Pixel)) {
                using (var dot = new SolidBrush(failure != null ? Color.FromArgb(246,165,110) : session != null && session.Ready ? Color.FromArgb(89,206,159) : Accent))
                    g.FillEllipse(dot,18*s,layout.Footer.Top+15*s,5*s,5*s);
                string right = options.Port + "  ·  " + resources;
                int rightWidth = TextRenderer.MeasureText(right,text).Width;
                TextRenderer.DrawText(g,footer,text,new Rectangle((int)(32*s),layout.Footer.Top+(int)(10*s),Math.Max(1,ClientSize.Width-rightWidth-(int)(52*s)),(int)(20*s)),notice != null ? Accent : Muted,TextFormatFlags.EndEllipsis|TextFormatFlags.NoPadding);
                TextRenderer.DrawText(g,right,text,new Rectangle(ClientSize.Width-rightWidth-(int)(15*s),layout.Footer.Top+(int)(10*s),rightWidth,(int)(20*s)),Muted,TextFormatFlags.NoPadding);
            }
        }

        private void PaintPlaceholder(Graphics g,float s)
        {
            var r = layout.Video;
            int cy = r.Top+r.Height/2;
            if (loadingLogo != null) {
                g.DrawImageUnscaled(loadingLogo,r.Left+(r.Width-loadingLogo.Width)/2,cy-(int)(94*s));
            }
            using(var font = new Font("Microsoft YaHei UI",14*s,FontStyle.Regular,GraphicsUnit.Pixel))
                TextRenderer.DrawText(g,failure == null ? status : "画面暂不可用",font,new Rectangle(r.Left,cy-(int)(25*s),r.Width,(int)(28*s)),Ink,TextFormatFlags.HorizontalCenter|TextFormatFlags.NoPadding);
            using(var font = new Font("Microsoft YaHei UI",10*s,FontStyle.Regular,GraphicsUnit.Pixel))
                TextRenderer.DrawText(g,failure ?? detail,font,new Rectangle(r.Left+(int)(16*s),cy+(int)(12*s),Math.Max(1,r.Width-(int)(32*s)),(int)(55*s)),Muted,TextFormatFlags.HorizontalCenter|TextFormatFlags.WordBreak|TextFormatFlags.EndEllipsis|TextFormatFlags.NoPadding);
        }

        private static GraphicsPath Rounded(Rectangle r, int radius)
        {
            var path = new GraphicsPath();
            int d = Math.Max(2,Math.Min(radius*2,Math.Min(r.Width,r.Height)));
            path.AddArc(r.Left,r.Top,d,d,180,90); path.AddArc(r.Right-d,r.Top,d,d,270,90);
            path.AddArc(r.Right-d,r.Bottom-d,d,d,0,90); path.AddArc(r.Left,r.Bottom-d,d,d,90,90); path.CloseFigure();
            return path;
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) {
                noticeTimer.Dispose(); tips.Dispose();
                displayChangeTimer.Dispose();
                if(moreMenu != null) moreMenu.Dispose();
                if(session != null) session.Dispose();
                if(logo != null) logo.Dispose();
                if(headerLogo != null) headerLogo.Dispose();
                if(loadingLogo != null) loadingLogo.Dispose();
            }
            base.Dispose(disposing);
        }

        private sealed class DarkMenuColors : ProfessionalColorTable
        {
            public override Color ToolStripDropDownBackground { get { return Rail; } }
            public override Color MenuItemSelected { get { return Color.FromArgb(44,58,78); } }
            public override Color MenuItemBorder { get { return Border; } }
            public override Color MenuBorder { get { return Border; } }
            public override Color SeparatorDark { get { return Border; } }
            public override Color SeparatorLight { get { return Rail; } }
        }

        private sealed class ToolButton : Button
        {
            public readonly string Kind;
            private bool hovered, pressed;
            public ToolButton(string kind)
            {
                Kind=kind;
                FlatStyle=FlatStyle.Flat; FlatAppearance.BorderSize=0; UseVisualStyleBackColor=false;
                SetStyle(ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer|ControlStyles.UserPaint|ControlStyles.Selectable|ControlStyles.SupportsTransparentBackColor,true);
                BackColor=Color.Transparent; Cursor=Cursors.Hand; AccessibleRole=AccessibleRole.PushButton;
            }
            protected override void OnMouseEnter(EventArgs e) { hovered=true; Invalidate(); base.OnMouseEnter(e); }
            protected override void OnMouseLeave(EventArgs e) { hovered=pressed=false; Invalidate(); base.OnMouseLeave(e); }
            protected override void OnMouseDown(MouseEventArgs e) { if(e.Button==MouseButtons.Left) pressed=true; Invalidate(); base.OnMouseDown(e); }
            protected override void OnMouseUp(MouseEventArgs e) { pressed=false; Invalidate(); base.OnMouseUp(e); }
            protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
            protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
            protected override void OnPaint(PaintEventArgs e)
            {
                var g=e.Graphics;
                g.Clear(Kind=="minimize"||Kind=="close" ? Surface : Kind=="reconnect" ? Color.FromArgb(8,12,18) : Rail);
                g.SmoothingMode=SmoothingMode.AntiAlias;
                if((hovered||Kind=="reconnect")&&Enabled) {
                    using(var path=Rounded(new Rectangle(1,1,Width-3,Height-3),8))
                    using(var brush=new SolidBrush(Kind=="close"&&hovered?Color.FromArgb(150,55,67):pressed?Color.FromArgb(48,72,104):Color.FromArgb(39,54,76))) g.FillPath(brush,path);
                }
                Color color=!Enabled?Color.FromArgb(70,83,101):hovered?Accent:Color.FromArgb(179,194,214);
                if(Focused&&ShowFocusCues&&TabStop) ControlPaint.DrawFocusRectangle(g,new Rectangle(3,3,Width-6,Height-6),Muted,Rail);
                if(Kind=="reconnect") {
                    using(var font=new Font("Microsoft YaHei UI",9)) TextRenderer.DrawText(g,Text,font,ClientRectangle,Ink,TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter);
                    return;
                }
                float unit=Math.Min(Width,Height)/42f;
                var state=g.Save();
                g.TranslateTransform(Width/2f-12*unit,Height/2f-12*unit); g.ScaleTransform(unit,unit);
                using(var pen=new Pen(color,1.65f) {StartCap=LineCap.Round,EndCap=LineCap.Round,LineJoin=LineJoin.Round}) {
                    switch(Kind) {
                        case "back": g.DrawLines(pen,new[]{new Point(14,5),new Point(7,12),new Point(14,19)}); break;
                        case "home": g.DrawEllipse(pen,5,5,14,14); break;
                        case "recent": g.DrawRectangle(pen,5,5,14,14); break;
                        case "volumeup": case "volumedown":
                            g.DrawPolygon(pen,new[]{new Point(4,9),new Point(8,9),new Point(13,5),new Point(13,19),new Point(8,15),new Point(4,15)});
                            g.DrawLine(pen,17,12,23,12); if(Kind=="volumeup")g.DrawLine(pen,20,9,20,15); break;
                        case "rotate":
                            g.DrawRectangle(pen,8,6,8,12); g.DrawArc(pen,2,2,20,20,205,95); g.DrawLines(pen,new[]{new Point(15,2),new Point(19,3),new Point(18,7)});
                            g.DrawArc(pen,2,2,20,20,25,95); g.DrawLines(pen,new[]{new Point(9,22),new Point(5,21),new Point(6,17)}); break;
                        case "power":g.DrawArc(pen,4,4,16,16,-48,276);g.DrawLine(pen,12,2,12,11);break;
                        case "screenshot":
                            g.DrawLines(pen,new[]{new Point(3,18),new Point(3,7),new Point(7,7),new Point(9,4),new Point(15,4),new Point(17,7),new Point(21,7),new Point(21,18),new Point(3,18)});g.DrawEllipse(pen,8,8,8,8);break;
                        case "install":g.DrawLines(pen,new[]{new Point(4,10),new Point(4,20),new Point(20,20),new Point(20,10)});g.DrawLine(pen,12,2,12,14);g.DrawLines(pen,new[]{new Point(8,10),new Point(12,14),new Point(16,10)});break;
                        case "import":g.DrawLines(pen,new[]{new Point(3,18),new Point(3,5),new Point(9,5),new Point(11,8),new Point(21,8),new Point(21,18),new Point(3,18)});g.DrawLine(pen,12,11,12,16);g.DrawLine(pen,9,13.5f,15,13.5f);break;
                        case "settings":g.DrawEllipse(pen,5,5,14,14);g.DrawEllipse(pen,9,9,6,6);for(int i=0;i<8;i++){double a=i*Math.PI/4;g.DrawLine(pen,12+(float)Math.Cos(a)*7,12+(float)Math.Sin(a)*7,12+(float)Math.Cos(a)*10,12+(float)Math.Sin(a)*10);}break;
                        case "more":using(var brush=new SolidBrush(color))for(int i=0;i<3;i++)g.FillEllipse(brush,5+i*6,11,2.5f,2.5f);break;
                        case "minimize":g.DrawLine(pen,7,13,17,13);break;
                        case "close":g.DrawLine(pen,7,7,17,17);g.DrawLine(pen,17,7,7,17);break;
                    }
                }
                g.Restore(state);
            }
        }
    }
}
