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
        private int _tapVk;                  // клавиша, чей «тап» отслеживается
        private int _tapTarget;              // 0 = РУС, 1 = ENG
        private int _tapDownTick;
        private bool _tapAlone;              // между нажатием и отпусканием не было других клавиш
        private bool _autoLocked;            // юзер сам выбрал раскладку — автодетект молчит до новой сессии
        private IntPtr _expectedHkl;         // раскладка, которую ожидаем в переднем окне
        private IntPtr _expectedHwnd;        // окно, для которого ожидаем _expectedHkl
        private bool _expectedValid;
        private int _expectGraceUntil;       // до этого тиканта смену HKL считаем «догоняет» PostMessage

        // точка отката последней автозамены
        private bool _undoPending;
        private string _undoText = "";       // что было набрано (до замены)
        private int _undoLen;                // длина заменённого текста (сколько стирать)
        private int _undoSep;                // был ли проглочен разделитель (пробел/знак)
        private IntPtr _undoHkl;             // раскладка до замены
        private IntPtr _undoHwnd;            // окно, где была замена
        private int _undoTick;
        private int _keysSinceUndoPoint;     // нажатий после замены: >0 — откат небезопасен
        private List<KeyRec> _undoTail = new List<KeyRec>(); // хвост: что юзер напечатал после замены
        private bool _undoTailBroken;        // хвост испорчен (enter/cap) — откат запрещён

        // компенсация лага смены раскладки после тапа Shift
        private bool _gapActive;
        private IntPtr _gapHkl;              // целевая раскладка
        private readonly List<KeyRec> _gapBuf = new List<KeyRec>();
        private int _gapDeadline;

        // обучение: слова, автозамену которых юзер отменил — больше не конвертировать
        private readonly HashSet<string> _rejected = new HashSet<string>();
        private const int RejectedCap = 1000;

        // обучение в другую сторону: слова, конвертацию которых юзер принял —
        // конвертировать даже при сомнительном скоринге
        private readonly HashSet<string> _accepted = new HashSet<string>();

        private string LearnedPath
        {
            get { return System.IO.Path.Combine(SettingsStore.Dir, "learned.txt"); }
        }

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
            LoadLearned();
        }

        private string AcceptedPath
        {
            get { return System.IO.Path.Combine(SettingsStore.Dir, "accepted.txt"); }
        }

        private void LoadLearned()
        {
            try
            {
                if (System.IO.File.Exists(LearnedPath))
                    foreach (string line in System.IO.File.ReadAllLines(LearnedPath))
                    {
                        string w = line.Trim().ToLowerInvariant();
                        if (w.Length > 0) _rejected.Add(w);
                    }
                if (System.IO.File.Exists(AcceptedPath))
                    foreach (string line in System.IO.File.ReadAllLines(AcceptedPath))
                    {
                        string w = line.Trim().ToLowerInvariant();
                        if (w.Length > 0) _accepted.Add(w);
                    }
            }
            catch (Exception) { }
        }

        private void RememberRejected(string typed)
        {
            try
            {
                if (_rejected.Count >= RejectedCap) return;
                string w = typed.Trim().ToLowerInvariant();
                if (w.Length == 0 || !_rejected.Add(w)) return;
                _accepted.Remove(w);
                System.IO.Directory.CreateDirectory(SettingsStore.Dir);
                System.IO.File.AppendAllText(LearnedPath, w + Environment.NewLine);
            }
            catch (Exception) { }
        }

        private void RememberAccepted(string typed)
        {
            try
            {
                if (_accepted.Count >= RejectedCap) return;
                string w = typed.Trim().ToLowerInvariant();
                if (w.Length == 0 || !_accepted.Add(w)) return;
                _rejected.Remove(w);
                System.IO.Directory.CreateDirectory(SettingsStore.Dir);
                System.IO.File.AppendAllText(AcceptedPath, w + Environment.NewLine);
            }
            catch (Exception) { }
        }

        private void RemoveAccepted(string typed)
        {
            try
            {
                if (!_accepted.Remove(typed)) return;
                var keep = new List<string>(_accepted);
                System.IO.Directory.CreateDirectory(SettingsStore.Dir);
                System.IO.File.WriteAllLines(AcceptedPath, keep.ToArray());
            }
            catch (Exception) { }
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
            // юзер задал язык явно: запираем автодетект до новой сессии ввода.
            // Сверяем только в том же окне, где ожидали раскладку — иначе ложный лок.
            // И только после grace-окна: сразу после нашего PostMessage старый HKL
            // читается ещё мгновение — нельзя лочить, пока «догоняет».
            if (_expectedValid && _fgHwnd == _expectedHwnd && _fgHkl != _expectedHkl
                && S.LockAutoAfterManualSwitch
                && unchecked(Environment.TickCount - _expectGraceUntil) >= 0)
                _autoLocked = true;
            _expectedHkl = _fgHkl;
            _expectedHwnd = _fgHwnd;
            _expectedValid = true;
        }

        /// <summary>Зафиксировать ожидаемую раскладку после собственной смены (чтобы не ложного лока).</summary>
        private void ExpectLayout(IntPtr hkl)
        {
            _expectedHkl = hkl;
            _expectedHwnd = _fgHwnd;
            _expectedValid = true;
            _expectGraceUntil = Environment.TickCount + 1200;
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
                var k = (Native.KBDLLHOOKSTRUCT)System.Runtime.InteropServices.Marshal.PtrToStructure(
                    lParam, typeof(Native.KBDLLHOOKSTRUCT));
                bool injected = (k.flags & 0x10) != 0;

                // guard отката: считаем ЛЮБЫЕ реальные нажатия — даже в suppress-окне
                // после автозамены (иначе Break после быстрой печати портит текст).
                // Исключения: сам хоткей отката И Backspace при ожидающемся откате
                // (иначе Backspace-отмена никогда не срабатывает)
                if (msg == Native.WM_KEYDOWN && !injected && !IsUndoHotkey(k) &&
                    !(_undoPending && (k.vkCode & 0xFF) == 0x08))
                    _keysSinceUndoPoint++;

                if (Environment.TickCount >= _suppressUntil)
                {
                    if (msg == Native.WM_KEYDOWN || msg == Native.WM_SYSKEYDOWN)
                    {
                        if (!injected && !OnKeyDown(k)) return IntPtr.Zero; // проглотить
                    }
                    else if (msg == Native.WM_KEYUP || msg == Native.WM_SYSKEYUP)
                    {
                        if (!injected && !OnKeyUp(k)) return IntPtr.Zero; // проглотить (Caps Lock и т.п.)
                    }
                }
            }
            return Native.CallNextHookEx(_kbHook, code, wParam, lParam);
        }

        private void FlushGap()
        {
            if (_gapBuf.Count == 0) return;
            TextConverter.ReleaseModifiers();
            string s = LayoutService.Render(_gapHkl, _gapBuf);
            TextConverter.SendUnicode(s);
            Log("gap: flushed " + _gapBuf.Count + " keys as '" + s + "'");
            _gapBuf.Clear();
        }

        /// <summary>Это нажатие — хоткей отката? (сам Break не должен ломить счётчик)</summary>
        private bool IsUndoHotkey(Native.KBDLLHOOKSTRUCT k)
        {
            int vk = (int)(k.vkCode & 0xFF);
            if (S.HotUndoVk == 0 || vk != S.HotUndoVk) return false;
            bool shift = (Native.GetAsyncKeyState(0x10) & 0x8000) != 0;
            bool ctrl = (Native.GetAsyncKeyState(0x11) & 0x8000) != 0;
            bool alt = (k.flags & Native.LLKHF_ALTDOWN) != 0 || (Native.GetAsyncKeyState(0x12) & 0x8000) != 0;
            bool win = (Native.GetAsyncKeyState(0x5B) & 0x8000) != 0 || (Native.GetAsyncKeyState(0x5C) & 0x8000) != 0;
            return MatchHot(vk, ctrl, shift, alt, win, S.HotUndoVk, S.HotUndoMods);
        }

        // OnKeyDown возвращает true — пропустить клавишу дальше, false — проглотить.

        private bool OnKeyDown(Native.KBDLLHOOKSTRUCT k)
        {
            UpdateForeground();
            int vk = (int)(k.vkCode & 0xFF);

            bool shift = (Native.GetAsyncKeyState(0x10) & 0x8000) != 0;
            bool ctrl = (Native.GetAsyncKeyState(0x11) & 0x8000) != 0;
            bool alt = (k.flags & Native.LLKHF_ALTDOWN) != 0 || (Native.GetAsyncKeyState(0x12) & 0x8000) != 0;
            bool win = (Native.GetAsyncKeyState(0x5B) & 0x8000) != 0 || (Native.GetAsyncKeyState(0x5C) & 0x8000) != 0;
            bool caps = (Native.GetAsyncKeyState(0x14) & 0x0001) != 0;
            bool heldMods = ctrl || alt || win;

            if (vk == 0xA0 || vk == 0xA1) // левый / правый Shift
            {
                int now = Environment.TickCount;
                // двойной Shift — сменить раскладку
                if (!_anyKeySinceShift && unchecked(now - _lastShiftDown) >= 0 &&
                    unchecked(now - _lastShiftDown) < 400 && S.DoubleShiftSwitch)
                {
                    _lastShiftDown = 0;
                    _anyKeySinceShift = true;
                    _tapAlone = false;
                    SwitchToOtherLayout();
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

            // пауза автоперевода — глобальный тумблер, работает в любом окне
            if (S.HotAutoToggleVk != 0 && MatchHot(vk, ctrl, shift, alt, win, S.HotAutoToggleVk, S.HotAutoToggleMods))
            {
                ToggleAuto();
                return false;
            }

            // ---- ручные действия: работают всегда (и в паузе, и в исключённых приложениях)

            // Backspace сразу после автозамены — отмена как в Caramba:
            // вернуть слово + разделитель и запомнить слово как отменённое
            if (vk == 0x08 && _undoPending && _keysSinceUndoPoint == 0 && !heldMods && !S.Paused)
            {
                UpdateForeground();
                int age = unchecked(Environment.TickCount - _undoTick);
                if (_undoHwnd == _fgHwnd && age >= 0 && age < 15000)
                {
                    _undoPending = false;
                    TextConverter.ReleaseModifiers();
                    Log("backspace-cancel: " + _undoText);
                    int bs2 = _undoLen + _undoSep + _undoTail.Count;
                    string restore2 = _undoText + (_undoSep == 1 ? " " : "") +
                                      (_undoTail.Count > 0 ? LayoutService.Render(_undoHkl, _undoTail) : "");
                    Suppress(600);
                    TextConverter.SendBackspaces(bs2);
                    TextConverter.SendUnicode(restore2);
                    LayoutService.SwitchForegroundTo(_fgHwnd, _undoHkl);
                    ExpectLayout(_undoHkl);
                    if (S.LockAutoAfterManualSwitch) _autoLocked = true;
                    string w = _undoText.ToLowerInvariant();
                    _rejected.Add(w);
                    Defer(delegate { RememberRejected(w); });
                    RemoveAccepted(w);
                    FireInfo("Отменено: " + restore2);
                    return false; // глотаем Backspace
                }
            }

            // отмена последней автозамены (Break по умолчанию)
            if (S.HotUndoVk != 0 && MatchHot(vk, ctrl, shift, alt, win, S.HotUndoVk, S.HotUndoMods))
            {
                Log("hotkey: undo");
                UndoLastConversion();
                return false;
            }
            if (S.HotFixWordVk != 0 && MatchHot(vk, ctrl, shift, alt, win, S.HotFixWordVk, S.HotFixWordMods))
            {
                Log("hotkey: fix-last-word");
                DoFixLastWord();
                return false;
            }
            if (S.HotFixSelVk != 0 && MatchHot(vk, ctrl, shift, alt, win, S.HotFixSelVk, S.HotFixSelMods))
            {
                Log("hotkey: fix-selection");
                BeginFixSelection();
                return false;
            }
            // клавиши раскладок: сочетания с модификаторами — срабатывают по нажатию
            if (S.HotRuMods != 0 && S.HotRuVk != 0 && MatchHot(vk, ctrl, shift, alt, win, S.HotRuVk, S.HotRuMods))
            {
                Log("hotkey: layout RU (combo)");
                SwitchToLanguage(0);
                return false;
            }
            if (S.HotEnMods != 0 && S.HotEnVk != 0 && MatchHot(vk, ctrl, shift, alt, win, S.HotEnVk, S.HotEnMods))
            {
                Log("hotkey: layout EN (combo)");
                SwitchToLanguage(1);
                return false;
            }
            // клавиши раскладок: тап-режим (Caps Lock, Scroll Lock, Insert, F-клавиши).
            // с зажатыми Ctrl/Alt/Win пропускаем — это уже чужое сочетание
            if ((S.HotRuMods == 0 && S.HotRuVk != 0 && vk == S.HotRuVk) ||
                (S.HotEnMods == 0 && S.HotEnVk != 0 && vk == S.HotEnVk))
            {
                if (heldMods) return true;
                _tapVk = vk;
                _tapTarget = (S.HotRuMods == 0 && vk == S.HotRuVk) ? 0 : 1;
                _tapDownTick = Environment.TickCount;
                _tapAlone = true;
                Log("tap armed: vk=" + vk + " lang=" + _tapTarget);
                return !IsSwallowableTap(vk); // не-модификаторы глотаем, чтобы не делали своего
            }

            // ---- компенсация лага смены раскладки: буквы, набранные в просвете
            // до применения смены, перехватываем и доставим уже в целевой раскладке
            if (_gapActive)
            {
                if (_fgHkl == _gapHkl || unchecked(Environment.TickCount - _gapDeadline) >= 0)
                {
                    FlushGap();
                    _gapActive = false;
                }
                else
                {
                    if (vk >= 0x41 && vk <= 0x5A)
                    {
                        _gapBuf.Add(new KeyRec(vk, shift, caps));
                        return false; // глотаем: доставим после применения раскладки
                    }
                    if (vk == 0x08)
                    {
                        if (_gapBuf.Count > 0) _gapBuf.RemoveAt(_gapBuf.Count - 1);
                        return false;
                    }
                    FlushGap();
                    return true; // остальное (пробел и т.п.) — как есть, после отложенных букв
                }
            }

            // ---- дальше — только авто-логика; в исключённых приложениях глушим
            if (IsExcludedHere()) { _buf.Clear(); return true; }

            if (vk >= 0x41 && vk <= 0x5A)
            {
                KeyRec rec = new KeyRec(vk, shift, caps);
                _buf.Push(rec);

                // ЖИВОЕ ИСПРАВЛЕНИЕ (базовая механика Caramba): слово переворачивается
                // сразу, как только набрано достаточно букв — юзер не видит целое слово
                // не в той раскладке. Shift при наборе заглавных — норма, Ctrl/Alt — нет.
                if (!ctrl && !alt && !win && S.AutoConvertOnWordEnd && _buf.Count >= S.MinWordLen)
                {
                    List<KeyRec> word = _buf.Snapshot();
                    if (TryConvertWord(word, 0, false, false))
                    {
                        _buf.Clear(); // дальше юзер печатает уже в новой раскладке
                        if (_undoPending) { _undoTail.Clear(); _undoTailBroken = false; }
                    }
                }

                // хвост отката: запоминаем, что юзер напечатал после замены
                if (_undoPending && !_undoTailBroken && !ctrl && !alt && !win)
                {
                    if (_undoTail.Count < 16) _undoTail.Add(rec);
                    else _undoTailBroken = true;
                }
                return true;
            }

            if (vk == 0x08) { _buf.Pop(); return true; } // Backspace (обычный забой)

            if (vk == 0x0D) // Enter — проверка последнего слова перед отправкой (фича Punto)
            {
                // ТОЛЬКО голый Enter: Shift/Ctrl/Alt+Enter (перенос строки, команды) не трогаем
                bool modified = ctrl || alt || win || shift;
                bool converted = false;
                List<KeyRec> word = _buf.Snapshot();
                if (word.Count > 0 && !modified)
                {
                    _lastWord = word;          // слово запомнится и без проверки (для Ctrl+Space)
                    _lastWordAt = Environment.TickCount;
                }
                if (!modified && S.FixOnEnter)
                    converted = TryConvertWord(word, 0x0D, false, false);
                // ВАЖНО: Enter лок НЕ снимает — в длинном тексте энтеры подряд,
                // а сессия ввода (окно) не сменилась. Лок держится до смены окна.
                // хвост отката после Enter восстановить нельзя
                _undoTailBroken = true;
                _buf.Clear();
                return !converted; // проглотить Enter, если конвертнули (перешлём свой)
            }

            if (vk == 0x09 || vk == 0x1B) { _buf.Clear(); return true; } // Tab / Esc

            if (vk == 0x20 || (vk >= 0x30 && vk <= 0x39) ||
                (vk >= 0xBA && vk <= 0xC0) || (vk >= 0xDB && vk <= 0xDF)) // пробел, цифры, OEM-знаки
            {
                // при зажатых модификаторах (шорткаты) не вмешиваемся
                bool modified = ctrl || alt || win || shift;
                bool converted = false;
                if (!modified && S.AutoConvertOnWordEnd && _buf.Count > 0)
                {
                    List<KeyRec> word = _buf.Snapshot();
                    // разделитель проглатывается и досылается ПОСЛЕ замены — иначе он
                    // доходит до приложения раньше backspace'ов и ломает слово
                    converted = TryConvertWord(word, vk, shift, false);
                }
                if (_buf.Count > 0 && !modified)
                {
                    _lastWord = _buf.Snapshot();
                    _lastWordAt = Environment.TickCount;
                }
                _buf.Clear();
                return !converted; // заменили — разделитель дослали внутри
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
                    _tapAlone = false;        // клик между нажатием и отпусканием отменяет тап
                    _keysSinceUndoPoint++;    // клик мог сдвинуть каретку — откат отменяем
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
            _undoPending = false; // сменилось окно — откатывать нечего/небезопасно
            _undoTailBroken = true;
            _gapActive = false; _gapBuf.Clear(); // буквы из другого окна не переносим
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
            // тап засчитывается только «голой» клавишей: Ctrl/Alt/Win рядом — чужое сочетание
            bool ctrl = (Native.GetAsyncKeyState(0x11) & 0x8000) != 0;
            bool alt = (k.flags & Native.LLKHF_ALTDOWN) != 0 || (Native.GetAsyncKeyState(0x12) & 0x8000) != 0;
            bool win = (Native.GetAsyncKeyState(0x5B) & 0x8000) != 0 || (Native.GetAsyncKeyState(0x5C) & 0x8000) != 0;
            bool alone = _tapAlone && !ctrl && !alt && !win &&
                         unchecked(now - _tapDownTick) >= 0 && unchecked(now - _tapDownTick) < 700;
            _tapAlone = false;
            if (alone)
            {
                Log("tap fired: lang=" + _tapTarget);
                UpdateForeground();
                SwitchToLanguage(_tapTarget);
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
            // компенсация лага: буквы в просвете доставим в целевой раскладке
            _gapActive = true; _gapHkl = target; _gapBuf.Clear();
            _gapDeadline = Environment.TickCount + 800;
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

        /// <summary>Попытка конвертации слова; manual=true — вызов явным хоткеем (игнорирует лок).
        /// resendVk — проглоченный разделитель (пробел/OEM) или Enter, который надо дослать после.</summary>
        private bool TryConvertWord(List<KeyRec> word, int resendVk, bool resendShift, bool manual)
        {
            string why = null;
            if (S.Paused) why = "paused";
            else if (word == null || word.Count < S.MinWordLen) why = "too-short (" + (word == null ? 0 : word.Count) + ")";
            else if (!manual && S.LockAutoAfterManualSwitch && _autoLocked) why = "locked";
            if (why != null) { Log("convert skip: " + why); return false; }

            UpdateForeground();
            if (IsExcludedHere()) { Log("convert skip: excluded app"); return false; }

            List<IntPtr> layouts = LayoutService.GetLayouts();
            if (layouts.Count < 2) { Log("convert skip: one layout"); return false; }
            List<LayoutCandidate> cands = LayoutService.RenderAll(word, layouts);

            LayoutCandidate cur = null;
            foreach (LayoutCandidate c in cands) if (c.Hkl == _fgHkl) { cur = c; break; }
            if (cur == null || cur.Lang < 0) { Log("convert skip: cur unknown"); return false; }

            string typedLow = cur.Text.ToLowerInvariant();

            // обучение: это слово юзер уже отменил — автоматически не трогаем
            // (ручной хоткей в обход: manual=true проверку не проходит)
            if (!manual && _rejected.Contains(typedLow))
            {
                Log("convert skip: learned-rejected '" + cur.Text + "'");
                return false;
            }
            bool acceptedWord = !manual && _accepted.Contains(typedLow);

            LayoutCandidate best = null;
            foreach (LayoutCandidate c in cands)
            {
                if (c.Hkl == _fgHkl || c.Lang < 0) continue;
                if (best == null || c.Score > best.Score) best = c;
            }
            if (best == null) { Log("convert skip: no candidate"); return false; }

            bool pass = LanguageTables.ShouldConvert(cur.Text, cur.Lang, cur.Score,
                                              best.Text, best.Lang, best.Score, S.Sensitivity);
            if (!pass && acceptedWord)
                pass = true; // такое слово юзер уже принимал — конвертим несмотря на скоринг

            // живое исправление решается посреди набора «вслепую» — запас x2
            double liveFactor = (resendVk == 0 && !manual) ? 2.0 : 1.0;

            // словарная валидация результата — действует всегда, даже для accepted:
            // мусорный результат в буфер не вставляем
            string dictSkip = null;
            if (pass)
            {
                bool targetInDict = WordDict.Has(best.Text, best.Lang);
                bool curInDict = WordDict.Has(cur.Text, cur.Lang);
                if (curInDict && !targetInDict)
                {
                    dictSkip = "cur-in-dict, target-not";
                    pass = false; // текущее — частое слово, результат — нет: не трогаем
                }
                else if (!targetInDict && !curInDict)
                {
                    // оба не словарные — нужен усиленный запас
                    double need = LanguageTables.BaseMargin *
                                  (acceptedWord ? 1.0 : 2.0 * liveFactor) /
                                  Math.Max(0.3, S.Sensitivity);
                    if (best.Score - cur.Score < need) pass = false;
                }
            }
            if (!pass)
            {
                Log("convert skip: scoring '" + cur.Text + "'(" + cur.Score.ToString("F2") + ") vs '" +
                    (best != null ? best.Text : "?") + "'(" + (best != null ? best.Score : 0).ToString("F2") + ")" +
                    (dictSkip != null ? " [" + dictSkip + "]" : ""));
                return false;
            }

            // юзер мог держать Shift/Ctrl (хоткей же с модификатором) — инжекция
            // с зажатыми модификаторами даёт Ctrl+Shift+C и управляющие символы
            TextConverter.ReleaseModifiers();

            Log("convert OK: '" + cur.Text + "' -> '" + best.Text + "' (resend=" + resendVk + ")");
            _lastWord = word;

            Suppress(600);
            TextConverter.SendBackspaces(word.Count);
            TextConverter.SendUnicode(best.Text);
            if (resendVk != 0) TextConverter.SendKey(resendVk, false, resendShift); // досылаем проглоченный разделитель/Enter
            LayoutService.SwitchForegroundTo(_fgHwnd, best.Hkl);
            ExpectLayout(best.Hkl);

            // точка отката: Break вернёт исходное слово и раскладку.
            // Только для замен по разделителю — после Enter строка уже ушла в
            // приложение, откат стирал бы переносы
            _undoPending = resendVk != 0x0D;
            _undoText = cur.Text;
            _undoLen = best.Text.Length;
            _undoSep = (resendVk != 0 && resendVk != 0x0D) ? 1 : 0;
            _undoHkl = cur.Hkl;
            _undoHwnd = _fgHwnd;
            _undoTick = Environment.TickCount;
            _keysSinceUndoPoint = 0;

            string acceptedTyped = cur.Text.ToLowerInvariant();
            Defer(delegate { RememberAccepted(acceptedTyped); }); // юзер не отменил в течение 15 с — примем

            FireConverted(cur.Text, best.Text);
            return true;
        }

        /// <summary>Глобальная пауза автоперевода (как Break в Caramba).</summary>
        public void ToggleAuto()
        {
            S.Paused = !S.Paused;
            if (!S.Paused) _autoLocked = false; // с чистого листа
            bool paused = S.Paused;
            Defer(delegate
            {
                SettingsStore.Save(S);
                Apply(S); // обновит тултип трея и статус-карточку
            });
            FireInfo(paused ? "Автоисправление выключено" : "Автоисправление включено");
        }

        /// <summary>Отмена последней автозамены: вернуть исходное слово и раскладку.</summary>
        public void UndoLastConversion()
        {
            if (!_undoPending) { Log("undo skip: nothing pending"); FireInfo("Нечего отменять"); return; }
            // после замены уже печатали — backspace'ами сотрём чужой текст, отказываемся
            if (_keysSinceUndoPoint > 0) { Log("undo skip: typed " + _keysSinceUndoPoint); FireInfo("Уже набран новый текст"); return; }
            UpdateForeground();
            if (_undoHwnd != _fgHwnd) { Log("undo skip: other window"); FireInfo("Уже в другом окне"); return; }
            int age = unchecked(Environment.TickCount - _undoTick);
            if (age < 0 || age > 15000) { Log("undo skip: stale " + age); FireInfo("Слишком поздно"); return; }

            TextConverter.ReleaseModifiers();
            int bs = _undoLen + _undoSep + _undoTail.Count;
            string restore = _undoText + (_undoSep == 1 ? " " : "") +
                             (_undoTail.Count > 0 ? LayoutService.Render(_undoHkl, _undoTail) : "");
            Suppress(600);
            TextConverter.SendBackspaces(bs);
            TextConverter.SendUnicode(restore);
            LayoutService.SwitchForegroundTo(_fgHwnd, _undoHkl);
            ExpectLayout(_undoHkl);
            if (S.LockAutoAfterManualSwitch) _autoLocked = true; // юзер настоял на своём
            string learned = _undoText;
            Defer(delegate { RememberRejected(learned); RemoveAccepted(learned); }); // слово больше не автозаменяем
            FireInfo("Отменено: " + restore);
            _undoPending = false;
        }

        /// <summary>Забыть изученные слова (accepted/rejected).</summary>
        public void ForgetAllWords()
        {
            _rejected.Clear();
            _accepted.Clear();
            try
            {
                System.IO.Directory.CreateDirectory(SettingsStore.Dir);
                System.IO.File.WriteAllText(LearnedPath, "");
                System.IO.File.WriteAllText(AcceptedPath, "");
            }
            catch (Exception) { }
            FireInfo("Память слов очищена");
        }

        public void DoFixLastWord()
        {
            UpdateForeground();

            // каретка сразу после слова (после пробела ничего не нажимали) —
            // точный путь: backspace'ы + перенабор
            if (_keysSinceUndoPoint == 0 && _lastWord.Count > 0)
            {
                Log("fix-last-word: exact path");
                var word = new List<KeyRec>(_lastWord);
                if (!TryConvertWord(word, 0, false, true))
                    FireInfo("Раскладка уже верная");
                return;
            }

            // каретка уже ушла вперёд — выделяем слово слева от каретки
            // и конвертируем его как выделенный текст (сценарий «красное слово»:
            // клик сразу после слова → Ctrl+Space)
            Log("fix-last-word: select-left path (keysSince=" + _keysSinceUndoPoint + ")");
            TextConverter.SendCombo(0x11, 0x10, 0x25, true); // Ctrl+Shift+Left
            BeginFixSelection(true);
        }

        // --- двухфазная конвертация выделенного текста ---
        // Фаза 1 (в хуке): только Ctrl+C и выход. Фаза 2 (таймер, вне хука): чтение
        // буфера, конвертация, вставка. Иначе инжектированный Ctrl+C не успевает
        // отработать, в буфере остаётся СТАРЫЙ текст и он вставится поверх выделения.

        private System.Windows.Forms.Timer _selTimer;
        private IntPtr _selFgHwnd;
        private int _selTries;
        private int _selPhase;               // 0 = ждём отпускания модификаторов, 1 = ждём буфер
        private bool _selFromFixWord;        // выделение слева от каретки (Ctrl+Space) — с ретраем
        private bool _selRetried;
        private string _selBaseline;         // буфер до Ctrl+C
        private uint _selBaseSeq;            // sequence number буфера до Ctrl+C

        public void BeginFixSelection()
        {
            BeginFixSelection(false);
        }

        public void BeginFixSelection(bool fromFixWord)
        {
            UpdateForeground();
            _selFgHwnd = _fgHwnd;
            _selFromFixWord = fromFixWord;
            _selRetried = false;
            _selBaseline = TextConverter.GetClipboardTextOnce();
            _selBaseSeq = Native.GetClipboardSequenceNumber();
            _selPhase = 0;
            _selTries = 0;
            if (_selTimer != null) { _selTimer.Stop(); _selTimer.Dispose(); }
            _selTimer = new System.Windows.Forms.Timer();
            _selTimer.Interval = 60;
            _selTimer.Tick += SelPollTick;
            _selTimer.Start();
            Log("sel: started (baseline " + (_selBaseline != null ? _selBaseline.Length + " ch" : "empty") + ")");
        }

        private void SelPollTick(object sender, EventArgs e)
        {
            if (_selPhase == 0)
            {
                // ждём, пока юзер отпустит модификаторы хоткея (иначе будет
                // Ctrl+Shift+C вместо Ctrl+C — «копирование форматирования»)
                bool shift = (Native.GetAsyncKeyState(0x10) & 0x8000) != 0;
                bool ctrl = (Native.GetAsyncKeyState(0x11) & 0x8000) != 0;
                bool alt = (Native.GetAsyncKeyState(0x12) & 0x8000) != 0;
                bool win = (Native.GetAsyncKeyState(0x5B) & 0x8000) != 0 || (Native.GetAsyncKeyState(0x5C) & 0x8000) != 0;
                _selTries++;
                if ((shift || ctrl || alt || win) && _selTries < 10) return; // до ~0.6 c
                TextConverter.ReleaseModifiers();
                _selPhase = 1;
                _selTries = 0;
                TextConverter.SendCombo(0x11, 0, 0x43, false); // чистый Ctrl+C
                Log("sel: ctrl+c sent (phase 1)");
                return;
            }

            string text = TextConverter.GetClipboardTextOnce();
            bool seqChanged = Native.GetClipboardSequenceNumber() != _selBaseSeq;
            _selTries++;
            bool isNew = !string.IsNullOrEmpty(text) && (seqChanged || text != _selBaseline);
            if (!isNew && _selTries < 20) return; // ждём до ~1.2 c

            if (_selTimer != null) { _selTimer.Stop(); _selTimer.Dispose(); _selTimer = null; }

            if (string.IsNullOrEmpty(text) || !seqChanged)
            {
                // Ctrl+Shift+Left мог не сработать в этом приложении — расширяем до 2 слов
                if (_selFromFixWord && !_selRetried)
                {
                    _selRetried = true;
                    _selPhase = 0;
                    _selTries = 0;
                    TextConverter.SendCombo(0x11, 0x10, 0x25, true);
                    TextConverter.SendCombo(0x11, 0x10, 0x25, true);
                    if (_selTimer != null) _selTimer.Start();
                    Log("sel: retry with 2 words left");
                    return;
                }
                // буфер не обновился — выделение не скопировалось; вставлять старьё нельзя
                Log("sel: no new clipboard (seqChanged=" + seqChanged + ")");
                FireInfo("Нет выделенного текста");
                return;
            }
            Log("sel: got " + text.Length + " chars");

            int lang = LanguageTables.LangOf(LanguageTables.LettersOnly(text));
            if (lang < 0)
            {
                Log("sel: lang unknown");
                FireInfo("Не удалось определить язык");
                return;
            }
            string converted = CharMaps.MapText(text, lang == 1);
            TextConverter.SetClipboardTextSafe(converted);
            TextConverter.ReleaseModifiers();
            TextConverter.SendCombo(0x11, 0x56); // Ctrl+V
            Log("sel: pasted converted (" + lang + ")");

            IntPtr target = LayoutService.FindLayoutByLang(lang == 1 ? 0 : 1);
            if (target != IntPtr.Zero)
            {
                LayoutService.SwitchForegroundTo(_selFgHwnd, target);
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
            // компенсация лага: буквы в просвете доставим в целевой раскладке
            _gapActive = true; _gapHkl = other; _gapBuf.Clear();
            _gapDeadline = Environment.TickCount + 800;
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

        // отложенная очередь: хук не должен заниматься плашками/файлами/сохранением,
        // иначе Windows режет события клавиатуры («работает через раз»)
        private readonly Queue<Action> _deferred = new Queue<Action>();
        private System.Windows.Forms.Timer _deferTimer;

        private void Defer(Action action)
        {
            _deferred.Enqueue(action);
            if (_deferTimer == null)
            {
                _deferTimer = new System.Windows.Forms.Timer { Interval = 50 };
                _deferTimer.Tick += delegate { FlushDeferred(); };
                _deferTimer.Start();
            }
        }

        private void FlushDeferred()
        {
            while (_deferred.Count > 0)
            {
                Action a = _deferred.Dequeue();
                try { a(); }
                catch (Exception) { }
            }
        }

        private void FireConverted(string oldText, string newText)
        {
            string o = oldText, n = newText;
            Defer(delegate
            {
                var d = Converted;
                if (d != null) d(o, n);
            });
        }

        private void FireInfo(string msg)
        {
            Defer(delegate
            {
                var d = Info;
                if (d != null) d(msg);
            });
        }

        // --- диагностика: журнал решений (пишется вне хука) ---
        private readonly List<string> _logBuf = new List<string>();

        private void Log(string line)
        {
            _logBuf.Add(DateTime.Now.ToString("HH:mm:ss.fff") + "  " + line);
            Defer(FlushLog);
        }

        private void FlushLog()
        {
            if (_logBuf.Count == 0) return;
            try
            {
                System.IO.Directory.CreateDirectory(SettingsStore.Dir);
                string p = System.IO.Path.Combine(SettingsStore.Dir, "log.txt");
                if (System.IO.File.Exists(p) && new System.IO.FileInfo(p).Length > 512 * 1024)
                    System.IO.File.WriteAllText(p, "");
                System.IO.File.AppendAllLines(p, _logBuf);
            }
            catch (Exception) { }
            _logBuf.Clear();
        }
    }
}
