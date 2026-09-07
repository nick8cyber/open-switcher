using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace OpenSwitcher.Core
{
    /// <summary>
    /// Сердце программы: низкоуровневые хуки, буфер слова, детект неверной раскладки,
    /// исполнение исправлений (по Enter, по концу слова, хоткеями, double-Shift).
    /// </summary>
    public class Engine : IDisposable
    {
        public Settings S;

        private Native.HookProc _kbProc;
        private Native.HookProc _mouseProc;
        private Native.WinEventProc _winProc;
        private IntPtr _kbHook = IntPtr.Zero;
        private IntPtr _mouseHook = IntPtr.Zero;
        private IntPtr _winHook = IntPtr.Zero;

        private readonly WordBuffer _buf = new WordBuffer();
        private List<KeyRec> _lastWord = new List<KeyRec>();
        private int _lastWordAt;             // тикант снимка последнего слова

        private int _suppressUntil;          // тикант до которого игнорируем собственную инжекцию
        private int _lastShiftDown;
        private bool _anyKeySinceShift;
        private bool _shiftAlone;            // (не используется, оставлено для совместимости)
        private int _tapVk;                  // клавиша, чей «тап» отслеживается
        private int _tapTarget;              // 0 = РУС, 1 = ENG
        private int _tapDownTick;
        private bool _tapAlone;              // между нажатием и отпусканием не было других клавиш
        private bool _autoLocked;            // юзер сам выбрал раскладку — автодетект молчит до новой сессии
        private IntPtr _expectedHkl;         // раскладка, которую ожидаем в переднем окне
        private bool _expectedValid;

        // состояние переднего окна
        private IntPtr _fgHwnd;
        private IntPtr _fgHkl;
        private IntPtr _fgFocus;
        private string _fgProc = "";
        private readonly Dictionary<uint, string> _procCache = new Dictionary<uint, string>();

        // дескрипторы собственного UI (настройки): исключаем автоисправление вне "песочницы"
        public IntPtr UiFormHandle;
        public IntPtr SandboxHandle;

        /// <summary>(старый текст, новый текст) — для всплывашки.</summary>
        public event Action<string, string> Converted;
        /// <summary>Информационное сообщение без пары "было/стало".</summary>
        public event Action<string> Info;
        /// <summary>Настройки применились (обновить трей и т.п.).</summary>
        public event Action SettingsApplied;

        public Engine(Settings settings)
        {
            S = settings;
            _kbProc = KeyboardProc;
            _mouseProc = MouseProc;
            _winProc = WinEventProcHandler;

            _kbHook = Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, _kbProc, IntPtr.Zero, 0);
            _mouseHook = Native.SetWindowsHookEx(Native.WH_MOUSE_LL, _mouseProc, IntPtr.Zero, 0);
            _winHook = Native.SetWinEventHook(Native.EVENT_SYSTEM_FOREGROUND, Native.EVENT_SYSTEM_FOREGROUND,
                IntPtr.Zero, _winProc, 0, 0, Native.WINEVENT_OUTOFCONTEXT);
            UpdateForeground();
        }

        public void Apply(Settings settings)
        {
            S = settings;
            if (SettingsApplied != null) SettingsApplied();
        }

        public void Dispose()
        {
            if (_kbHook != IntPtr.Zero) Native.UnhookWindowsHookEx(_kbHook);
            if (_mouseHook != IntPtr.Zero) Native.UnhookWindowsHookEx(_mouseHook);
            if (_winHook != IntPtr.Zero) Native.UnhookWinEvent(_winHook);
            _kbHook = _mouseHook = _winHook = IntPtr.Zero;
        }

        // ------------------------------------------------------------------Foreground

        private void UpdateForeground()
        {
            _fgHwnd = Native.GetForegroundWindow();
            uint pid;
            uint tid = Native.GetWindowThreadProcessId(_fgHwnd, out pid);
            _fgHkl = tid != 0 ? Native.GetKeyboardLayout(tid) : Native.GetKeyboardLayout(0);
            _fgFocus = IntPtr.Zero;
            var gti = new Native.GUITHREADINFO();
            gti.cbSize = System.Runtime.InteropServices.Marshal.SizeOf(typeof(Native.GUITHREADINFO));
            if (tid != 0 && Native.GetGUIThreadInfo(tid, ref gti))
            {
                _fgFocus = gti.hwndFocus != IntPtr.Zero ? gti.hwndFocus : gti.hwndActive;
            }
            if (!_procCache.TryGetValue(pid, out _fgProc) || string.IsNullOrEmpty(_fgProc))
            {
                _fgProc = ProcessNameOf(pid);
                if (!string.IsNullOrEmpty(_fgProc)) _procCache[pid] = _fgProc;
            }

            // раскладка поменялась вне движка (Alt+Shift / Win+Space / тап Shift) —
            // юзер задал язык явно: запираем автодетект до новой сессии ввода
            if (_expectedValid && _fgHkl != _expectedHkl && S.LockAutoAfterManualSwitch)
                _autoLocked = true;
            _expectedHkl = _fgHkl;
            _expectedValid = true;
        }

        /// <summary>Зафиксировать ожидаемую раскладку после собственной смены (чтобы не ложного лока).</summary>
        private void ExpectLayout(IntPtr hkl)
        {
            _expectedHkl = hkl;
            _expectedValid = true;
        }

        private static string ProcessNameOf(uint pid)
        {
            if (pid == 0) return "";
            IntPtr h = Native.OpenProcess(Native.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (h == IntPtr.Zero) return "";
            try
            {
                var sb = new StringBuilder(1024);
                int size = sb.Capacity;
                if (Native.QueryFullProcessImageName(h, 0, sb, ref size))
                {
                    string path = sb.ToString();
                    int slash = Math.Max(path.LastIndexOf('\\'), path.LastIndexOf('/'));
                    return slash >= 0 ? path.Substring(slash + 1).ToLowerInvariant() : path.ToLowerInvariant();
                }
            }
            catch (Exception) { }
            finally { Native.CloseHandle(h); }
            return "";
        }

        private bool IsExcludedHere()
        {
            // собственное окно настроек: исключаем всё, кроме "песочницы"
            if (UiFormHandle != IntPtr.Zero && _fgHwnd == UiFormHandle)
                return _fgFocus != SandboxHandle || SandboxHandle == IntPtr.Zero;
            string excl = S.Exclusions;
            if (string.IsNullOrEmpty(excl) || string.IsNullOrEmpty(_fgProc)) return false;
            foreach (string part in excl.ToLowerInvariant().Split(new[] { ',', ';' }))
            {
                string p = part.Trim();
                if (p.Length == 0) continue;
                if (_fgProc == p || _fgProc.EndsWith(p) || _fgProc.Contains(p)) return true;
            }
            return false;
        }

        // ------------------------------------------------------------------ Hook

        private IntPtr KeyboardProc(int code, IntPtr wParam, IntPtr lParam)
        {
            if (code >= 0)
            {
                int msg = wParam.ToInt32();
                if (msg == Native.WM_KEYDOWN || msg == Native.WM_SYSKEYDOWN)
                {
                    if (Environment.TickCount >= _suppressUntil)
                    {
                        var k = (Native.KBDLLHOOKSTRUCT)System.Runtime.InteropServices.Marshal.PtrToStructure(
                            lParam, typeof(Native.KBDLLHOOKSTRUCT));
                        if (!OnKeyDown(k)) return IntPtr.Zero; // проглотить
                    }
                }
                else if (msg == Native.WM_KEYUP || msg == Native.WM_SYSKEYUP)
                {
                    if (Environment.TickCount >= _suppressUntil)
                    {
                        var k = (Native.KBDLLHOOKSTRUCT)System.Runtime.InteropServices.Marshal.PtrToStructure(
                            lParam, typeof(Native.KBDLLHOOKSTRUCT));
                        if (!OnKeyUp(k)) return IntPtr.Zero; // проглотить (Caps Lock и т.п.)
                    }
                }
            }
            return Native.CallNextHookEx(_kbHook, code, wParam, lParam);
        }

        // OnKeyDown возвращает true — пропустить клавишу дальше, false — проглотить.

        private bool OnKeyDown(Native.KBDLLHOOKSTRUCT k)
        {
            // чужая автоматика (RDP, макросы) — не реагируем
            if ((k.flags & 0x10) != 0) return true; // LLKHF_INJECTED

            UpdateForeground();
            int vk = (int)(k.vkCode & 0xFF);

            bool shift = (Native.GetAsyncKeyState(0x10) & 0x8000) != 0;
            bool ctrl = (Native.GetAsyncKeyState(0x11) & 0x8000) != 0;
            bool alt = (k.flags & Native.LLKHF_ALTDOWN) != 0 || (Native.GetAsyncKeyState(0x12) & 0x8000) != 0;
            bool win = (Native.GetAsyncKeyState(0x5B) & 0x8000) != 0 || (Native.GetAsyncKeyState(0x5C) & 0x8000) != 0;
            bool caps = (Native.GetAsyncKeyState(0x14) & 0x0001) != 0;

            if (vk == 0xA0 || vk == 0xA1) // левый / правый Shift
            {
                int now = Environment.TickCount;
                // двойной Shift — смена на другую раскладку (опционально)
                if (!_anyKeySinceShift && unchecked(now - _lastShiftDown) >= 0 &&
                    unchecked(now - _lastShiftDown) < 400 && S.DoubleShiftSwitch && !S.Paused)
                {
                    _lastShiftDown = 0;
                    _anyKeySinceShift = true;
                    _tapAlone = false;
                    UpdateForeground();
                    if (!IsExcludedHere()) SwitchToOtherLayout();
                    return true;
                }
                _lastShiftDown = now;
                _anyKeySinceShift = false;
                if ((S.HotRuMods == 0 && S.HotRuVk == vk) || (S.HotEnMods == 0 && S.HotEnVk == vk))
                {
                    _tapVk = vk;
                    _tapTarget = S.HotRuVk == vk ? 0 : 1;
                    _tapDownTick = now;
                    _tapAlone = true;
                }
                return true;
            }

            _anyKeySinceShift = true;
            _tapAlone = false;

            if (vk == 0x11 || vk == 0x12 || vk == 0x5B || vk == 0x5C || vk == 0xA2 || vk == 0xA4)
            {
                _buf.Clear();
                return true;
            }

            // пауза автоперевода (Break по умолчанию) — глобальный тумблер, работает в любом окне
            if (S.HotAutoToggleVk != 0 && MatchHot(vk, ctrl, shift, alt, win, S.HotAutoToggleVk, S.HotAutoToggleMods))
            {
                ToggleAuto();
                return false;
            }

            if (IsExcludedHere()) { _buf.Clear(); return true; }

            // хоткеи: MatchHot сверяет и vk, и все модификаторы, так что
            // случайное срабатывание при обычной печати исключено
            if (S.HotFixWordVk != 0 && MatchHot(vk, ctrl, shift, alt, win, S.HotFixWordVk, S.HotFixWordMods))
            {
                DoFixLastWord();
                return false;
            }
            if (S.HotFixSelVk != 0 && MatchHot(vk, ctrl, shift, alt, win, S.HotFixSelVk, S.HotFixSelMods))
            {
                DoFixSelection();
                return false;
            }

            // клавиши раскладок: тап-режим (Caps Lock, Scroll Lock, Insert, F-клавиши)
            if ((S.HotRuMods == 0 && S.HotRuVk != 0 && vk == S.HotRuVk) ||
                (S.HotEnMods == 0 && S.HotEnVk != 0 && vk == S.HotEnVk))
            {
                _tapVk = vk;
                _tapTarget = (S.HotRuMods == 0 && vk == S.HotRuVk) ? 0 : 1;
                _tapDownTick = Environment.TickCount;
                _tapAlone = true;
                return !IsSwallowableTap(vk); // не-модификаторы глотаем, чтобы не делали своего
            }

            // клавиши раскладок: сочетания с модификаторами — срабатывают по нажатию
            if (S.HotRuMods != 0 && S.HotRuVk != 0 && MatchHot(vk, ctrl, shift, alt, win, S.HotRuVk, S.HotRuMods))
            {
                SwitchToLanguage(0);
                return false;
            }
            if (S.HotEnMods != 0 && S.HotEnVk != 0 && MatchHot(vk, ctrl, shift, alt, win, S.HotEnVk, S.HotEnMods))
            {
                SwitchToLanguage(1);
                return false;
            }

            if (vk >= 0x41 && vk <= 0x5A)
            {
                _buf.Push(new KeyRec(vk, shift, caps));
                return true;
            }

            if (vk == 0x08) { _buf.Pop(); return true; } // Backspace

            if (vk == 0x0D) // Enter — проверка последнего слова перед отправкой (фича Punto)
            {
                // ТОЛЬКО голый Enter: Shift/Ctrl/Alt+Enter (перенос строки, команды) не трогаем
                bool modified = ctrl || alt || win || shift;
                bool converted = false;
                List<KeyRec> word = _buf.Snapshot();
                if (word.Count > 0 && !modified)
                {
                    _lastWord = word;          // слово запомнится и без проверки (для Pause)
                    _lastWordAt = Environment.TickCount;
                }
                if (!modified && S.FixOnEnter && !S.Paused)
                    converted = TryConvertWord(word, true, false);
                // ВАЖНО: Enter лок НЕ снимает — в длинном тексте энтеры подряд,
                // а сессия ввода (окно) не сменилась. Лок держится до смены окна.
                _buf.Clear();
                return !converted; // проглотить Enter, если конвертнули (перешлём свой)
            }

            if (vk == 0x09 || vk == 0x1B) { _buf.Clear(); return true; } // Tab / Esc

            if (vk == 0x20 || (vk >= 0x30 && vk <= 0x39) ||
                (vk >= 0xBA && vk <= 0xC0) || (vk >= 0xDB && vk <= 0xDF)) // пробел, цифры, OEM-знаки
            {
                // при зажатых модификаторах (шорткаты) не вмешиваемся
                bool modified = ctrl || alt || win || shift;
                if (!modified && S.AutoConvertOnWordEnd && !S.Paused && _buf.Count > 0)
                {
                    List<KeyRec> word = _buf.Snapshot();
                    TryConvertWord(word, false, false);
                }
                if (_buf.Count > 0 && !modified)
                {
                    _lastWord = _buf.Snapshot();
                    _lastWordAt = Environment.TickCount;
                }
                _buf.Clear();
                return true;
            }

            if ((vk >= 0x70 && vk <= 0x87) || (vk >= 0x21 && vk <= 0x28) ||
                vk == 0x2D || vk == 0x2E) // F-клавиши, навигация, Ins/Del
            {
                _buf.Clear();
                return true;
            }

            return true;
        }

        private IntPtr MouseProc(int code, IntPtr wParam, IntPtr lParam)
        {
            if (code >= 0)
            {
                int msg = wParam.ToInt32();
                if (msg == Native.WM_LBUTTONDOWN || msg == Native.WM_RBUTTONDOWN)
                {
                    if (_buf.Count > 0) _lastWord = _buf.Snapshot();
                    _buf.Clear();
                    _tapAlone = false; // клик между нажатием и отпусканием отменяет тап
                }
            }
            return Native.CallNextHookEx(_mouseHook, code, wParam, lParam);
        }

        private void WinEventProcHandler(IntPtr hHook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
        {
            if (_buf.Count > 0) _lastWord = _buf.Snapshot();
            _buf.Clear();
            _anyKeySinceShift = true;
            _tapAlone = false;
            // новое окно — новая сессия ввода: лок снимается
            _autoLocked = false;
            _expectedValid = false;
            UpdateForeground();
        }

        /// <summary>Не-модификаторные тап-клавиши глотаются (Caps Lock не включает капс и т.п.).</summary>
        private static bool IsSwallowableTap(int vk)
        {
            return vk != 0xA0 && vk != 0xA1 && vk != 0xA2 && vk != 0xA3 && vk != 0xA4 && vk != 0xA5;
        }

        /// <summary>KEYUP: завершение тапа клавиши раскладки. Возвращает false, если событие надо проглотить.</summary>
        private bool OnKeyUp(Native.KBDLLHOOKSTRUCT k)
        {
            int vk = (int)(k.vkCode & 0xFF);
            if (_tapVk == 0 || vk != _tapVk) return true;

            bool swallow = IsSwallowableTap(vk);
            int now = Environment.TickCount;
            bool alone = _tapAlone && unchecked(now - _tapDownTick) >= 0 && unchecked(now - _tapDownTick) < 700;
            _tapAlone = false;
            if (alone && !S.Paused)
            {
                UpdateForeground();
                if (!IsExcludedHere()) SwitchToLanguage(_tapTarget);
            }
            return !swallow;
        }

        /// <summary>Переключить раскладку переднего окна на конкретный язык (0 ру, 1 эн).</summary>
        public void SwitchToLanguage(int lang)
        {
            UpdateForeground();
            IntPtr target = LayoutService.FindLayoutByLang(lang);
            if (target == IntPtr.Zero)
            {
                FireInfo(lang == 0 ? "Русская раскладка не найдена" : "Английская раскладка не найдена");
                return;
            }
            LayoutService.SwitchForegroundTo(_fgHwnd, target);
            ExpectLayout(target);
            // юзер выбрал язык явно — автодетект молчит до смены окна / Enter
            if (S.LockAutoAfterManualSwitch) _autoLocked = true;
            FireInfo(lang == 0 ? "РУС" : "ENG");
        }

        private static bool MatchHot(int vkEvent, bool ctrl, bool shift, bool alt, bool win, int vkHot, int modsHot)
        {
            if (vkHot == 0 || vkEvent != vkHot) return false;
            if (((modsHot & HK.CTRL) != 0) != ctrl) return false;
            if (((modsHot & HK.SHIFT) != 0) != shift) return false;
            if (((modsHot & HK.ALT) != 0) != alt) return false;
            if (((modsHot & HK.WIN) != 0) != win) return false;
            return true;
        }

        // ------------------------------------------------------------------ Действия

        /// <summary>Попытка конвертации слова; manual=true — вызов явным хоткеем (игнорирует лок).</summary>
        private bool TryConvertWord(List<KeyRec> word, bool viaEnter, bool manual)
        {
            if (S.Paused || word == null || word.Count < S.MinWordLen) return false;
            if (!manual && S.LockAutoAfterManualSwitch && _autoLocked) return false;
            UpdateForeground();
            if (IsExcludedHere()) return false;

            List<IntPtr> layouts = LayoutService.GetLayouts();
            if (layouts.Count < 2) return false;
            List<LayoutCandidate> cands = LayoutService.RenderAll(word, layouts);

            LayoutCandidate cur = null;
            foreach (LayoutCandidate c in cands) if (c.Hkl == _fgHkl) { cur = c; break; }
            if (cur == null || cur.Lang < 0) return false;

            LayoutCandidate best = null;
            foreach (LayoutCandidate c in cands)
            {
                if (c.Hkl == _fgHkl || c.Lang < 0) continue;
                if (best == null || c.Score > best.Score) best = c;
            }
            if (best == null) return false;

            if (!LanguageTables.ShouldConvert(cur.Text, cur.Lang, cur.Score,
                                              best.Text, best.Lang, best.Score, S.Sensitivity))
                return false;

            _lastWord = word;

            Suppress(600);
            TextConverter.SendBackspaces(word.Count);
            TextConverter.SendUnicode(best.Text);
            if (viaEnter) TextConverter.SendKey(0x0D, false); // пересылаем проглоченный Enter
            LayoutService.SwitchForegroundTo(_fgHwnd, best.Hkl);
            ExpectLayout(best.Hkl);
            FireConverted(cur.Text, best.Text);
            return true;
        }

        /// <summary>Глобальная пауза автоперевода (как Break в Caramba).</summary>
        public void ToggleAuto()
        {
            S.Paused = !S.Paused;
            SettingsStore.Save(S);
            if (!S.Paused) _autoLocked = false; // с чистого листа
            Apply(S); // обновит тултип трея
            FireInfo(S.Paused ? "Автоисправление выключено" : "Автоисправление включено");
        }

        public void DoFixLastWord()
        {
            if (S.Paused) return;
            UpdateForeground();
            if (IsExcludedHere()) return;
            if (_lastWord.Count == 0)
            {
                FireInfo("Нет слова для исправления");
                return;
            }
            // протухший снимок конвертировать опасно: каретка уже в другом месте,
            // backspace'ы сотрут чужой текст
            int age = unchecked(Environment.TickCount - _lastWordAt);
            if (age < 0 || age > 3000)
            {
                FireInfo("Слово уже устарело");
                return;
            }
            var word = new List<KeyRec>(_lastWord);
            if (!TryConvertWord(word, false, true))
                FireInfo("Раскладка уже верная");
        }

        /// <summary>Конвертация по готовому буферу (для хоткея последнего слова).</summary>
        private bool TryConvertWordDirect(List<KeyRec> word)
        {
            return TryConvertWord(word, false, true);
        }

        public void DoFixSelection()
        {
            if (S.Paused) return;
            UpdateForeground();
            if (IsExcludedHere()) return;

            string old = TextConverter.GetClipboardTextOnce();
            Suppress(1600);
            TextConverter.SendCombo(0x11, 0x43); // Ctrl+C

            string text = null;
            for (int i = 0; i < 45; i++)
            {
                Thread.Sleep(14);
                text = TextConverter.GetClipboardTextOnce();
                if (!string.IsNullOrEmpty(text)) break;
            }
            if (string.IsNullOrEmpty(text))
            {
                FireInfo("Нет выделенного текста");
                return;
            }

            int lang = LanguageTables.LangOf(LanguageTables.LettersOnly(text));
            if (lang < 0)
            {
                FireInfo("Не удалось определить язык");
                return;
            }
            string converted = CharMaps.MapText(text, lang == 1);
            TextConverter.SetClipboardTextSafe(converted);
            TextConverter.SendCombo(0x11, 0x56); // Ctrl+V

            IntPtr target = LayoutService.FindLayoutByLang(lang == 1 ? 0 : 1);
            if (target != IntPtr.Zero)
            {
                LayoutService.SwitchForegroundTo(_fgHwnd, target);
                ExpectLayout(target);
            }
            if (S.LockAutoAfterManualSwitch) _autoLocked = true; // юзер руками правил текст

            if (S.RestoreClipboard) ScheduleClipboardRestore(text);

            if (converted != text) FireConverted(text, converted);
            else FireInfo("Раскладка уже верная");
        }

        private System.Windows.Forms.Timer _clipTimer;

        private void ScheduleClipboardRestore(string original)
        {
            if (_clipTimer != null) { _clipTimer.Stop(); _clipTimer.Dispose(); }
            string text = original;
            _clipTimer = new System.Windows.Forms.Timer();
            _clipTimer.Interval = 800;
            _clipTimer.Tick += delegate
            {
                _clipTimer.Stop();
                _clipTimer.Dispose();
                _clipTimer = null;
                Suppress(300);
                TextConverter.SetClipboardTextSafe(text);
            };
            _clipTimer.Start();
        }

        public void SwitchToOtherLayout()
        {
            UpdateForeground();
            List<IntPtr> layouts = LayoutService.GetLayouts();
            IntPtr other = IntPtr.Zero;
            foreach (IntPtr hkl in layouts)
                if (hkl != _fgHkl) { other = hkl; break; }
            if (other == IntPtr.Zero) return;

            // имя целевой раскладки для попапа
            var probe = new List<KeyRec>();
            probe.Add(new KeyRec(0x41, false, false));
            string sample = LayoutService.Render(other, probe);
            string name = LanguageTables.LangOf(sample) == 0 ? "РУС" : "ENG";
            LayoutService.SwitchForegroundTo(_fgHwnd, other);
            ExpectLayout(other);
            if (S.LockAutoAfterManualSwitch) _autoLocked = true;
            FireInfo("Раскладка: " + name);
        }

        // ------------------------------------------------------------------ Вспомогательное

        private void Suppress(int ms)
        {
            int until = Environment.TickCount + ms;
            if (until > _suppressUntil) _suppressUntil = until;
        }

        /// <summary>Точка экрана возле каретки ввода (для всплывашки).</summary>
        public System.Drawing.Point CaretPoint()
        {
            uint pid;
            uint tid = Native.GetWindowThreadProcessId(_fgHwnd, out pid);
            var gti = new Native.GUITHREADINFO();
            gti.cbSize = System.Runtime.InteropServices.Marshal.SizeOf(typeof(Native.GUITHREADINFO));
            if (tid != 0 && Native.GetGUIThreadInfo(tid, ref gti) && gti.hwndCaret != IntPtr.Zero)
            {
                var p = new Native.POINT();
                p.X = gti.rcCaret.Left;
                p.Y = gti.rcCaret.Bottom;
                if (Native.ClientToScreen(gti.hwndCaret, ref p))
                    return new System.Drawing.Point(p.X, p.Y);
            }
            if (gti.hwndFocus != IntPtr.Zero)
            {
                var p2 = new Native.POINT();
                p2.X = gti.rcCaret.Left;
                p2.Y = gti.rcCaret.Bottom;
                if (Native.ClientToScreen(gti.hwndFocus, ref p2))
                    return new System.Drawing.Point(p2.X, p2.Y);
            }
            return Cursor.Position;
        }

        private void FireConverted(string oldText, string newText)
        {
            var d = Converted;
            if (d != null) d(oldText, newText);
        }

        private void FireInfo(string msg)
        {
            var d = Info;
            if (d != null) d(msg);
        }
    }
}
