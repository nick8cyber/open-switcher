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
        private bool _autoLocked;            // юзер сам выбрал раскладку — автодетект молчит до конца текущего сеанса набора
        private int _lastInputTick;          // последний НЕмодификаторный keydown — отсчёт паузы между сеансами
        private const int SessionPauseMs = 3000; // пауза в наборе дольше этого = сеанс кончился, лок отпускает
        private int _lastResendSpaceTick;    // когда дослали проглоченный пробел — для глотания «эха» (двойных пробелов)
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
        private int _lastBufTick;            // тикант предыдущей буквы буфера (пауза для live)
        public static bool TestInjectMode;   // ВРЕМЕННО: трактовать инжектированный ввод как настоящий
        /// <summary>Пауза набора (мс), после которой разрешена live-конвертация слова.</summary>
        internal const int LivePauseMs = 500;
        private List<KeyRec> _undoTail = new List<KeyRec>(); // хвост: что юзер напечатал после замены
        private bool _undoTailBroken;        // хвост испорчен (enter/cap) — откат запрещён

        // компенсация лага смены раскладки после тапа Shift
        private bool _gapActive;
        private IntPtr _gapHkl;              // целевая раскладка
        private readonly List<KeyRec> _gapBuf = new List<KeyRec>();
        private int _gapDeadline;
        private System.Windows.Forms.Timer _hookWatchdog; // переустановка LL-хуков: Windows молча снимает их при таймаутах колбэка.
        // Только WinForms-таймер (UI-поток)! System.Threading.Timer ставит хуки из потока пула без
        // message loop — LL-колбэки туда не доставляются, и через 60 с после старта всё умирает молча.

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

            // watchdog: раз в 60 с переустанавливаем LL-хуки — Windows молча снимает их,
            // если колбэк хоть раз сработал медленнее таймаута (типичная «внезапная смерть»)
            _hookWatchdog = new System.Windows.Forms.Timer { Interval = 60000 };
            _hookWatchdog.Tick += delegate
            {
                try { ReinstallHooks(); Log("watchdog: hooks reinstalled"); }
                catch (Exception) { }
            };
            _hookWatchdog.Start();
        }

        private void ReinstallHooks()
        {
            if (_kbHook != IntPtr.Zero) Native.UnhookWindowsHookEx(_kbHook);
            if (_mouseHook != IntPtr.Zero) Native.UnhookWindowsHookEx(_mouseHook);
            _kbHook = Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, _kbProc, IntPtr.Zero, 0);
            _mouseHook = Native.SetWindowsHookEx(Native.WH_MOUSE_LL, _mouseProc, IntPtr.Zero, 0);
            if (_kbHook == IntPtr.Zero || _mouseHook == IntPtr.Zero)
                Log("hooks FAILED: kb=" + (_kbHook != IntPtr.Zero) + " mouse=" + (_mouseHook != IntPtr.Zero));
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
            IntPtr prevHwnd = _fgHwnd;
            _fgHwnd = Native.GetForegroundWindow();

            // Окно сменилось, а WinEvent мог не дойти (доставка EVENT_SYSTEM_FOREGROUND
            // ненадёжна: события теряются, когда система занята или хук отключён по
            // таймауту). Детектим смену окна сами — это та же «новая сессия ввода»:
            // снимаем лок автодетекта и сбрасываем состояние, как в WinEventProcHandler.
            if (_expectedValid && _fgHwnd != IntPtr.Zero && prevHwnd != IntPtr.Zero && prevHwnd != _fgHwnd)
            {
                if (TestInjectMode)
                    Log("window-switch: " + _fgHwnd.ToInt64().ToString("X") + " (was " + prevHwnd.ToInt64().ToString("X") + ")");
                _autoLocked = false;
                _undoPending = false;
                _undoTailBroken = true;
                _buf.Clear();
                _tapAlone = false;
                _anyKeySinceShift = true;
                _gapActive = false; _gapBuf.Clear();
                _expectedValid = false;
            }
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
            {
                _autoLocked = true;
                if (TestInjectMode)
                    Log("auto-lock: hkl=" + _fgHkl.ToInt64().ToString("X8") +
                        " expected=" + _expectedHkl.ToInt64().ToString("X8") +
                        " hwnd=" + _fgHwnd.ToInt64().ToString("X"));
            }
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
                // Три класса ввода:
                //  1) реальный пользовательский — обрабатываем всегда;
                //  2) в тест-режиме (OS_TEST_INJECT) инжектированный ИЗВНЕ — обрабатываем
                //     как настоящий (иначе тест не может гонять движок без человека);
                //  3) СОБСТВЕННАЯ инжекция движка (SendCombo/SendUnicode/...) — игнорируем
                //     даже в тест-режиме, иначе движок реагирует на себя: фантомные тапы
                //     от Shift в комбинациях, захват собственных клавиш gap-буфером.
                bool selfInject = TestInjectMode && TextConverter.SelfInjectDepth > 0;
                bool treatAsReal = !selfInject && (!injected || TestInjectMode);

                // эхо-пробел: пробел, прилетающий в первые 250 мс после досланного
                // после замены разделителя, — это второе нажатие/авторепит (юзер не
                // увидел мгновенную замену и нажал ещё раз). Глотаем, иначе после
                // автоправок появляются двойные/тройные пробелы. Инжектированный
                // досланный пробел сюда не попадает (treatAsReal=false).
                if (msg == Native.WM_KEYDOWN && treatAsReal && (k.vkCode & 0xFF) == 0x20)
                {
                    if (_lastResendSpaceTick != 0 && _buf.Count == 0 &&
                        unchecked(Environment.TickCount - _lastResendSpaceTick) < 250)
                    {
                        Log("space-echo swallowed");
                        return IntPtr.Zero;
                    }
                    _lastResendSpaceTick = 0;
                }
                else if (msg == Native.WM_KEYDOWN && treatAsReal)
                {
                    _lastResendSpaceTick = 0; // пошла новая печать — окно эха не нужно
                }

                // guard отката: считаем ЛЮБЫЕ реальные нажатия — даже в suppress-окне
                // после автозамены (иначе Break после быстрой печати портит текст).
                // Исключения: модификаторы (они не «набор»), сам хоткей отката,
                // хоткей «исправить слово» и Backspace при ожидающемся откате
                // (иначе Backspace-отмена никогда не срабатывает). Без исключения
                // хоткея Ctrl+Space его собственное нажатие засчитывалось как
                // «набор после слова», и точный путь (каретка сразу после слова)
                // никогда не срабатывал — всегда шло выделение слева.
                if (msg == Native.WM_KEYDOWN && treatAsReal && !IsModifierVk(k.vkCode) && !IsUndoHotkey(k) &&
                    !IsFixWordHotkey(k) && !(_undoPending && (k.vkCode & 0xFF) == 0x08))
                    _keysSinceUndoPoint++;

                // лок живёт только внутри сеанса набора, при котором сработал: пауза
                // длиннее SessionPauseMs — сеанс кончился, следующий ввод начинается
                // с чистым автодетектом (без этой оговорки лок висит до смены окна)
                if (msg == Native.WM_KEYDOWN && treatAsReal && !IsModifierVk(k.vkCode))
                {
                    if (_autoLocked && unchecked(Environment.TickCount - _lastInputTick) >= SessionPauseMs)
                    {
                        _autoLocked = false;
                        Log("auto-unlock: session pause " + unchecked(Environment.TickCount - _lastInputTick) + " ms");
                    }
                    _lastInputTick = Environment.TickCount;
                }

                if (Environment.TickCount >= _suppressUntil)
                {
                    if (msg == Native.WM_KEYDOWN || msg == Native.WM_SYSKEYDOWN)
                    {
                        if (treatAsReal && !OnKeyDown(k)) return IntPtr.Zero; // проглотить
                    }
                    else if (msg == Native.WM_KEYUP || msg == Native.WM_SYSKEYUP)
                    {
                        if (treatAsReal && !OnKeyUp(k)) return IntPtr.Zero; // проглотить (Caps Lock и т.п.)
                    }
                }
            }
            return Native.CallNextHookEx(_kbHook, code, wParam, lParam);
        }

        private void FlushGap()
        {
            if (_gapBuf.Count == 0) return;
            // режим и окно фокуса обязаны выставляться в точке инжекции — иначе
            // тут остаются значения с прошлой замены (чужое окно / SendInput)
            TextConverter.InjectMode = S.InputMode;
            TextConverter.FocusHwnd = _fgFocus != IntPtr.Zero ? _fgFocus : _fgHwnd;
            TextConverter.ReleaseModifiers();
            string s = LayoutService.Render(_gapHkl, _gapBuf);
            TextConverter.SendUnicode(s);
            Log("gap: flushed " + _gapBuf.Count + " keys as '" + s + "'");
            _gapBuf.Clear();
        }

        /// <summary>Модификатор ли это (не считаем модификаторы «набором после слова»).</summary>
        private static bool IsModifierVk(uint vkRaw)
        {
            int vk = (int)(vkRaw & 0xFF);
            return vk == 0x10 || vk == 0x11 || vk == 0x12 || vk == 0x5B || vk == 0x5C ||
                   (vk >= 0xA0 && vk <= 0xA5);
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

        /// <summary>Это нажатие — хоткей «исправить последнее слово»? (само нажатие
        /// не должно засчитываться как набор после слова)</summary>
        private bool IsFixWordHotkey(Native.KBDLLHOOKSTRUCT k)
        {
            int vk = (int)(k.vkCode & 0xFF);
            if (S.HotFixWordVk == 0 || vk != S.HotFixWordVk) return false;
            bool shift = (Native.GetAsyncKeyState(0x10) & 0x8000) != 0;
            bool ctrl = (Native.GetAsyncKeyState(0x11) & 0x8000) != 0;
            bool alt = (k.flags & Native.LLKHF_ALTDOWN) != 0 || (Native.GetAsyncKeyState(0x12) & 0x8000) != 0;
            bool win = (Native.GetAsyncKeyState(0x5B) & 0x8000) != 0 || (Native.GetAsyncKeyState(0x5C) & 0x8000) != 0;
            return MatchHot(vk, ctrl, shift, alt, win, S.HotFixWordVk, S.HotFixWordMods);
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
            TextConverter.InjectMode = S.InputMode;
            TextConverter.FocusHwnd = _fgFocus != IntPtr.Zero ? _fgFocus : _fgHwnd;
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
                if (_undoPending)
                {
                    Log("hotkey: undo");
                    UndoLastConversion();
                }
                else
                {
                    // откатить нечего: Break означает «детектор слово не осилил, а надо было» —
                    // принудительно переворачиваем последнее слово и выучиваем пару
                    Log("hotkey: undo -> nothing pending, force flip");
                    ForceFlipLastWord();
                }
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
                int nowTick = Environment.TickCount;
                // live-конвертация уместна только после ПАУЗЫ в наборе: непрерывный поток
                // букв — это ещё не законченное слово, и переворот словарного ПРЕФИКСА
                // («ghb»->«при» внутри «ghbdtn») давал «приветвте» вместо «привет».
                // Требуем >= LivePauseMs от предыдущей буквы; при непрерывном наборе
                // слово честно ловится по разделителю (пробел/Enter).
                bool livePause = _buf.Count == 0 ||
                    (unchecked(nowTick - _lastBufTick) >= 0 && unchecked(nowTick - _lastBufTick) >= LivePauseMs);
                KeyRec rec = new KeyRec(vk, shift, caps);
                _buf.Push(rec);
                _lastBufTick = nowTick;
                bool liveConverted = false;

                // ЖИВОЕ ИСПРАВЛЕНИЕ (базовая механика Caramba): слово переворачивается
                // сразу, как только набрано достаточно букв — юзер не видит целое слово
                // не в той раскладке. Shift при наборе заглавных — норма, Ctrl/Alt — нет.
                if (livePause && !ctrl && !alt && !win && S.AutoConvertOnWordEnd && _buf.Count >= S.MinWordLen)
                {
                    List<KeyRec> word = _buf.Snapshot();
                    if (TryConvertWord(word, 0, false, false))
                    {
                        _buf.Clear();
                        liveConverted = true; // эта буква уже внутри заменённого слова — в хвост ей нельзя
                    }
                }

                // хвост отката: запоминаем, что юзер напечатал после замены
                if (!liveConverted && _undoPending && !_undoTailBroken && !ctrl && !alt && !win)
                {
                    if (_undoTail.Count < 16) _undoTail.Add(rec);
                    else _undoTailBroken = true;
                }
                return true;
            }

            if (vk == 0x08) // Backspace: обычный забой — правим и хвост отката
            {
                if (ctrl || alt || win) // Ctrl+Backspace = удалить слово — откат небезопасен
                {
                    _buf.Clear();
                    if (_undoPending) _undoTailBroken = true;
                    return true;
                }
                _buf.Pop();
                if (_undoPending && !_undoTailBroken)
                {
                    if (_undoTail.Count > 0) _undoTail.RemoveAt(_undoTail.Count - 1);
                    else _undoTailBroken = true; // стёрли сам заменённый текст — откат больше не воспроизведёт историю
                }
                return true;
            }

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
                // цифры/знаки после замены — тоже хвост, иначе Break вернёт слово
                // ПОВЕРХ них с перепутанным порядком символов
                if (!modified && !converted && _undoPending && !_undoTailBroken && vk != 0x09)
                {
                    if (_undoTail.Count < 16) _undoTail.Add(new KeyRec(vk, shift, caps));
                    else _undoTailBroken = true;
                }
                _buf.Clear();
                return !converted; // заменили — разделитель дослали внутри
            }

            if ((vk >= 0x70 && vk <= 0x87) || (vk >= 0x21 && vk <= 0x28) ||
                vk == 0x2D || vk == 0x2E) // F-клавиши, навигация, Ins/Del
            {
                _buf.Clear();
                // навигация/Del сдвигают каретку или правят текст — хвост отката невоспроизводим
                if (_undoPending) _undoTailBroken = true;
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
                if (_undoPending) _undoTailBroken = true; // клик ломает откат (контракт)
                }
            }
            return Native.CallNextHookEx(_mouseHook, code, wParam, lParam);
        }

        private void WinEventProcHandler(IntPtr hHook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
        {
            if (TestInjectMode)
                Log("fg-event: hwnd=" + hwnd.ToInt64().ToString("X") + " (was " + _fgHwnd.ToInt64().ToString("X") + ")");
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

            // тап одноразовый: после отпускания клавиши disarm, иначе осиротевший
            // KEYUP той же клавиши (Alt+Tab, инжекция, гонка с двойным Shift)
            // спровоцирует повторное переключение раскладки
            int armedVk = _tapVk;
            _tapVk = 0;

            bool swallow = IsSwallowableTap(vk);
            int now = Environment.TickCount;
            // тап засчитывается только «голой» клавишей: Ctrl/Alt/Win рядом — чужое сочетание
            bool ctrl = (Native.GetAsyncKeyState(0x11) & 0x8000) != 0;
            bool alt = (k.flags & Native.LLKHF_ALTDOWN) != 0 || (Native.GetAsyncKeyState(0x12) & 0x8000) != 0;
            bool win = (Native.GetAsyncKeyState(0x5B) & 0x8000) != 0 || (Native.GetAsyncKeyState(0x5C) & 0x8000) != 0;
            bool alone = _tapAlone && !ctrl && !alt && !win &&
                         unchecked(now - _tapDownTick) >= 0 && unchecked(now - _tapDownTick) < 700;
            if (alone)
            {
                Log("tap fired: lang=" + _tapTarget);
                UpdateForeground();
                SwitchToLanguage(_tapTarget);
            }
            return !IsSwallowableTap(armedVk);
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
            else if (!manual && S.LockAutoAfterManualSwitch && _autoLocked)
                why = "locked (hkl=" + _fgHkl.ToInt64().ToString("X8") + " hwnd=" + _fgHwnd.ToInt64().ToString("X") + ")";
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

            // ЖИВОЙ режим: переворачиваем только если результат — знакомое слово.
            // Посреди набора частотный скоринг шумит ('муд'->'vel' на правильном «мудаке»),
            // поэтому уверенность = слово есть в словаре.
            bool live = resendVk == 0 && !manual;
            // выученная пара (accepted) сильнее живого ограничителя: юзер уже
            // подтвердил эту конвертацию руками — переворачиваем и посреди набора
            if (live && !acceptedWord && !WordDict.Has(best.Text, best.Lang))
            {
                Log("convert skip: live, target not in dict ('" + best.Text + "')");
                return false;
            }

            bool pass = LanguageTables.ShouldConvert(cur.Text, cur.Lang, cur.Score,
                                              best.Text, best.Lang, best.Score, S.Sensitivity);
            if (!pass && acceptedWord)
                pass = true; // такое слово юзер уже принимал — конвертим несмотря на скоринг

            // Частотный пол цели (EN -0.05 / RU -0.55) режет и настоящие слова с редкими
            // биграммами ('что' ниже пола: пары 'чт' нет в таблице). Если цель — словарное
            // слово, а набранное — нет, скорингу верить нельзя: словарь перевешивает
            // (selftest давно ожидал это правило — в движке его не было).
            if (!pass && !acceptedWord && WordDict.Has(best.Text, best.Lang) &&
                !WordDict.Has(cur.Text, cur.Lang))
            {
                pass = true;
                Log("convert: dict-over-score ('" + cur.Text + "' -> '" + best.Text + "')");
            }

            // словарная валидация результата — но не для выученных пар: юзер уже
            // подтвердил эту конвертацию руками, словарь здесь не указ
            string dictSkip = null;
            if (pass && !acceptedWord)
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
                                  (acceptedWord ? 1.0 : 2.0) /
                                  Math.Max(0.3, S.Sensitivity);
                    if (best.Score - cur.Score < need)
                    {
                        dictSkip = "both-not-in-dict, margin";
                        pass = false;
                    }
                }
            }
            // СТРОП: решение обязано быть положительным, иначе конвертируем МУСОР.
            // (раньше pass вычислялся, но не проверялся — из-за этого в журнал
            // попадали «convert OK: 'так' -> 'nfr'», которых не должно быть)
            if (!pass)
            {
                Log("convert skip: score" + (dictSkip != null ? "/" + dictSkip : "") +
                    " ('" + cur.Text + "' -> '" + best.Text + "')");
                return false;
            }

            // юзер мог держать Shift/Ctrl (хоткей же с модификатором) — инжекция
            // с зажатыми модификаторами даёт Ctrl+Shift+C и управляющие символы
            TextConverter.ReleaseModifiers();
            TextConverter.InjectMode = S.InputMode;
            // ВАЖНО: без fallback на _fgHwnd (когда GetGUIThreadInfo не дал hwndFocus)
            // FocusHwnd оставался Zero — канал сообщений молча отключался, и всё
            // уходило через SendInput, который гасит COMODO HIPS.
            TextConverter.FocusHwnd = _fgFocus != IntPtr.Zero ? _fgFocus : _fgHwnd;
            if (_fgFocus == IntPtr.Zero)
                Log("convert warn: no hwndFocus, messages go to fg window");

            Log("convert OK: '" + cur.Text + "' -> '" + best.Text + "' (resend=" + resendVk +
                ", mode=" + (TextConverter.InjectMode == 1 ? "msg" : "sendinput") + ")");
            _lastWord = word;

            Suppress(600);
            TextConverter.SendBackspaces(word.Count);
            TextConverter.SendUnicode(best.Text);
            if (TextConverter.LastSendInputRequested > 0)
                Log("inj: sendinput accepted " + TextConverter.LastSendInputResult + "/" +
                    TextConverter.LastSendInputRequested +
                    (TextConverter.LastSendInputResult == 0 ? " — BLOCKED (HIPS/антивирус?)" : ""));
            if (resendVk != 0) TextConverter.SendKey(resendVk, false, resendShift); // досылаем проглоченный разделитель/Enter
            if (resendVk == 0x20) _lastResendSpaceTick = Environment.TickCount; // окно глотания «эха» пробела
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
            // новая точка отката — хвост от ПРЕДЫДУЩЕЙ замены не имеет права
            // сюда попасть, иначе Break стирал/возвращал чужие символы
            _undoTail.Clear();
            _undoTailBroken = false;

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
            // хвост знает всё, что напечатано после замены (до 16 клавиш) —
            // откат корректен, пока хвост не «сломан» (Enter/переполнение)
            if (_undoTailBroken) { Log("undo skip: tail broken"); FireInfo("Слишком много набрано после"); return; }
            UpdateForeground();
            if (_undoHwnd != _fgHwnd) { Log("undo skip: other window"); FireInfo("Уже в другом окне"); return; }
            int age = unchecked(Environment.TickCount - _undoTick);
            if (age < 0 || age > 15000) { Log("undo skip: stale " + age); FireInfo("Слишком поздно"); return; }

            TextConverter.ReleaseModifiers();
            TextConverter.InjectMode = S.InputMode;
            TextConverter.FocusHwnd = _fgFocus != IntPtr.Zero ? _fgFocus : _fgHwnd;
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
            TextConverter.InjectMode = S.InputMode;
            TextConverter.FocusHwnd = _fgFocus != IntPtr.Zero ? _fgFocus : _fgHwnd;
            // ТОЛЬКО SendInput (allowMessages=false): posted-комбинации модификаторов
            // чужие приложения обрабатывают нестабильно (WinUI-блокнот то выделяет,
            // то двигает каретку) — а без выделения copy/paste цепочка ломается.
            // Для стрелок это безопасно даже при блокировке SendInput.
            TextConverter.SendCombo(0x11, 0x10, 0x25, true, false);
            BeginFixSelection(true);
        }

        /// <summary>Break при нечего-отменять: детектор слово не сконвертировал, а юзер настаивает.
        /// Переворачиваем последнее слово принудительно (без словаря и скоринга) и выучиваем пару.</summary>
        public void ForceFlipLastWord()
        {
            UpdateForeground();
            // 1) каретка прямо после ещё не отправленного слова — буфер ещё жив
            if (_buf.Count >= 2)
            {
                Log("force-flip: current buffer (" + _buf.Count + " keys)");
                ForceConvertWord(_buf.Snapshot());
                return;
            }
            // 2) слово только что завершилось (разделитель уже ушёл в приложение) —
            //    точный откат по свежему снимку
            if (_lastWord.Count > 0 && unchecked(Environment.TickCount - _lastWordAt) < 1500)
            {
                Log("force-flip: exact path (last word)");
                ForceConvertWord(new List<KeyRec>(_lastWord));
                return;
            }
            // 3) каретка уже ушла — выделяем слово слева и конвертим как выделение
            Log("force-flip: select-left path");
            TextConverter.InjectMode = S.InputMode;
            TextConverter.FocusHwnd = _fgFocus != IntPtr.Zero ? _fgFocus : _fgHwnd;
            TextConverter.SendCombo(0x11, 0x10, 0x25, true, false);
            BeginFixSelection(true);
        }

        /// <summary>Безусловный переворот слова:cur -> лучший кандидат другой раскладки.
        /// Ставит точку отката (повторный Break вернёт как было и занесёт слово в «не трогать»),
        /// пару запоминает в accepted — автодетект дальше конвертит её сам.</summary>
        private bool ForceConvertWord(List<KeyRec> word)
        {
            UpdateForeground();
            if (IsExcludedHere()) { Log("force-flip skip: excluded app"); return false; }
            List<IntPtr> layouts = LayoutService.GetLayouts();
            if (layouts.Count < 2) { Log("force-flip skip: one layout"); return false; }
            List<LayoutCandidate> cands = LayoutService.RenderAll(word, layouts);

            LayoutCandidate cur = null;
            foreach (LayoutCandidate c in cands) if (c.Hkl == _fgHkl) { cur = c; break; }
            if (cur == null || cur.Lang < 0) { Log("force-flip skip: cur unknown"); return false; }

            LayoutCandidate best = null;
            foreach (LayoutCandidate c in cands)
            {
                if (c.Hkl == _fgHkl || c.Lang < 0) continue;
                if (best == null || c.Score > best.Score) best = c;
            }
            if (best == null || best.Text == cur.Text) { Log("force-flip skip: no other reading"); return false; }

            TextConverter.ReleaseModifiers();
            TextConverter.InjectMode = S.InputMode;
            TextConverter.FocusHwnd = _fgFocus != IntPtr.Zero ? _fgFocus : _fgHwnd;
            Log("force-flip: '" + cur.Text + "' -> '" + best.Text + "'");

            Suppress(600);
            TextConverter.SendBackspaces(word.Count);
            TextConverter.SendUnicode(best.Text);
            LayoutService.SwitchForegroundTo(_fgHwnd, best.Hkl);
            ExpectLayout(best.Hkl);

            // точка отката: повторный Break вернёт исходное слово; отмена занесёт
            // его в rejected — «самообучение» сработало в обратную сторону
            _undoPending = true;
            _undoText = cur.Text;
            _undoLen = best.Text.Length;
            _undoSep = 0;
            _undoHkl = cur.Hkl;
            _undoHwnd = _fgHwnd;
            _undoTick = Environment.TickCount;
            _keysSinceUndoPoint = 0;
            _undoTail.Clear();
            _undoTailBroken = false;

            string learned = cur.Text.ToLowerInvariant();
            Defer(delegate { RememberAccepted(learned); });
            FireInfo("Заучено: " + cur.Text + " → " + best.Text);
            return true;
        }

        // --- двухфазная конвертация выделенного текста ---
        // Фаза 1 (в хуке): только Ctrl+C и выход. Фаза 2 (таймер, вне хука): чтение
        // буфера, конвертация, вставка. Иначе инжектированный Ctrl+C не успевает
        // отработать, в буфере остаётся СТАРЫЙ текст и он вставится поверх выделения.

        private System.Windows.Forms.Timer _selTimer;
        private IntPtr _selFgHwnd;
        private IntPtr _selFocusHwnd;        // окно с фокусом ввода — ему шлём WM_COPY/WM_PASTE
        private int _selTries;
        private int _selPhase;               // 0 = ждём отпускания модификаторов, 1 = ждём буфер
        private bool _selFromFixWord;        // выделение слева от каретки (Ctrl+Space) — с ретраем
        private bool _selRetried;
        private int _selMethod;              // чем копировали: 0 = wm_copy, 1 = Ctrl+C инжекция
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
            _selFocusHwnd = _fgFocus != IntPtr.Zero ? _fgFocus : _fgHwnd;
            _selFromFixWord = fromFixWord;
            _selRetried = false;
            _selBaseline = TextConverter.GetClipboardTextOnce();
            _selBaseSeq = Native.GetClipboardSequenceNumber();
            _selPhase = 0;
            _selTries = 0;
            RestartSelTimer();
            Log("sel: started (baseline " + (_selBaseline != null ? _selBaseline.Length + " ch" : "empty") + ")");
        }

        private void StopSelTimer()
        {
            if (_selTimer != null) { _selTimer.Stop(); _selTimer.Dispose(); _selTimer = null; }
        }

        /// <summary>Перезапуск опроса буфера. Обязателен после каждого fallback-шага:
        /// раньше таймер уничтожался ДО fallback-веток, и цепочка
        /// wm_copy -> Ctrl+C -> ретрай умирала молча (Shift+Break не работал вовсе).</summary>
        private void RestartSelTimer()
        {
            StopSelTimer();
            _selTimer = new System.Windows.Forms.Timer();
            _selTimer.Interval = 60;
            _selTimer.Tick += SelPollTick;
            _selTimer.Start();
        }

        // буквенное сочетание шлём ТОЛЬКО SendInput (allowMessages=false):
        // posted Ctrl+C без обновлённого key-state чужое приложение может
        // прочитать как букву 'c' поверх выделения
        private void SelCopyByCtrlC()
        {
            TextConverter.ReleaseModifiers();
            TextConverter.InjectMode = S.InputMode;
            TextConverter.FocusHwnd = _selFocusHwnd;
            TextConverter.SendCombo(0x11, 0, 0x43, false, false);
        }

        private static string WindowClassOf(IntPtr hwnd)
        {
            var sb = new System.Text.StringBuilder(64);
            return Native.GetClassName(hwnd, sb, sb.Capacity) > 0 ? sb.ToString() : "";
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
                // сначала WM_COPY (не блокируется HIPS); не сработает — перейдём на Ctrl+C.
                // Хромиум-окна (Chrome_WidgetWin_1: Opera/Chrome/Edge/Electron) WM_COPY
                // не обрабатывают никогда — начинаем сразу с Ctrl+C, иначе каждое
                // исправление в браузере сгорает ~0.4 с на заведомо мёртвую попытку
                if (WindowClassOf(_selFocusHwnd) == "Chrome_WidgetWin_1")
                {
                    _selMethod = 1;
                    SelCopyByCtrlC();
                    RestartSelTimer();
                    Log("sel: chromium -> ctrl+c directly");
                    return;
                }
                _selMethod = 0;
                Native.PostMessage(_selFocusHwnd, Native.WM_COPY, IntPtr.Zero, IntPtr.Zero);
                Log("sel: wm_copy sent");
                return;
            }

            string text = TextConverter.GetClipboardTextOnce();
            bool seqChanged = Native.GetClipboardSequenceNumber() != _selBaseSeq;
            _selTries++;
            bool isNew = !string.IsNullOrEmpty(text) && (seqChanged || text != _selBaseline);
            // wm_copy либо отвечает за пару тиков, либо никогда (хромиум) —
            // на мёртвую попытку тратим не больше ~0.4 с; Ctrl+C-инжекции даём ~1.2 с
            int maxTries = _selMethod == 0 ? 7 : 20;
            if (!isNew && _selTries < maxTries) return;
            StopSelTimer(); // опрос завершён (успех или срок); fallback-ветки перезапустят

            if (string.IsNullOrEmpty(text) || !seqChanged)
            {
                // цепочка копирования: wm_copy -> Ctrl+C (инжекция) -> расширить до 2 слов -> сдаёмся
                if (_selMethod == 0)
                {
                    _selMethod = 1; // fallback: инжекция Ctrl+C
                    _selTries = 0;
                    SelCopyByCtrlC();
                    RestartSelTimer();
                    Log("sel: wm_copy failed -> ctrl+c injection");
                    return;
                }
                if (_selFromFixWord && !_selRetried)
                {
                    _selRetried = true;
                    _selPhase = 0;
                    _selTries = 0;
                    _selMethod = 0;
                    TextConverter.InjectMode = S.InputMode;
                    TextConverter.FocusHwnd = _selFocusHwnd;
                    // как и первая попытка — только SendInput (posted-комбо нестабильны)
                    TextConverter.SendCombo(0x11, 0x10, 0x25, true, false);
                    TextConverter.SendCombo(0x11, 0x10, 0x25, true, false);
                    RestartSelTimer();
                    Log("sel: retry with 2 words left");
                    return;
                }
                // буфер не обновился — выделение не скопировалось; вставлять старьё нельзя
                Log("sel: no new clipboard (seqChanged=" + seqChanged + ")");
                FireInfo("Не удалось скопировать выделение в этом приложении");
                return;
            }
            Log("sel: got " + text.Length + " chars (method=" + (_selMethod == 0 ? "wm_copy" : "ctrl+c") + ")");

            int lang = LanguageTables.LangOf(LanguageTables.LettersOnly(text));
            if (lang < 0)
            {
                Log("sel: lang unknown");
                FireInfo("Не удалось определить язык");
                return;
            }
            string converted = CharMaps.MapText(text, lang == 1);
            TextConverter.SetClipboardTextSafe(converted);
            // вставляем тем же способом, которым удалось скопировать
            if (_selMethod == 1)
            {
                TextConverter.ReleaseModifiers();
                TextConverter.InjectMode = S.InputMode;
                TextConverter.FocusHwnd = _selFocusHwnd;
                TextConverter.SendCombo(0x11, 0, 0x56, false, false); // Ctrl+V (только SendInput)
            }
            else
            {
                Native.PostMessage(_selFocusHwnd, Native.WM_PASTE, IntPtr.Zero, IntPtr.Zero);
            }
            Log("sel: pasted converted (" + lang + ", method=" + (_selMethod == 0 ? "wm" : "inj") + ")");

            // самообучение (Ctrl+Space / Break-flip): одно слово из букв — выучиваем пару,
            // автодетект в следующий раз перевернёт его сам
            if (_selFromFixWord && text.Length >= 2 && text.Length <= 24 &&
                text == LanguageTables.LettersOnly(text))
            {
                string learnedSel = text.ToLowerInvariant();
                Defer(delegate { RememberAccepted(learnedSel); });
            }

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
