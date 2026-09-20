using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace OpenSwitcher.UI
{
    /// <summary>Небольшая неберущая-фокус подсказка возле каретки: «ghbdtn → привет».</summary>
    public class ConvertPopup : Form
    {
        private const int VisibleMs = 1400;
        private readonly string _old;
        private readonly string _new;
        private readonly bool _isInfo;
        private Timer _timer;
        private int _age;
        private readonly int _stepMs = 40;

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= 0x8;          // WS_EX_TOPMOST
                cp.ExStyle |= 0x80;         // WS_EX_TOOLWINDOW
                cp.ExStyle |= 0x08000000;   // WS_EX_NOACTIVATE
                return cp;
            }
        }

        private ConvertPopup(string oldText, string newText)
        {
            _old = oldText;
            _new = newText;
            _isInfo = string.IsNullOrEmpty(newText);
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = false;
            BackColor = UiTheme.Bg;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);
            Size = Measure();
        }

        private Size Measure()
        {
            Font fOld = UiTheme.Font(10f, false);
            Font fNew = UiTheme.Font(10f, true);
            int pad = Dp(14);
            int w;
            if (_isInfo)
            {
                w = TextRenderer.MeasureText(_old, fOld).Width + pad * 2;
            }
            else
            {
                string o = Trunc(_old);
                string n = Trunc(_new);
                w = TextRenderer.MeasureText(o, fOld).Width +
                    TextRenderer.MeasureText("  →  ", fOld).Width +
                    TextRenderer.MeasureText(n, fNew).Width + pad * 2;
            }
            int h = TextRenderer.MeasureText("Пример", fNew).Height + Dp(18);
            return new Size(Math.Max(w, Dp(120)), h);
        }

        private static string Trunc(string s)
        {
            if (s == null) return "";
            if (s.Length > 26) return s.Substring(0, 25) + "…";
            return s;
        }

        private int Dp(int px) { return UiTheme.Dp(this, px); }

        public static void Show(Point screenPoint, string oldText, string newText)
        {
            ConvertPopup p = null;
            try
            {
                p = new ConvertPopup(oldText, newText);
                var wa = Screen.FromPoint(screenPoint).WorkingArea;
                int x = screenPoint.X + 10;
                int y = screenPoint.Y + 6;
                if (x + p.Width > wa.Right - 8) x = wa.Right - 8 - p.Width;
                if (x < wa.Left + 8) x = wa.Left + 8;
                if (y + p.Height > wa.Bottom - 8) y = screenPoint.Y - p.Height - 10;
                if (y < wa.Top + 8) y = wa.Top + 8;
                p.Location = new Point(x, y);
                p.Show();
            }
            catch (Exception)
            {
                if (p != null) p.Dispose();
            }
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            _timer = new Timer();
            _timer.Interval = _stepMs;
            _timer.Tick += OnTick;
            _timer.Start();
        }

        private void OnTick(object sender, EventArgs e)
        {
            _age += _stepMs;
            if (_age < VisibleMs) return;
            double fade = (_age - VisibleMs) / 300.0;
            if (fade >= 1)
            {
                _timer.Stop();
                _timer.Dispose();
                Close();
                Dispose();
                return;
            }
            Opacity = 1.0 - fade;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var p = UiTheme.RoundRect(r, Dp(10)))
            {
                using (var b = new SolidBrush(UiTheme.Card)) e.Graphics.FillPath(b, p);
                using (var pen = new Pen(UiTheme.CardBorder)) e.Graphics.DrawPath(pen, p);
            }
            int pad = Dp(14);
            var rect = new Rectangle(pad, 0, Width - pad * 2, Height);
            if (_isInfo)
            {
                TextRenderer.DrawText(e.Graphics, _old, UiTheme.Font(10f, false), rect, UiTheme.Dim,
                    TextFormatFlags.VerticalCenter | TextFormatFlags.Default);
                return;
            }
            Font fOld = UiTheme.Font(10f, false);
            Font fNew = UiTheme.Font(10f, true);
            string o = Trunc(_old);
            string n = Trunc(_new);
            int wOld = TextRenderer.MeasureText(o, fOld).Width;
            int wArrow = TextRenderer.MeasureText("  →  ", fOld).Width;
            var r1 = new Rectangle(rect.X, 0, wOld + 4, Height);
            var r2 = new Rectangle(rect.X + wOld, 0, wArrow, Height);
            var r3 = new Rectangle(rect.X + wOld + wArrow, 0, rect.Width - wOld - wArrow, Height);
            TextRenderer.DrawText(e.Graphics, o, fOld, r1, UiTheme.Dim,
                TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
            TextRenderer.DrawText(e.Graphics, "  →  ", fOld, r2, UiTheme.Dim,
                TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
            TextRenderer.DrawText(e.Graphics, n, fNew, r3, UiTheme.Accent,
                TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        }
    }
}
