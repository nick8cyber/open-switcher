# ADR-005: Механика ввода, изоляция отката и потокобезопасность (1.3.0)

Статус: принято (релиз 1.3.0). Платформы: macOS + Windows.

## Контекст

Комплексный архитектурный аудит версии 1.2 выявил класс системных сбоев при
реальной печати (фантомное стирание соседних слов, сбои в Chromium/Electron,
отравление `learned.txt`, гонки потоков на macOS и утечка GDI/краш DPI на Windows):

1. На Windows по умолчанию стоял `InputMode=1` (`WM_CHAR` + `WM_KEYDOWN(VK_BACK)`),
   который не работает в Chromium/Electron и части современных редакторов, а
   `BackspaceOnce` слал виртуальное нажатие вместо `\b`. Длинное окно `Suppress(600)`
   «глотало» или ломало быстрые `Enter`/`Tab`/`Backspace` сразу после конвертации.
2. Флаг автоматического обучения отказов мог переживать промежуточный ввод и
   навигацию: запоздалое нажатие `Ctrl+Z` или правка текста с последующим стиранием
   отправляли неверно отменённое слово в `learned.txt`. На Windows дополнительно
   счётчик `_keysSinceUndoPoint++` срабатывал до диспетчера `Ctrl+Z` в `OnKeyDown`.
3. На macOS потоки `CGEventTap`, `main` и `DistributedNotificationCenter` без
   блокировок обращались к общим настройкам (`Settings`), состоянию переднего окна
   (`_fg*`), AX-боксам (`TailCheckBox` / `SelectedTextBox`) и асинхронной записи
   файлов обучения (`learned.txt` / `accepted.txt`), а `single-instance` через
   `/tmp/com.openswitcher.pid` был подвержен TOCTOU-гонкам и reuse PID.
4. Детектор формы ложно срабатывал на словах с конечной пунктуацией (`here.`),
   именах файлов/доменах (`main.py`, `vk.ru`), CLI-флагах (`-rf`, `--help`),
   инвертированном `CapsLock` (`gHBDTN`), а на русских раскладках путались
   IME/UA/BY источники и парные Shift-символы (`:<>"{}~` ⇄ `ЖБЮЭХЪЁ`).

## Решение

1. **Канал ввода и `suppress` на Windows (`Settings.cs`, `TextConverter.cs`, `Engine.cs`):**
   - Дефолт переключён на `InputMode = 0` (`SendInput` + `KEYEVENTF_UNICODE`) с
     однократной миграцией `DefaultsV = 9`. Режим `InputMode = 1` остаётся как
     явная опция в настройках для систем со строгим HIPS; внутри `WM_CHAR`-режима
     `BackspaceOnce` для `Edit`/`RichEdit` контролов шлёт `PostChar(hwnd, '\b')`.
   - Окно `Suppress` сокращено с `600` до `200 мс`; внутри окна `Enter`, `Tab`,
     `Esc`, навигация, `Break`, `Ctrl+Z` и `Backspace` корректно обновляют буфер
     и состояние отката вместо потери событий.
2. **Строгая изоляция отката и обучения (`autoRejectEligible`):**
   - `autoRejectEligible` взводится только после автозамены и мгновенно сбрасывается
     при любом не-BS вводе, `Enter`, навигации, клике мыши, смене фокуса/окна и
     модификаторах (кроме чистого `Ctrl+Z` / `Cmd+Z`).
   - В Windows `KeyboardProc` исключение сделано для чистого `Ctrl+Z` (рядом с
     `VK_BACK`), чтобы счётчик `_keysSinceUndoPoint` не ломал откат до `OnKeyDown`.
   - `WordDict` запоминает `accepted` (RU→EN ручной переворот) только если исходное
     слово не является возможным русским, а целевое есть в `hasCore`/`HasCore`.
3. **Защита от ложных срабатываний, карты и раскладки:**
   - Введены `curCore = lettersOnly(cur.text)`, защита доменов/файлов
     (`IsDomainOrFileName` / `isDomainOrFileName`), поддержка дефисных слов с
     отклонением ведущих `-` (`-rf`, `--help`), двунаправленная карта Shift-символов
     (`:<>"{}~` ⇄ `ЖБЮЭХЪЁ`) + корректные OEM VK-коды (`VkOfChar`), фильтр
     инвертированного `CapsLock` (`gHBDTN`) и разделение RU `ALL_CAPS` (`XNJ`→`ЧТО`)
     и EN-акронимов (`API`, `SQL`).
   - На macOS и Windows фильтруются IME и соседние кириллические раскладки (UA/BY),
     нормализуются `Ë`/`ё` на русской раскладке, добавлен флаг `flags = 4u` для
     `ToUnicodeEx` на Win10+, фильтрация автоповтора и поддержка Numpad-клавиш.
4. **Потокобезопасность macOS, UI/DPI Windows и CI:**
   - `Engine.swift`: добавлены `stateLock` (защищает `_s`, `_fg*`, `_lastExternalProc`,
     `_switchSerial`, `_exclusionList`, `_uiSettingsActive`, `_sandboxFocused`),
     `Settings.clone()`, сериализация дисковых операций на `ioQueue`, подписки
     `DistributedNotificationCenter` строго на `queue: .main`, а `main.swift` переведён
     на `flock(LOCK_EX | LOCK_NB)` файла `openswitcher.lock`.
   - `UiTheme.cs` / `SettingsForm.cs` / `Program.cs`: кэширование GDI `Font`, DPI-масштабирование
     без `.NET 4.7 DeviceDpi` и с фоллбэком для Win 8.1, перенос `os_crash.log` в
     `SettingsStore.Dir` и полный `Dispose()` хуков и таймеров.
   - `.github/workflows/release.yml`: сборка Windows и macOS артефактов разделена от
     единого финального job `release` (устранена гонка публикаций в GitHub Releases).

## Следствия

- Windows `OpenSwitcher.exe` работает «из коробки» во всех современных браузерах,
  мессенджерах и редакторах без проблем `WM_CHAR`.
- Отказ по `Ctrl+Z` / `Backspace` работает предсказуемо и не отравляет пользовательский
  словарь `learned.txt` при обычном редактировании текста.
- macOS-демон не содержит гонок ARC/потоков между `CGEventTap`, `main` и фоновыми очередями.
