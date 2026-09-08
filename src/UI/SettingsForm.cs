using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using OpenSwitcher.Core;

namespace OpenSwitcher.UI
{
    /// <summary>Окно настроек: сайдбар + страницы, градиентный статус, тёмная/светлая тема.</summary>
    public class SettingsForm : Form
    {
        private readonly Engine _engine;

        private const int TitleH = 48;
        private const int SidebarW = 208;
        private const int FormW = 880;
        private const int FormH = 660;
        private const int FooterH = 52;

        private int ClientHeight { get { return ClientSize.Height; } }

        private SidebarPanel _sidebar;
        private Panel _pagesHost;
        private StatusHero _hero;
        private Panel[] _pages;
        private PageCard[] _cards;

        private ToggleSwitch _tEnter, _tAuto, _tDouble, _tPopup, _tClip, _tRun, _tLock;
        private HotkeyBox _hkWord, _hkSel, _hkRu, _hkEn, _hkAuto, _hkUndo;
        private NumBox _numLen;
        private ChoiceSeg _segSens, _segTheme;
        private TextBox _tbExcl, _tbSandbox;

        public IntPtr SandboxHandle
        {
            get { return _tbSandbox != null && _tbSandbox.IsHandleCreated ? _tbSandbox.Handle : IntPtr.Zero; }
        }

        public SettingsForm(Engine engine)
        {
            _engine = engine;
            Text = "OpenSwitcher";
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.CenterScreen;
            ShowInTaskbar = true;
            BackColor = UiTheme.Bg;
            Font = UiTheme.Font(10f, false);
            KeyPreview = true;
            DoubleBuffered = true;
            AutoScaleMode = AutoScaleMode.None; // масштабируем вручную в OnLoad

            int waH = Screen.PrimaryScreen.WorkingArea.Height - 40;
            ClientSize = new Size(FormW, Math.Min(FormH, Math.Max(460, waH)));

            BuildUi();
            UiTheme.Changed += OnThemeChanged;
            _engine.SettingsApplied += OnEngineSettingsApplied;
        }

        private void OnEngineSettingsApplied()
        {
            // Break/трей-пауза изменили состояние — синхронизируем статус-карточку
            if (_hero != null) _hero.SetPaused(_engine.S.Paused);
        }

        // ---------------------------------------------------------------- построение

        private void BuildUi()
        {
            int contentTop = TitleH + 12;
            int footerTop = ClientHeight - FooterH;

            // --- сайдбар
            _sidebar = new SidebarPanel(
                new[] { "Основное", "Горячие клавиши", "Внешний вид", "Система", "Исключения" },
                new[] { "fix", "keys", "look", "sys", "block" }, 0);
            _sidebar.SetBounds(0, TitleH, SidebarW, footerTop - TitleH);
            _sidebar.PageActivated += ActivatePage;
            Controls.Add(_sidebar);

            // --- хост страниц
            _pagesHost = new Panel();
            _pagesHost.SetBounds(SidebarW + 16, contentTop,
                FormW - SidebarW - 32, footerTop - contentTop - 4);
            _pagesHost.BackColor = UiTheme.Bg;
            Controls.Add(_pagesHost);

            int w = _pagesHost.Width;

            // --- герой-статус
            _hero = new StatusHero();
            _hero.SetBounds(0, 0, w, 64);
            _hero.SetPaused(_engine.S.Paused);
            _hero.PauseToggled += delegate
            {
                _engine.S.Paused = !_engine.S.Paused;
                SettingsStore.Save(_engine.S);
                _engine.Apply(_engine.S); // обновит трей
            };
            _pagesHost.Controls.Add(_hero);

            int pageY = 78;

            // ================= страница «Основное»
            Panel pMain = MkPage(w);
            PageHeader(pMain, "Основное", "Автоисправление неверной раскладки при вводе");
            int y = 46;

            PageCard c1 = MkCard(pMain, y);
            _tAuto = new ToggleSwitch();
            _tAuto.Checked = _engine.S.AutoConvertOnWordEnd;
            c1.AddRow("Автоисправление по пробелу и знакам",
                "Проверять слово в конце ввода: пробел, запятая, точка…", _tAuto, 56);
            _tEnter = new ToggleSwitch();            _tEnter.Checked = _engine.S.FixOnEnter;
            c1.AddRow("Исправлять слово перед Enter",
                "Enter перехватывается, слово правится до отправки", _tEnter, 56);
            _tLock = new ToggleSwitch();
            _tLock.Checked = _engine.S.LockAutoAfterManualSwitch;
            c1.AddRow("Не трогать после ручного выбора языка",
                "Автодетект молчит до смены окна или приложения", _tLock, 56);
            _numLen = new NumBox();
            _numLen.Min = 2; _numLen.Max = 8; _numLen.Value = _engine.S.MinWordLen;
            c1.AddRow("Минимальная длина слова", null, _numLen, 44);
            _segSens = new ChoiceSeg();
            _segSens.Items = new[] { "Низкая", "Средняя", "Высокая" };
            _segSens.SelectedIndex = _engine.S.Sensitivity <= 0.85 ? 0 : (_engine.S.Sensitivity >= 1.25 ? 2 : 1);
            c1.AddRow("Как часто вмешиваться", null, _segSens, 44);

            y = c1.Bottom + 12;
            PageCard c2 = MkCard(pMain, y);
            _tbSandbox = DarkTextbox("", false, 24);
            _tbSandbox.HandleCreated += delegate { if (_engine != null) _engine.SandboxHandle = _tbSandbox.Handle; };
            c2.AddRow("Попробуйте", "Напечатайте ghbdtn и пробел — исправится сразу", null, 40);
            InputPanel sand = new InputPanel(_tbSandbox, 36);
            sand.SetBounds(18, 56, c2.Width - 36, 36);
            c2.Controls.Add(sand);
            c2.Height = 102;

            // ================= страница «Горячие клавиши»
            Panel pKeys = MkPage(w);
            PageHeader(pKeys, "Горячие клавиши", "Кликните по полю и нажмите сочетание; Backspace — очистить");
            y = 46;
            PageCard c3 = MkCard(pKeys, y);
            _hkRu = new HotkeyBox();
            _hkRu.Vk = _engine.S.HotRuVk;
            _hkRu.Mods = _engine.S.HotRuMods;
            c3.AddRow("Русская раскладка", "Тап Caps Lock / левого Shift / F9 — или сочетание с Ctrl", _hkRu, 52);
            _hkEn = new HotkeyBox();
            _hkEn.Vk = _engine.S.HotEnVk;
            _hkEn.Mods = _engine.S.HotEnMods;
            c3.AddRow("Английская раскладка", "Тап правого Shift или другая своя клавиша", _hkEn, 52);
            _hkWord = new HotkeyBox();
            _hkWord.Vk = _engine.S.HotFixWordVk;
            _hkWord.Mods = _engine.S.HotFixWordMods;
            c3.AddRow("Исправить последнее слово", "Сработает даже после пробела или Enter", _hkWord, 52);
            _hkSel = new HotkeyBox();
            _hkSel.Vk = _engine.S.HotFixSelVk;
            _hkSel.Mods = _engine.S.HotFixSelMods;
            c3.AddRow("Исправить выделенный текст", "Конвертирует выделение и переключает раскладку", _hkSel, 52);
            _tDouble = new ToggleSwitch();
            _tDouble.Checked = _engine.S.DoubleShiftSwitch;
            c3.AddRow("Двойной Shift — сменить раскладку", "Двойной тап любого Shift переключает на другую", _tDouble, 44);
            _hkUndo = new HotkeyBox();
            _hkUndo.Vk = _engine.S.HotUndoVk;
            _hkUndo.Mods = _engine.S.HotUndoMods;
            c3.AddRow("Отменить последнюю автозамену", "Вернуть слово и раскладку, которые были до автозамены", _hkUndo, 52);
            _hkAuto = new HotkeyBox();
            _hkAuto.Vk = _engine.S.HotAutoToggleVk;
            _hkAuto.Mods = _engine.S.HotAutoToggleMods;
            c3.AddRow("Пауза автоперевода", "Глобальный тумблер; по умолчанию не назначена", _hkAuto, 52);

            // ================= страница «Внешний вид»
            Panel pLook = MkPage(w);
            PageHeader(pLook, "Внешний вид", "Тема и уведомления");
            y = 52;
            PageCard c4 = MkCard(pLook, y);
            _segTheme = new ChoiceSeg();
            _segTheme.Items = new[] { "Системная", "Светлая", "Тёмная" };
            _segTheme.SelectedIndex = _engine.S.ThemeMode;
            _segTheme.SelectedChanged += delegate
            {
                UiTheme.ApplyMode(_segTheme.SelectedIndex);
                _engine.S.ThemeMode = _segTheme.SelectedIndex;
            };
            c4.AddRow("Тема оформления", null, _segTheme, 44);
            _tPopup = new ToggleSwitch();
            _tPopup.Checked = _engine.S.ShowPopup;
            c4.AddRow("Показывать подсказку при исправлении",
                "Плашка «ghbdtn → привет» возле каретки", _tPopup, 56);

            // ================= страница «Система»
            Panel pSys = MkPage(w);
            PageHeader(pSys, "Система", "Буфер обмена и запуск");
            y = 52;
            PageCard c5 = MkCard(pSys, y);
            _tClip = new ToggleSwitch();
            _tClip.Checked = _engine.S.RestoreClipboard;
            c5.AddRow("Восстанавливать буфер обмена", "Вернуть прежнее содержимое после конвертации выделения", _tClip, 56);
            _tRun = new ToggleSwitch();
            _tRun.Checked = _engine.S.StartWithWindows;
            c5.AddRow("Запускать при входе в Windows", null, _tRun, 44);

            // ================= страница «Исключения»
            Panel pEx = MkPage(w);
            PageHeader(pEx, "Исключения", "Программы, где исправление выключено");
            y = 52;
            PageCard c6 = MkCard(pEx, y);
            _tbExcl = DarkTextbox(_engine.S.Exclusions, true, 56);
            c6.AddRow("Не исправлять в", "Имена процессов через запятую: cmd.exe, far.exe", null, 40);
            InputPanel ex = new InputPanel(_tbExcl, 72);
            ex.SetBounds(18, 56, c6.Width - 36, 72);
            c6.Controls.Add(ex);
            c6.Height = 138;

            _pages = new[] { pMain, pKeys, pLook, pSys, pEx };
            ActivatePage(0);

            // --- кнопки заголовка
            TitleButton btnMin = new TitleButton();
            btnMin.Kind = "min";
            btnMin.Location = new Point(FormW - TitleButtonSize() * 2, 4);
            btnMin.Click += delegate { WindowState = FormWindowState.Minimized; };
            Controls.Add(btnMin);

            TitleButton btnClose = new TitleButton();
            btnClose.Kind = "close";
            btnClose.Location = new Point(FormW - TitleButtonSize(), 4);
            btnClose.Click += delegate { Close(); };
            Controls.Add(btnClose);

            // --- футер
            RoundedButton btnReset = new RoundedButton();
            btnReset.Accent = false;
            btnReset.Text = "Сбросить";
            btnReset.Size = new Size(104, 38);
            btnReset.Location = new Point(FormW - 16 - 120 * 2 - 10,
                footerTop + (FooterH - btnReset.Height) / 2);
            btnReset.Click += delegate { LoadFrom(new Settings()); };

            RoundedButton btnSave = new RoundedButton();
            btnSave.Accent = true;
            btnSave.Text = "Сохранить";
            btnSave.Size = new Size(120, 38);
            btnSave.Location = new Point(FormW - 16 - btnSave.Width, btnReset.Top);
            btnSave.Click += delegate { Save(); };

            Controls.Add(btnReset);
            Controls.Add(btnSave);
        }

        private int TitleButtonSize()
        {
            return 40;
        }

        private Panel MkPage(int w)
        {
            var p = new Panel();
            p.SetBounds(0, 78, w, Math.Max(420, _pagesHost.Height - 78));
            p.BackColor = UiTheme.Bg;
            p.Visible = false;
            _pagesHost.Controls.Add(p);
            return p;
        }

        private void PageHeader(Panel page, string title, string sub)
        {
            var t = new Label();
            t.Text = title;
            t.Font = UiTheme.Font(15.5f, true);
            t.ForeColor = UiTheme.Text;
            t.BackColor = Color.Transparent;
            t.AutoSize = false;
            t.SetBounds(0, 0, page.Width, 28);
            page.Controls.Add(t);

            var s = new Label();
            s.Text = sub;
            s.Font = UiTheme.Font(9f, false);
            s.ForeColor = UiTheme.Dim;
            s.BackColor = Color.Transparent;
            s.Tag = "dim";
            s.AutoSize = false;
            s.SetBounds(0, 28, page.Width, 18);
            page.Controls.Add(s);
        }

        private PageCard MkCard(Panel page, int y)
        {
            var card = new PageCard();
            card.SetBounds(0, y, page.Width, 10);
            page.Controls.Add(card);
            page.Controls.SetChildIndex(card, page.Controls.Count - 1);
            return card;
        }

        private void ActivatePage(int index)
        {
            if (_pages == null) return;
            for (int i = 0; i < _pages.Length; i++) _pages[i].Visible = i == index;
            _pages[index].BringToFront();
        }

        private TextBox DarkTextbox(string text, bool multiline, int h)
        {
            var tb = new TextBox();
            tb.BorderStyle = BorderStyle.None;
            tb.BackColor = UiTheme.Input;
            tb.ForeColor = UiTheme.Text;
            tb.Font = UiTheme.Font(10.5f, false);
            tb.Multiline = multiline;
            if (multiline) { tb.ScrollBars = ScrollBars.None; tb.Height = h; }
            tb.Text = text;
            return tb;
        }

        // ---------------------------------------------------------------- тема

        public void ApplyTheme()
        {
            BackColor = UiTheme.Bg;
            if (_pagesHost != null) _pagesHost.BackColor = UiTheme.Bg;
            if (_sidebar != null) _sidebar.BackColor = UiTheme.SidebarBg;
            if (_hero != null) _hero.BackColor = UiTheme.Bg;

            if (_pages != null)
            {
                foreach (Panel page in _pages)
                {
                    page.BackColor = UiTheme.Bg;
                    foreach (Control c in page.Controls)
                    {
                        if (c is PageCard)
                        {
                            c.BackColor = UiTheme.Card;
                            foreach (Control ch in c.Controls) ThemeChild(ch);
                        }                        else if (c is Label)
                        {
                            c.ForeColor = (c.Tag as string) == "dim" ? UiTheme.Dim : UiTheme.Text;
                        }
                    }
                }
            }
            foreach (Control c in Controls)
            {
                if (c is Panel || c is SidebarPanel) continue;
                c.BackColor = UiTheme.Bg; // кнопки, крестик, свернуть
            }
            Invalidate(true);
        }

        private static void ThemeChild(Control ch)
        {
            if (ch is InputPanel)
            {
                ch.BackColor = UiTheme.Input;
                foreach (Control t in ch.Controls)
                {
                    t.BackColor = UiTheme.Input;
                    t.ForeColor = UiTheme.Text;
                }
            }
            else if (ch is TextBox)
            {
                ch.BackColor = UiTheme.Input;
                ch.ForeColor = UiTheme.Text;
            }
            else if (ch is Label)
            {
                ch.BackColor = Color.Transparent;
                ch.ForeColor = (ch.Tag as string) == "dim" ? UiTheme.Dim : UiTheme.Text;
            }
            else
            {
                ch.BackColor = UiTheme.Card;
                ch.ForeColor = UiTheme.Text;
            }
        }

        private void OnThemeChanged()
        {
            if (IsHandleCreated && !IsDisposed) ApplyTheme();
        }

        // ---------------------------------------------------------------- данные

        private void LoadFrom(Settings s)
        {
            _tAuto.Checked = s.AutoConvertOnWordEnd;
            _tEnter.Checked = s.FixOnEnter;
            _tLock.Checked = s.LockAutoAfterManualSwitch;
            _numLen.Value = s.MinWordLen;
            _segSens.SelectedIndex = s.Sensitivity <= 0.85 ? 0 : (s.Sensitivity >= 1.25 ? 2 : 1);
            _hkWord.Vk = s.HotFixWordVk; _hkWord.Mods = s.HotFixWordMods;
            _hkSel.Vk = s.HotFixSelVk; _hkSel.Mods = s.HotFixSelMods;
            _hkRu.Vk = s.HotRuVk; _hkRu.Mods = s.HotRuMods;
            _hkEn.Vk = s.HotEnVk; _hkEn.Mods = s.HotEnMods;
            _hkAuto.Vk = s.HotAutoToggleVk; _hkAuto.Mods = s.HotAutoToggleMods;
            _hkUndo.Vk = s.HotUndoVk; _hkUndo.Mods = s.HotUndoMods;
            _tDouble.Checked = s.DoubleShiftSwitch;
            _segTheme.SelectedIndex = s.ThemeMode;
            _tPopup.Checked = s.ShowPopup;
            _tClip.Checked = s.RestoreClipboard;
            _tRun.Checked = s.StartWithWindows;
            _tbExcl.Text = s.Exclusions;
            _hkWord.Invalidate(); _hkSel.Invalidate();
        }

        private void Save()
        {
            var s = new Settings();
            s.AutoConvertOnWordEnd = _tAuto.Checked;
            s.FixOnEnter = _tEnter.Checked;
            s.LockAutoAfterManualSwitch = _tLock.Checked;
            s.MinWordLen = _numLen.Value;
            s.Sensitivity = _segSens.SelectedIndex == 0 ? 0.7 : (_segSens.SelectedIndex == 2 ? 1.5 : 1.0);
            s.HotFixWordVk = _hkWord.Vk;
            s.HotFixWordMods = _hkWord.Mods;
            s.HotFixSelVk = _hkSel.Vk;
            s.HotFixSelMods = _hkSel.Mods;
            s.HotRuVk = _hkRu.Vk;
            s.HotRuMods = _hkRu.Mods;
            s.HotEnVk = _hkEn.Vk;
            s.HotEnMods = _hkEn.Mods;
            s.HotAutoToggleVk = _hkAuto.Vk;
            s.HotAutoToggleMods = _hkAuto.Mods;
            s.HotUndoVk = _hkUndo.Vk;
            s.HotUndoMods = _hkUndo.Mods;
            s.DoubleShiftSwitch = _tDouble.Checked;
            s.ThemeMode = _segTheme.SelectedIndex;
            s.ShowPopup = _tPopup.Checked;
            s.RestoreClipboard = _tClip.Checked;
            s.StartWithWindows = _tRun.Checked;
            s.Exclusions = _tbExcl.Text.Trim();
            s.Paused = _engine.S.Paused;
            SettingsStore.Save(s);
            Program.SetAutostart(s.StartWithWindows);
            _engine.Apply(s);
        }

        // ---------------------------------------------------------------- окно

        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);
            // ручное DPI-масштабирование: раскладка собрана в логических 96dpi-пикселях
            uint dpi = Native.GetDpiForWindow(Handle);
            if (dpi == 0) dpi = (uint)DeviceDpi;
            float k = dpi / 96f;
            if (k > 1.01f)
            {
                Scale(new SizeF(k, k));
                CenterToScreen();
            }
            try
            {
                int pref = 2; // DWMWCP_ROUND
                Native.DwmSetWindowAttribute(Handle, Native.DWMWA_WINDOW_CORNER_PREFERENCE, ref pref, 4);
            }
            catch (Exception) { }
            _engine.UiFormHandle = Handle;
            _engine.SandboxHandle = IntPtr.Zero;
        }

        protected override void OnFormClosed(FormClosedEventArgs e)
        {
            UiTheme.Changed -= OnThemeChanged;
            _engine.SettingsApplied -= OnEngineSettingsApplied;
            _engine.UiFormHandle = IntPtr.Zero;
            _engine.SandboxHandle = IntPtr.Zero;
            base.OnFormClosed(e);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            // Esc во время захвата хоткея отменяет захват, а не закрывает окно
            var hk = ActiveControl as HotkeyBox;
            if (e.KeyCode == Keys.Escape && hk != null && hk.Capturing)
            {
                base.OnKeyDown(e);
                return;
            }
            if (e.KeyCode == Keys.Escape) Close();
            base.OnKeyDown(e);
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left && e.Y < TitleH)
            {
                Native.ReleaseCapture();
                Native.SendMessage(Handle, Native.WM_NCLBUTTONDOWN, (IntPtr)Native.HTCAPTION, IntPtr.Zero);
            }
            base.OnMouseDown(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            // иконка приложения
            var iconR = new Rectangle(12, 13, 22, 22);
            Rectangle gr = new Rectangle(0, 0, Width, Height);
            using (var path = UiTheme.RoundRect(iconR, 7))
            using (var brush = new LinearGradientBrush(gr, UiTheme.Accent, Color.FromArgb(0x7C, 0x5C, 0xFF), 40f))
                e.Graphics.FillPath(brush, path);
            using (var pen = new Pen(Color.White, 1.8f))
            {
                pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
                int x = iconR.X, y = iconR.Y, s = 22;
                e.Graphics.DrawLine(pen, x + 4, y + 8, x + s - 4, y + 8);
                e.Graphics.DrawLine(pen, x + s - 4, y + 8, x + s - 7, y + 5);
                e.Graphics.DrawLine(pen, x + s - 4, y + 8, x + s - 7, y + 11);
                e.Graphics.DrawLine(pen, x + s - 4, y + 14, x + 4, y + 14);
                e.Graphics.DrawLine(pen, x + 4, y + 14, x + 7, y + 11);
                e.Graphics.DrawLine(pen, x + 4, y + 14, x + 7, y + 17);
            }

            TextRenderer.DrawText(e.Graphics, "OpenSwitcher", UiTheme.Font(13f, true),
                new Point(42, 13), UiTheme.Text);

            using (var pen = new Pen(UiTheme.CardBorder))
                e.Graphics.DrawLine(pen, 0, TitleH, Width, TitleH);
            using (var pen = new Pen(UiTheme.CardBorder))
                e.Graphics.DrawLine(pen, SidebarW, TitleH, SidebarW, Height - FooterH);
            using (var pen = new Pen(UiTheme.CardBorder))
                e.Graphics.DrawLine(pen, 0, Height - FooterH, Width, Height - FooterH);

            var verR = new Rectangle(16, Height - FooterH, 300, FooterH);
            TextRenderer.DrawText(e.Graphics, "OpenSwitcher 1.1 · Ru ⇄ En", UiTheme.Font(8.5f, false),
                verR, UiTheme.Dim, TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);

            base.OnPaint(e);
        }
    }
}
