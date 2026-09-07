using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace OpenSwitcher.UI
{
    /// <summary>Палитра и типографика. Светлая/тёмная темы + автосмена от системной.</summary>
    public static class UiTheme
    {
        /// <summary>0 = как в системе, 1 = светлая, 2 = тёмная.</summary>
        public static int Mode;

        private static bool _light;
        public static bool IsLight { get { return _light; } }

        public static event Action Changed;

        public static Color Bg;
        public static Color SidebarBg;
        public static Color Card;
        public static Color CardBorder;
        public static Color Input;
        public static Color InputBorder;
        public static Color ChipBg;
        public static Color Text;
        public static Color Dim;
        public static Color Accent;
        public static Color AccentHover;
        public static Color AccentPressed;
        public static Color AccentSoft;
        public static Color Hero1;
        public static Color Hero2;
        public static Color Paused1;
        public static Color Paused2;
        public static Color Ok;
        public static Color Warn;
        public static Color Danger;
        public static Color TrackOff;
        public static Color RowHover;

        private const string KeyPersonalize = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

        static UiTheme()
        {
            Apply(ReadSystemLight(), true);
        }

        public static void ApplyMode(int mode)
        {
            Mode = mode;
            Apply(mode == 1 ? true : (mode == 2 ? false : ReadSystemLight()), true);
        }

        /// <summary>Вызывается при смене темы Windows; действует только в режиме «системная».</summary>
        public static void RefreshFromSystem()
        {
            if (Mode == 0) Apply(ReadSystemLight(), false);
        }

        public static bool ReadSystemLight()
        {
            try
            {
                using (var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(KeyPersonalize))
                {
                    if (k != null)
                    {
                        object v = k.GetValue("AppsUseLightTheme");
                        if (v is int) return ((int)v) != 0;
                        if (v != null) return v.ToString() != "0";
                    }
                }
            }
            catch (Exception) { }
            return false;
        }

        private static void Apply(bool light, bool force)
        {
            if (!force && light == _light) return;
            _light = light;
            if (light)
            {
                Bg = FromHex("#F4F5F8");
                SidebarBg = FromHex("#EAECF1");
                Card = FromHex("#FFFFFF");
                CardBorder = FromHex("#E2E4EA");
                Input = FromHex("#FFFFFF");
                InputBorder = FromHex("#D6DAE2");
                ChipBg = FromHex("#F0F2F6");
                Text = FromHex("#191B1F");
                Dim = FromHex("#6E747E");
                Accent = FromHex("#3671F6");
                AccentHover = FromHex("#2861E4");
                AccentPressed = FromHex("#2153C6");
                AccentSoft = FromHex("#E8EFFF");
                Hero1 = FromHex("#3D74F5");
                Hero2 = FromHex("#8B5CF6");
                Paused1 = FromHex("#B4BAC5");
                Paused2 = FromHex("#8B919D");
                Ok = FromHex("#1FA463");
                Warn = FromHex("#C78A12");
                Danger = FromHex("#D93A3F");
                TrackOff = FromHex("#CDD2DB");
                RowHover = FromHex("#F2F4F8");
            }
            else
            {
                Bg = FromHex("#141519");
                SidebarBg = FromHex("#101114");
                Card = FromHex("#1C1E24");
                CardBorder = FromHex("#2A2D35");
                Input = FromHex("#121317");
                InputBorder = FromHex("#31353F");
                ChipBg = FromHex("#22252C");
                Text = FromHex("#E9EAEE");
                Dim = FromHex("#969DA8");
                Accent = FromHex("#628FFF");
                AccentHover = FromHex("#7AA0FF");
                AccentPressed = FromHex("#4A79E8");
                AccentSoft = FromHex("#26304A");
                Hero1 = FromHex("#4A7CF8");
                Hero2 = FromHex("#7C5CFF");
                Paused1 = FromHex("#4B4F59");
                Paused2 = FromHex("#35383F");
                Ok = FromHex("#3FBF7F");
                Warn = FromHex("#E8B341");
                Danger = FromHex("#E5484D");
                TrackOff = FromHex("#3A3E48");
                RowHover = FromHex("#22252C");
            }
            var h = Changed;
            if (h != null) h();
        }

        public static Color FromHex(string hex)
        {
            return Color.FromArgb(
                Convert.ToInt32(hex.Substring(1, 2), 16),
                Convert.ToInt32(hex.Substring(3, 2), 16),
                Convert.ToInt32(hex.Substring(5, 2), 16));
        }

        public static Color Lerp(Color a, Color b, float t)
        {
            if (t < 0) t = 0; if (t > 1) t = 1;
            return Color.FromArgb(
                (int)(a.A + (b.A - a.A) * t),
                (int)(a.R + (b.R - a.R) * t),
                (int)(a.G + (b.G - a.G) * t),
                (int)(a.B + (b.B - a.B) * t));
        }

        private static bool _varChecked;
        private static string _family;
        public static string Family
        {
            get
            {
                if (!_varChecked)
                {
                    _varChecked = true;
                    try
                    {
                        using (var f = new Font("Segoe UI Variable Display", 10f))
                            _family = f.Name == "Segoe UI Variable Display" ? f.Name : "Segoe UI";
                    }
                    catch (Exception) { _family = "Segoe UI"; }
                }
                return _family;
            }
        }

        public static Font Font(float size, bool bold)
        {
            return new Font(Family, size, bold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Point);
        }

        public static GraphicsPath RoundRect(Rectangle r, int radius)
        {
            var p = new GraphicsPath();
            int d = radius * 2;
            if (d > r.Width) d = r.Width;
            if (d > r.Height) d = r.Height;
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        /// <summary>Пиксели -> DevicePixel (для чёткости на масштабах >100%).</summary>
        public static int Dp(Control c, int px)
        {
            return (int)Math.Round(px * c.DeviceDpi / 96.0);
        }
    }

    /// <summary>Векторные пиктограммы (штриховые, скруглённые).</summary>
    public static class Glyphs
    {
        public static void Draw(Graphics g, string name, Rectangle r, Color c)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (var pen = new Pen(c, 1.6f))
            {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                int cx = r.X + r.Width / 2, cy = r.Y + r.Height / 2;
                int rad = Math.Min(r.Width, r.Height) / 2 - 1;

                if (name == "fix") // круговые стрелки
                {
                    g.DrawArc(pen, cx - rad, cy - rad, rad * 2, rad * 2, -50, 150);
                    g.DrawArc(pen, cx - rad, cy - rad, rad * 2, rad * 2, 130, 150);
                    int s = Math.Max(3, rad / 3);
                    g.DrawLine(pen, cx + rad - s - 1, cy - rad + s - 2, cx + rad, cy - rad + s + 1);
                    g.DrawLine(pen, cx + rad, cy - rad + s + 1, cx + rad - s + 1, cy - rad + s + 3);
                    g.DrawLine(pen, cx - rad + s + 1, cy + rad - s - 2, cx - rad, cy + rad - s + 1);
                    g.DrawLine(pen, cx - rad, cy + rad - s + 1, cx - rad + s - 1, cy + rad - s - 3);
                }
                else if (name == "keys") // клавиатура
                {
                    var body = new Rectangle(cx - rad, cy - rad + 2, rad * 2, rad * 2 - 4);
                    using (var p2 = UiTheme.RoundRect(body, 4)) g.DrawPath(pen, p2);
                    int ky = cy - 1;
                    g.DrawLine(pen, cx - rad + 4, ky, cx + rad - 4, ky);
                    using (var dot = new Pen(c, 1.4f))
                        foreach (int dx in new int[] { -rad + 5, -2, rad - 5 })
                            g.DrawLine(dot, cx + dx, cy - rad + 5, cx + dx, cy - rad + 5);
                }
                else if (name == "look") // полукруг — тема
                {
                    g.DrawEllipse(pen, cx - rad, cy - rad, rad * 2, rad * 2);
                    using (var b = new SolidBrush(c))
                        g.FillPie(b, cx - rad, cy - rad, rad * 2, rad * 2, 90, 180);
                }
                else if (name == "block") // «не в этой программе»
                {
                    g.DrawEllipse(pen, cx - rad, cy - rad, rad * 2, rad * 2);
                    double d = rad * 0.707;
                    g.DrawLine(pen, (float)(cx - d), (float)(cy - d), (float)(cx + d), (float)(cy + d));
                }
                else if (name == "sys") // шестерёнка
                {
                    g.DrawEllipse(pen, cx - rad + 4, cy - rad + 4, (rad - 4) * 2, (rad - 4) * 2);
                    double r0 = (rad - 4), r1 = rad;
                    for (int a = 0; a < 8; a++)
                    {
                        double ang = a * Math.PI / 4.0;
                        g.DrawLine(pen,
                            (float)(cx + r0 * Math.Cos(ang)), (float)(cy + r0 * Math.Sin(ang)),
                            (float)(cx + r1 * Math.Cos(ang)), (float)(cy + r1 * Math.Sin(ang)));
                    }
                }
            }
        }
    }
}
