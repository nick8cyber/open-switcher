using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using OpenSwitcher.Core;

namespace OpenSwitcher.UI
{
    /// <summary>Анимированный переключатель.</summary>
    public class ToggleSwitch : Control
    {
        private bool _checked;
        private float _anim;           // 0..1
        private Timer _tmr;

        public event EventHandler CheckedChanged;

        public bool Checked
        {
            get { return _checked; }
            set { _checked = value; StartAnim(); }
        }

        public ToggleSwitch()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            BackColor = UiTheme.Card;
            Cursor = Cursors.Hand;
            Size = new Size(46, 24);
            _anim = _checked ? 1f : 0f;
            _tmr = new Timer();
            _tmr.Interval = 10;
            _tmr.Tick += delegate
            {
                float target = _checked ? 1f : 0f;
                _anim += (target - _anim) * 0.35f;
                if (Math.Abs(target - _anim) < 0.02f) { _anim = target; _tmr.Stop(); }
                Invalidate();
            };
        }

        private void StartAnim()
        {
            _tmr.Stop();
            _tmr.Start();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing && _tmr != null) _tmr.Dispose();
            base.Dispose(disposing);
        }

        protected override void OnClick(EventArgs e)
        {
            _checked = !_checked;
            StartAnim();
            var h = CheckedChanged;
            if (h != null) h(this, EventArgs.Empty);
            base.OnClick(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var track = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var p = UiTheme.RoundRect(track, Height / 2))
            using (var b = new SolidBrush(UiTheme.Lerp(UiTheme.TrackOff, UiTheme.Accent, _anim)))
                e.Graphics.FillPath(b, p);
            int pad = 2;
            int knob = Height - pad * 2;
            float x = pad + (Width - knob - pad * 2) * _anim;
            using (var b = new SolidBrush(Color.White))
                e.Graphics.FillEllipse(b, x, pad, knob, knob);
        }
    }

    /// <summary>Поле захвата сочетания; показывает модификаторы как «клавиши»-чипы.</summary>
    public class HotkeyBox : Control
    {
        private bool _capture;
        private string _error;

        public int Vk;
        public int Mods;

        public HotkeyBox()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.UserPaint | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
            BackColor = UiTheme.Card;
            Cursor = Cursors.Hand;
            Size = new Size(210, 36);
            TabStop = true;
        }

        protected override void OnClick(EventArgs e) { Focus(); base.OnClick(e); }
        protected override void OnGotFocus(EventArgs e) { _capture = true; _error = null; Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { _capture = false; Invalidate(); base.OnLostFocus(e); }
        protected override bool IsInputKey(Keys keyData) { return true; }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (!_capture) { base.OnKeyDown(e); return; }
            Keys code = e.KeyCode;
            if (code == Keys.Escape) { _capture = false; Invalidate(); base.OnKeyDown(e); return; }
            if (code == Keys.Back && e.Modifiers == Keys.None)
            {
                Vk = 0; Mods = 0; _capture = false; Invalidate();
                base.OnKeyDown(e);
                return;
            }
            // одиночный левый/правый Shift — самостоятельный хоткей (переключение раскладки)
            if (code == Keys.LShiftKey || code == Keys.RShiftKey)
            {
                Vk = code == Keys.LShiftKey ? 0xA0 : 0xA1;
                Mods = 0;
                _error = null;
                _capture = false;
                Invalidate();
                base.OnKeyDown(e);
                return;
            }
            int vk = (int)code;
            if (code == Keys.ControlKey || code == Keys.ShiftKey || code == Keys.Menu ||
                code == Keys.LWin || code == Keys.RWin || code == Keys.LControlKey ||
                code == Keys.RControlKey || code == Keys.LMenu || code == Keys.RMenu)
            {
                base.OnKeyDown(e);
                return;
            }
            // ВАЖНО: Win-модификатор читается из e.Modifiers, а не побитовой маской по KeyCode
            int mods = (e.Control ? HK.CTRL : 0) | (e.Shift ? HK.SHIFT : 0) | (e.Alt ? HK.ALT : 0) |
                       ((e.Modifiers & (Keys)0x40000) != 0 ? HK.WIN : 0);
            bool textKey = (vk >= 'A' && vk <= 'Z') || (vk >= '0' && vk <= '9') || vk == 0x20;
            if (textKey && (mods & (HK.CTRL | HK.ALT | HK.WIN)) == 0)
            {
                _error = "Нужен Ctrl или Alt";
                Invalidate();
                base.OnKeyDown(e);
                return;
            }
            Vk = vk; Mods = mods; _error = null; _capture = false;
            Invalidate();
            base.OnKeyDown(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var p = UiTheme.RoundRect(r, 9))
            {
                using (var b = new SolidBrush(UiTheme.Input)) e.Graphics.FillPath(b, p);
                using (var pen = new Pen(_capture || Focused ? UiTheme.Accent : UiTheme.InputBorder,
                       _capture || Focused ? 1.6f : 1f))
                    e.Graphics.DrawPath(pen, p);
            }
            Font f = UiTheme.Font(9f, false);
            if (_capture)
            {
                TextRenderer.DrawText(e.Graphics, "Нажмите сочетание…", f,
                    new Rectangle(12, 0, Width - 24, Height),
                    UiTheme.Accent, TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
                return;
            }
            if (_error != null)
            {
                TextRenderer.DrawText(e.Graphics, _error, f,
                    new Rectangle(12, 0, Width - 24, Height),
                    UiTheme.Danger, TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
                return;
            }
            if (Vk == 0)
            {
                TextRenderer.DrawText(e.Graphics, "Не задано", f,
                    new Rectangle(12, 0, Width - 24, Height),
                    UiTheme.Dim, TextFormatFlags.VerticalCenter);
                return;
            }
            // чипы-клавиши
            int pad = 8;
            int chipH = Height - 12;
            int x = 10;
            int y = (Height - chipH) / 2;
            if ((Mods & HK.CTRL) != 0) x = DrawChip(e.Graphics, "Ctrl", x, y, chipH, f) + 4;
            if ((Mods & HK.SHIFT) != 0) x = DrawChip(e.Graphics, "Shift", x, y, chipH, f) + 4;
            if ((Mods & HK.ALT) != 0) x = DrawChip(e.Graphics, "Alt", x, y, chipH, f) + 4;
            if ((Mods & HK.WIN) != 0) x = DrawChip(e.Graphics, "Win", x, y, chipH, f) + 4;
            DrawChip(e.Graphics, KeyName(Vk), x, y, chipH, UiTheme.Font(9f, true));
        }

        private int DrawChip(Graphics g, string text, int x, int y, int h, Font f)
        {
            Size t = TextRenderer.MeasureText(text, f);
            int w = t.Width + 14;
            if (x + w > Width - 6) return x; // не влезло
            var r = new Rectangle(x, y, w, h);
            using (var p = UiTheme.RoundRect(r, 6))
            {
                using (var b = new SolidBrush(UiTheme.ChipBg)) g.FillPath(b, p);
                using (var pen = new Pen(UiTheme.InputBorder)) g.DrawPath(pen, p);
            }
            TextRenderer.DrawText(g, text, f, r, UiTheme.Text,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
            return x + w;
        }

        private static string KeyName(int vk)
        {
            if (vk == 0xA0) return "Левый Shift";
            if (vk == 0xA1) return "Правый Shift";
            if (vk == 0x13) return "Pause (Break)";
            if (vk == 0x14) return "Caps Lock";
            if (vk == 0x2C) return "Print Screen";
            try { return new KeysConverter().ConvertToString((Keys)vk); }
            catch (Exception) { return ((Keys)vk).ToString(); }
        }

        public static string HotkeyText(int vk, int mods)
        {
            string s = "";
            if ((mods & HK.CTRL) != 0) s += "Ctrl+";
            if ((mods & HK.SHIFT) != 0) s += "Shift+";
            if ((mods & HK.ALT) != 0) s += "Alt+";
            if ((mods & HK.WIN) != 0) s += "Win+";
            return s + KeyName(vk);
        }
    }

    /// <summary>Сегментный выбор с hover-подсветкой.</summary>
    public class ChoiceSeg : Control
    {
        private string[] _items = new string[0];
        private int _index;
        private int _hover = -1;
        public event EventHandler SelectedChanged;

        public string[] Items
        {
            get { return _items; }
            set { _items = value ?? new string[0]; if (_index >= _items.Length) _index = 0; Invalidate(); }
        }

        public int SelectedIndex
        {
            get { return _index; }
            set { _index = Math.Max(0, Math.Min(_items.Length - 1, value)); Invalidate(); }
        }

        public ChoiceSeg()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            BackColor = UiTheme.Card;
            Cursor = Cursors.Hand;
            Size = new Size(252, 34);
        }

        private int HitSeg(int x)
        {
            if (_items.Length == 0) return -1;
            return Math.Min(_items.Length - 1, x * _items.Length / Width);
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            int h = HitSeg(e.X);
            if (h != _hover) { _hover = h; Invalidate(); }
            base.OnMouseMove(e);
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            _hover = -1; Invalidate(); base.OnMouseLeave(e);
        }

        protected override void OnMouseClick(MouseEventArgs e)
        {
            int seg = HitSeg(e.X);
            if (seg >= 0 && seg != _index)
            {
                _index = seg;
                Invalidate();
                var h = SelectedChanged;
                if (h != null) h(this, EventArgs.Empty);
            }
            base.OnMouseClick(e);
        }

        protected override void OnMouseWheel(MouseEventArgs e)
        {
            if (_items.Length > 0)
            {
                _index = (_index + (e.Delta > 0 ? -1 : 1) + _items.Length) % _items.Length;
                Invalidate();
                var h = SelectedChanged;
                if (h != null) h(this, EventArgs.Empty);
            }
            base.OnMouseWheel(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var p = UiTheme.RoundRect(r, 9))
            {
                using (var b = new SolidBrush(UiTheme.Input)) e.Graphics.FillPath(b, p);
                using (var pen = new Pen(UiTheme.InputBorder)) e.Graphics.DrawPath(pen, p);
            }
            if (_items.Length == 0) return;
            int segW = Width / _items.Length;
            Font f = UiTheme.Font(9f, false);
            for (int i = 0; i < _items.Length; i++)
            {
                var seg = new Rectangle(i * segW + 2, 3,
                    segW - 4, Height - 6);
                bool sel = i == _index;
                if (sel)
                {
                    using (var p2 = UiTheme.RoundRect(seg, 7))
                    {
                        using (var b = new SolidBrush(UiTheme.AccentSoft)) e.Graphics.FillPath(b, p2);
                        using (var pen = new Pen(UiTheme.Accent)) e.Graphics.DrawPath(pen, p2);
                    }
                    TextRenderer.DrawText(e.Graphics, _items[i], UiTheme.Font(9f, true), seg, UiTheme.Text,
                        TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
                }
                else
                {
                    if (i == _hover)
                    {
                        using (var p2 = UiTheme.RoundRect(seg, 7))
                        using (var b = new SolidBrush(UiTheme.RowHover)) e.Graphics.FillPath(b, p2);
                    }
                    TextRenderer.DrawText(e.Graphics, _items[i], f, seg, UiTheme.Dim,
                        TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
                }
            }
        }
    }

    /// <summary>Минимальный числовой бокс: значение меняется кнопками/колесом.</summary>
    public class NumBox : Control
    {
        private int _min = 2, _max = 8, _value = 3;
        private bool _hoverUp, _hoverDown;
        public event EventHandler ValueChanged;

        public int Min { get { return _min; } set { _min = value; } }
        public int Max { get { return _max; } set { _max = value; } }

        public int Value
        {
            get { return _value; }
            set { _value = Math.Max(_min, Math.Min(_max, value)); Invalidate(); }
        }

        public NumBox()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            BackColor = UiTheme.Card;
            Cursor = Cursors.Hand;
            Size = new Size(84, 34);
        }

        private Rectangle UpRect()
        {
            int btn = 36;
            return new Rectangle(Width - btn, 0, btn, Height / 2);
        }

        private Rectangle DownRect()
        {
            int btn = 36;
            return new Rectangle(Width - btn, Height / 2, btn, Height - Height / 2);
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            bool u = UpRect().Contains(e.Location), d = DownRect().Contains(e.Location);
            if (u != _hoverUp || d != _hoverDown) { _hoverUp = u; _hoverDown = d; Invalidate(); }
            base.OnMouseMove(e);
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            _hoverUp = _hoverDown = false; Invalidate(); base.OnMouseLeave(e);
        }

        private void Step(int delta)
        {
            Value += delta;
            var h = ValueChanged;
            if (h != null) h(this, EventArgs.Empty);
        }

        protected override void OnMouseClick(MouseEventArgs e)
        {
            if (UpRect().Contains(e.Location)) Step(1);
            else if (DownRect().Contains(e.Location)) Step(-1);
            base.OnMouseClick(e);
        }

        protected override void OnMouseWheel(MouseEventArgs e)
        {
            Step(e.Delta > 0 ? 1 : -1);
            base.OnMouseWheel(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var p = UiTheme.RoundRect(r, 9))
            {
                using (var b = new SolidBrush(UiTheme.Input)) e.Graphics.FillPath(b, p);
                using (var pen = new Pen(UiTheme.InputBorder)) e.Graphics.DrawPath(pen, p);
            }
            int btn = 36;
            TextRenderer.DrawText(e.Graphics, Value.ToString(), UiTheme.Font(10f, true),
                new Rectangle(12, 0, Width - btn - 16, Height),
                UiTheme.Text, TextFormatFlags.VerticalCenter);
            int half = Height / 2;
            int cx = Width - btn / 2 - 2;
            using (var pen = new Pen(_hoverUp || _hoverDown ? UiTheme.Text : UiTheme.Dim, 1.6f))
            {
                pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
                int s = 4;
                e.Graphics.DrawLine(pen, cx - s, half - 4, cx, half - 8);
                e.Graphics.DrawLine(pen, cx, half - 8, cx + s, half - 4);
                e.Graphics.DrawLine(pen, cx - s, half + 4, cx, half + 8);
                e.Graphics.DrawLine(pen, cx, half + 8, cx + s, half + 4);
            }
        }
    }

    /// <summary>Кнопка: акцентная с градиентом или ghost.</summary>
    public class RoundedButton : Control
    {
        public bool Accent = true;
        private bool _hover;
        private bool _down;

        public RoundedButton()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            BackColor = UiTheme.Bg;
            Cursor = Cursors.Hand;
            Size = new Size(110, 38);
        }

        protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { _hover = false; _down = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { _down = true; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { _down = false; Invalidate(); base.OnMouseUp(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var p = UiTheme.RoundRect(r, 10))
            {
                if (Accent)
                {
                    Rectangle gr = new Rectangle(0, 0, Width, Height);
                    using (var b = _down
                        ? (Brush)new SolidBrush(UiTheme.AccentPressed)
                        : new LinearGradientBrush(gr, UiTheme.Accent, UiTheme.AccentPressed, 90f))
                        e.Graphics.FillPath(b, p);
                    TextRenderer.DrawText(e.Graphics, Text, UiTheme.Font(10f, true), r, Color.White,
                        TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
                }
                else
                {
                    using (var b = new SolidBrush(_hover || _down ? UiTheme.RowHover : UiTheme.Input))
                        e.Graphics.FillPath(b, p);
                    using (var pen = new Pen(_hover ? UiTheme.Accent : UiTheme.InputBorder)) e.Graphics.DrawPath(pen, p);
                    TextRenderer.DrawText(e.Graphics, Text, UiTheme.Font(10f, false), r, UiTheme.Text,
                        TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
                }
            }
        }
    }

    /// <summary>Кнопки заголовка окна: крестик и свернуть.</summary>
    public class TitleButton : Control
    {
        public string Kind = "close"; // close | min
        private bool _hover;

        public TitleButton()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            BackColor = UiTheme.Bg;
            Cursor = Cursors.Hand;
            Size = new Size(40, 40);
        }

        protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { _hover = false; Invalidate(); base.OnMouseLeave(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            if (_hover)
            {
                using (var b = new SolidBrush(Kind == "close" ? UiTheme.Danger : UiTheme.RowHover))
                    e.Graphics.FillRectangle(b, 0, 0, Width, Height);
            }
            using (var pen = new Pen(_hover && Kind == "close" ? Color.White : UiTheme.Dim, 1.7f))
            {
                pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
                int cx = Width / 2, cy = Height / 2;
                if (Kind == "close")
                {
                    int s = 5;
                    e.Graphics.DrawLine(pen, cx - s, cy - s, cx + s, cy + s);
                    e.Graphics.DrawLine(pen, cx + s, cy - s, cx - s, cy + s);
                }
                else
                {
                    int s = 5;
                    e.Graphics.DrawLine(pen, cx - s, cy, cx + s, cy);
                }
            }
        }
    }

    /// <summary>Карточка страницы: строки (заголовок + описание) с hover и разделителями.</summary>
    /// <summary>Рамка-поле для TextBox без бордюра.</summary>
    public class InputPanel : Panel
    {
        public InputPanel(TextBox tb, int height)
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
            BackColor = UiTheme.Input;
            Height = height;
            tb.BorderStyle = BorderStyle.None;
            tb.BackColor = UiTheme.Input;
            tb.ForeColor = UiTheme.Text;
            tb.Parent = this;
            if (tb.Multiline)
                tb.SetBounds(10, 8, Math.Max(50, Width - 20), height - 16);
            else
                tb.SetBounds(10, (height - tb.Height) / 2, Math.Max(50, Width - 20), tb.Height);
        }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            foreach (Control c in Controls)
            {
                var tb = c as TextBox;
                if (tb != null && tb.Multiline) tb.SetBounds(10, 8, Math.Max(50, Width - 20), Height - 16);
                else c.SetBounds(10, (Height - c.Height) / 2, Math.Max(50, Width - 20), c.Height);
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var p = UiTheme.RoundRect(r, 9))
            {
                using (var b = new SolidBrush(UiTheme.Input)) e.Graphics.FillPath(b, p);
                using (var pen = new Pen(UiTheme.InputBorder)) e.Graphics.DrawPath(pen, p);
            }
        }
    }

    public class PageCard : Panel
    {
        public class Row
        {
            public string Title;
            public string Desc;
            public Control Ctrl;
            public int Height;
            public Rectangle Bounds;
        }

        private readonly List<Row> _rows = new List<Row>();
        private int _hover = -1;
        private int _y;
        public const int PadTop = 6;

        public PageCard()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
            BackColor = UiTheme.Card;
        }

        public int CardWidth { get { return Width; } }

        /// <summary>Добавить строку; control прикладывается справа по центру.</summary>
        public void AddRow(string title, string desc, Control ctrl, int rowH)
        {
            var row = new Row();
            row.Title = title;
            row.Desc = desc;
            row.Ctrl = ctrl;
            row.Height = rowH;
            int pad = 18;
            int ctrlW = ctrl != null ? ctrl.Width : 0;
            int rowY = _y + PadTop;
            row.Bounds = new Rectangle(0, rowY, Width, rowH);

            if (desc != null)
            {
                var t = MkLabel(title, UiTheme.Text, false);
                t.SetBounds(pad, rowY + 8, Width - pad * 2 - ctrlW - 12, 18);
                Controls.Add(t);

                var d = MkLabel(desc, UiTheme.Dim, true);
                d.SetBounds(pad, rowY + 28, Width - pad * 2 - ctrlW - 12, 16);
                Controls.Add(d);
            }
            else
            {
                var t = MkLabel(title, UiTheme.Text, false);
                t.SetBounds(pad, rowY, Width - pad * 2 - ctrlW - 12, rowH);
                t.TextAlign = ContentAlignment.MiddleLeft;
                Controls.Add(t);
            }
            if (ctrl != null)
            {
                ctrl.Location = new Point(Width - pad - ctrlW, rowY + (rowH - ctrl.Height) / 2);
                Controls.Add(ctrl);
            }
            _rows.Add(row);
            _y = rowY + rowH;
            Height = _y + PadTop;
        }

        private static Label MkLabel(string text, Color color, bool dim)
        {
            var lbl = new Label();
            lbl.Text = text;
            lbl.Font = UiTheme.Font(dim ? 8.75f : 10f, false);
            lbl.ForeColor = color;
            lbl.BackColor = Color.Transparent;
            lbl.AutoSize = false;
            if (dim) lbl.Tag = "dim";
            return lbl;
        }

        private int HitRow(Point p)
        {
            for (int i = 0; i < _rows.Count; i++)
                if (_rows[i].Bounds.Contains(p)) return i;
            return -1;
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            int h = HitRow(e.Location);
            if (h != _hover) { _hover = h; Invalidate(); }
            base.OnMouseMove(e);
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            _hover = -1; Invalidate(); base.OnMouseLeave(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var p = UiTheme.RoundRect(r, 14))
            {
                using (var b = new SolidBrush(UiTheme.Card)) e.Graphics.FillPath(b, p);
                using (var pen = new Pen(UiTheme.CardBorder)) e.Graphics.DrawPath(pen, p);
            }
            for (int i = 0; i < _rows.Count; i++)
            {
                Row row = _rows[i];
                if (i == _hover)
                {
                    var hr = new Rectangle(4, row.Bounds.Y,
                        Width - 8, row.Bounds.Height);
                    using (var p2 = UiTheme.RoundRect(hr, 10))
                    using (var b = new SolidBrush(UiTheme.RowHover))
                        e.Graphics.FillPath(b, p2);
                }
                if (i < _rows.Count - 1)
                {
                    int y = row.Bounds.Bottom;
                    using (var pen = new Pen(UiTheme.CardBorder))
                        e.Graphics.DrawLine(pen, 18, y, Width - 18, y);
                }
            }
            base.OnPaint(e);
        }
    }

    /// <summary>Градиентная статус-карточка с кнопкой паузы.</summary>
    public class StatusHero : Control
    {
        private bool _hoverBtn;
        private bool _down;

        public event Action PauseToggled;

        public StatusHero()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            BackColor = UiTheme.Bg;
            Size = new Size(624, 64);
        }

        private bool Paused { get; set; }
        public void SetPaused(bool paused) { Paused = paused; Invalidate(); }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            bool h = _btnRect.Contains(e.Location);
            if (h != _hoverBtn) { _hoverBtn = h; Invalidate(); }
            base.OnMouseMove(e);
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            _hoverBtn = false; _down = false; Invalidate(); base.OnMouseLeave(e);
        }

        protected override void OnMouseDown(MouseEventArgs e) { _down = true; Invalidate(); base.OnMouseDown(e); }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            bool wasDown = _down;
            _down = false;
            if (wasDown && _btnRect.Contains(e.Location))
            {
                Paused = !Paused;
                Invalidate();
                var h = PauseToggled;
                if (h != null) h();
            }
            Invalidate();
            base.OnMouseUp(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            Rectangle gr = new Rectangle(0, 0, Width, Height);
            using (var p = UiTheme.RoundRect(r, 14))
            using (var b = new LinearGradientBrush(gr,
                Paused ? UiTheme.Paused1 : UiTheme.Hero1,
                Paused ? UiTheme.Paused2 : UiTheme.Hero2, 12f))
                e.Graphics.FillPath(b, p);

            Font fBig = UiTheme.Font(11.5f, true);
            Font fSub = UiTheme.Font(8.5f, false);
            Font fBtn = UiTheme.Font(9f, true);
            string bigText = Paused ? "На паузе" : "Работает";
            string subText = Paused ? "Автоисправление отключено" : "Автоисправление активно · Ru ⇄ En";
            string btnText = Paused ? "Возобновить" : "Приостановить";

            int cx = 24, cy = Height / 2;
            using (var b = new SolidBrush(Color.White))
            {
                if (Paused)
                {
                    e.Graphics.FillRectangle(b, cx - 5, cy - 6, 4, 12);
                    e.Graphics.FillRectangle(b, cx + 2, cy - 6, 4, 12);
                }
                else
                {
                    e.Graphics.FillEllipse(b, cx - 6, cy - 6, 12, 12);
                }
            }

            Size bigS = TextRenderer.MeasureText(bigText, fBig);
            Size subS = TextRenderer.MeasureText(subText, fSub);
            int textX = 44;
            int blockH = bigS.Height + 2 + subS.Height;
            int textY = (Height - blockH) / 2;
            TextRenderer.DrawText(e.Graphics, bigText, fBig,
                new Rectangle(textX, textY, bigS.Width + 8, bigS.Height),
                Color.White, TextFormatFlags.NoPadding);
            TextRenderer.DrawText(e.Graphics, subText, fSub,
                new Rectangle(textX, textY + bigS.Height + 2, subS.Width + 8, subS.Height),
                Color.FromArgb(205, 255, 255, 255), TextFormatFlags.NoPadding);

            Size btnS = TextRenderer.MeasureText(btnText, fBtn);
            int btnW = btnS.Width + 36;
            int btnH = Math.Max(btnS.Height + 12, 32);
            var br = new Rectangle(Width - btnW - 18, (Height - btnH) / 2, btnW, btnH);
            _btnRect = br;
            using (var p = UiTheme.RoundRect(br, 9))
            {
                using (var b = new SolidBrush(_hoverBtn || _down ? Color.FromArgb(50, 255, 255, 255) : Color.FromArgb(26, 255, 255, 255)))
                    e.Graphics.FillPath(b, p);
                using (var pen = new Pen(Color.FromArgb(150, 255, 255, 255))) e.Graphics.DrawPath(pen, p);
            }
            TextRenderer.DrawText(e.Graphics, btnText, fBtn, br, Color.White,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        }

        private Rectangle _btnRect = Rectangle.Empty;
    }

    /// <summary>Сайдбар с навигацией по страницам.</summary>
    public class SidebarPanel : Panel
    {
        private string[] _titles;
        private string[] _icons;
        private int _active;
        private int _hover = -1;

        public event Action<int> PageActivated;

        public SidebarPanel(string[] titles, string[] icons, int active)
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
            _titles = titles;
            _icons = icons;
            _active = active;
            BackColor = UiTheme.SidebarBg;
            Cursor = Cursors.Hand;
        }

        private Rectangle ItemRect(int i)
        {
            int y = 12 + i * (42 + 4);
            return new Rectangle(8, y, Width - 16, 42);
        }

        private int Hit(Point p)
        {
            for (int i = 0; i < _titles.Length; i++)
                if (ItemRect(i).Contains(p)) return i;
            return -1;
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            int h = Hit(e.Location);
            if (h != _hover) { _hover = h; Invalidate(); }
            base.OnMouseMove(e);
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            _hover = -1; Invalidate(); base.OnMouseLeave(e);
        }

        protected override void OnMouseClick(MouseEventArgs e)
        {
            int h = Hit(e.Location);
            if (h >= 0 && h != _active)
            {
                _active = h;
                Invalidate();
                var d = PageActivated;
                if (d != null) d(h);
            }
            base.OnMouseClick(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Font f = UiTheme.Font(10f, false);
            Font fb = UiTheme.Font(10f, true);
            for (int i = 0; i < _titles.Length; i++)
            {
                var r = ItemRect(i);
                bool act = i == _active;
                if (act)
                {
                    using (var p = UiTheme.RoundRect(r, 10))
                    using (var b = new SolidBrush(UiTheme.AccentSoft))
                        e.Graphics.FillPath(b, p);
                }
                else if (i == _hover)
                {
                    using (var p = UiTheme.RoundRect(r, 10))
                    using (var b = new SolidBrush(UiTheme.RowHover))
                        e.Graphics.FillPath(b, p);
                }
                var iconR = new Rectangle(r.X + 12, r.Y + (r.Height - 18) / 2,
                    18, 18);
                Glyphs.Draw(e.Graphics, _icons[i], iconR, act ? UiTheme.Accent : UiTheme.Dim);
                var textR = new Rectangle(iconR.Right + 10, r.Y, r.Width - iconR.Width - 26, r.Height);
                TextRenderer.DrawText(e.Graphics, _titles[i], act ? fb : f, textR, act ? UiTheme.Text : UiTheme.Dim,
                    TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
            }
        }
    }
}
