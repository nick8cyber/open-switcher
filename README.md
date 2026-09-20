# OpenSwitcher

Автоисправление слов, набранных не в той раскладке (Ru ⇄ En) — открытый
аналог Punto Switcher / Caramba Switcher. Два приложения в одном репозитории:

| Папка | Платформа | Стек | Сборка |
|---|---|---|---|
| [`win/`](win/) | Windows 10/11 | C# (.NET Framework 4.x, WinForms) | `cd win && build.cmd` |
| [`macos/`](macos/) | macOS 13+ (Apple Silicon и Intel) | Swift 5.9, AppKit + CGEventTap + TIS | `cd macos && ./build.sh [arm64\|x86_64\|universal]` |

Логика детектора общая и зафиксирована в
[`docs/SPEC.md`](docs/SPEC.md) (v3): частоты/биграммы, ворота конвертации,
одиночные буквы по «словности», хвост-двойник, самообучение, откат.
Mac-порт синхронизирован со спекой и проходит общий selftest детектора.

## Скачать

Готовые сборки — в [Releases](../../releases) по тегам:

- `OpenSwitcher-win.zip` — Windows (anycpu, .NET Framework 4.x предустановлен);
- `OpenSwitcher-macOS-AppleSilicon.zip` — Mac на чипах M1…M-серии;
- `OpenSwitcher-macOS-Intel.zip` — старые Mac на Intel.

## Первый запуск

- **Windows**: `OpenSwitcher.exe` — иконка в трее. Настройки — левый клик.
- **macOS**: разрешение «Мониторинг ввода» (и при необходимости
  «Универсальный доступ») — приложение подхватит его само в течение 10 с.
  Подробнее в [`macos/README.md`](macos/README.md).

### Подпись и нотаризация (macOS)

Сборки подписываются сертификатом **Developer ID Application** и отправляются
в Apple на нотаризацию (Gatekeeper). Локально:

```bash
cd macos
./build.sh arm64
codesign --force --deep --options runtime --timestamp \
  --sign "Developer ID Application: <Имя> (TEAMID)" build/OpenSwitcher.app
APPLE_ID=... APPLE_APP_SPECIFIC_PASSWORD=... TEAM_ID=... ./notarize.sh build/OpenSwitcher.app
```

Автоматически — в CI по тегу (секреты `SIGN_IDENTITY`, `DEVELOPER_ID_P12`,
`P12_PASSWORD`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `TEAM_ID`).
Без нотаризации Gatekeeper попросит ПКМ → «Открыть» при первом запуске.

## Структура

```
docs/SPEC.md   поведенческая спецификация (норматив для обеих платформ)
win/           Windows-приложение (C#): src, tools, build.cmd
macos/         macOS-приложение (Swift): Package.swift, Sources, build.sh
```
