using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using OpenSwitcher.Core;

namespace OpenSwitcher.UI
{
    /// <summary>Трей: иконка, меню, открытие настроек.</summary>
    public class TrayService : IDisposable
    {
        private readonly Engine _engine;
        private NotifyIcon _icon;
        private SettingsForm _form;

        public TrayService(Engine engine)
        {
            _engine = engine;
        }

        public void Init()
        {
            _icon = new NotifyIcon();
            _icon.Icon = MakeIcon();
            _icon.Text = "OpenSwitcher";
            _icon.Visible = true;
            _icon.ContextMenuStrip = BuildMenu();
            _icon.MouseClick += delegate(object s, MouseEventArgs e)
            {
                if (e.Button == MouseButtons.Left) ShowSettings();
            };
            UpdateTooltip();
            _engine.SettingsApplied += UpdateTooltip;
            _engine.Converted += delegate(string o, string n)
            {
                if (_engine.S.ShowPopup) ConvertPopup.Show(_engine.CaretPoint(), o, n);
            };
            _engine.Info += delegate(string msg)
            {
                if (_engine.S.ShowPopup) ConvertPopup.Show(_engine.CaretPoint(), msg, "");
            };
        }

        public void UpdateTooltip()
        {
            _icon.Text = "OpenSwitcher — " + (_engine.S.Paused ? "пауза" : "Ru ⇄ En");
        }

        private ContextMenuStrip BuildMenu()
        {
            var menu = new ContextMenuStrip();
            menu.Renderer = new DarkMenuRenderer();
            menu.BackColor = UiTheme.Card;
            menu.ShowImageMargin = false;
            menu.Font = UiTheme.Font(10f, false);

            var miSettings = new ToolStripMenuItem("Настройки");
            miSettings.Font = UiTheme.Font(10f, true);
            miSettings.Click += delegate { ShowSettings(); };

            var miPause = new ToolStripMenuItem("Пауза");
            miPause.Click += delegate
            {
                _engine.S.Paused = !_engine.S.Paused;
                SettingsStore.Save(_engine.S);
                UpdateTooltip();
                RefreshMenu();
            };

            var miExit = new ToolStripMenuItem("Выход");
            miExit.Click += delegate
            {
                _icon.Visible = false;
                Application.Exit();
            };

            menu.Items.Add(miSettings);
            menu.Items.Add(miPause);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(miExit);
            menu.Opening += delegate { RefreshMenu(); };
            TagMenu(menu, miPause);
            return menu;
        }

        private ToolStripMenuItem _miPause;

        private void TagMenu(ContextMenuStrip menu, ToolStripMenuItem miPause)
        {
            _miPause = miPause;
        }

        private void RefreshMenu()
        {
            if (_miPause != null)
                _miPause.Text = _engine.S.Paused ? "Продолжить" : "Пауза";
        }

        public void ShowSettings()
        {
            if (_form != null && !_form.IsDisposed)
            {
                _form.Activate();
                return;
            }
            _form = new SettingsForm(_engine);
            _form.Show();
            _form.Activate();
        }

        private static Icon MakeIcon()
        {
            try
            {
                using (var bmp = new Bitmap(32, 32))
                {
                    using (var g = Graphics.FromImage(bmp))
                    {
                        g.SmoothingMode = SmoothingMode.AntiAlias;
                        using (var path = UiTheme.RoundRect(new Rectangle(1, 1, 30, 30), 9))
                        using (var brush = new LinearGradientBrush(new Rectangle(0, 0, 32, 32),
                            UiTheme.Accent, Color.FromArgb(0x7C, 0x5C, 0xFF), 70f))
                            g.FillPath(brush, path);
                        using (var pen = new Pen(Color.White, 2.6f))
                        {
                            pen.StartCap = LineCap.Round;
                            pen.EndCap = LineCap.Round;
                            g.DrawLine(pen, 8, 12, 22, 12);
                            g.DrawLine(pen, 22, 12, 18, 8);
                            g.DrawLine(pen, 22, 12, 18, 16);
                            g.DrawLine(pen, 24, 21, 10, 21);
                            g.DrawLine(pen, 10, 21, 14, 17);
                            g.DrawLine(pen, 10, 21, 14, 25);
                        }
                    }
                    return Icon.FromHandle(bmp.GetHicon());
                }
            }
            catch (Exception)
            {
                return SystemIcons.Application;
            }
        }

        public void Dispose()
        {
            if (_icon != null) _icon.Dispose();
        }
    }

    /// <summary>Тёмный рендерер меню трея.</summary>
    public class DarkMenuRenderer : ToolStripProfessionalRenderer
    {
        public DarkMenuRenderer() : base(new DarkMenuColors()) { }

        protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
        {
            if (e.Item.Selected)
            {
                var r = new Rectangle(2, 1, e.Item.Width - 4, e.Item.Height - 2);
                using (var p = UiTheme.RoundRect(r, 6))
                using (var b = new SolidBrush(UiTheme.RowHover))
                    e.Graphics.FillPath(b, p);
            }
        }
    }

    public class DarkMenuColors : ProfessionalColorTable
    {
        public override Color ToolStripDropDownBackground { get { return UiTheme.Card; } }
        public override Color ImageMarginGradientBegin { get { return UiTheme.Card; } }
        public override Color ImageMarginGradientMiddle { get { return UiTheme.Card; } }
        public override Color ImageMarginGradientEnd { get { return UiTheme.Card; } }
        public override Color MenuBorder { get { return UiTheme.CardBorder; } }
        public override Color MenuItemBorder { get { return Color.Transparent; } }
        public override Color SeparatorDark { get { return UiTheme.CardBorder; } }
        public override Color SeparatorLight { get { return UiTheme.CardBorder; } }
    }
}
