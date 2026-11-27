import Foundation

/// Биты модификаторов для хоткеев (порт HK).
public enum HK {
    public static let CTRL = 1
    public static let SHIFT = 2
    public static let ALT = 4
    public static let CMD = 8   // аналог WIN
}

public final class Settings {
    public static let defaultMacExclusions = "terminal, iterm, iterm2, warp, ghostty, alacritty, kitty, bitwarden, 1password, keychain access, связка ключей"

    // --- автоправка
    public var fixOnEnter = true
    public var autoConvertOnWordEnd = true
    public var minWordLen = 3
    public var sensitivity = 1.0

    // --- хоткеи (macOS keycodes). F15 (0x71 = Pause/Break) больше не дефолт:
    // клавиши нет на современных Mac-клавиатурах (defaultsV 9).
    public var hotUndoVk: Int = 0
    public var hotUndoMods: Int = 0
    public var hotFixWordVk: Int = KeyCodeMap.space
    public var hotFixWordMods: Int = HK.CTRL
    public var hotFixSelVk: Int = 0
    public var hotFixSelMods: Int = 0
    public var hotRuVk: Int = KeyCodeMap.leftShift
    public var hotRuMods: Int = 0
    public var hotEnVk: Int = KeyCodeMap.rightShift
    public var hotEnMods: Int = 0
    public var hotAutoToggleVk: Int = 0
    public var hotAutoToggleMods: Int = 0
    public var hotPasteVk: Int = 0x09            // «V» — вставить без форматирования (как в Caramba)
    public var hotPasteMods: Int = HK.CMD | HK.SHIFT
    public var lockAutoAfterManualSwitch = true
    public var doubleShiftSwitch = true

    // --- жесты «как в Caramba»
    public var optionFlip = true        // голый тап Option — принудительный переворот слова (пинг-понг)
    public var pastePlain = true        // хоткей «вставить без форматирования» включён
    public var shiftShiftToggle = false // оба Shift одновременно — вкл/выкл автопереключения

    // --- система
    public var showPopup = true
    public var restoreClipboard = true
    public var devLog = false  // режим разработчика: вести журнал решений в файл
    public var spaceDedupMs = 0 // дедуп двойных пробелов (0 = выкл)
    public var tapMinMs = 0 // тап короче N мс не переключает раскладку (0 = дефолтный анти-дребезг 15 мс)
    public var startWithSystem = false
    public var paused = false
    public var exclusions = Settings.defaultMacExclusions
    public var pasteConvertApps = "" // устаревшее ini-поле (сохранено для совместимости чтения/записи)
    public var themeMode = 0 // 0 системная / 1 светлая / 2 тёмная
    public var defaultsV = 12

    public init() {}

    public func clone() -> Settings {
        let c = Settings()
        c.fixOnEnter = fixOnEnter
        c.autoConvertOnWordEnd = autoConvertOnWordEnd
        c.minWordLen = minWordLen
        c.sensitivity = sensitivity
        c.hotUndoVk = hotUndoVk
        c.hotUndoMods = hotUndoMods
        c.hotFixWordVk = hotFixWordVk
        c.hotFixWordMods = hotFixWordMods
        c.hotFixSelVk = hotFixSelVk
        c.hotFixSelMods = hotFixSelMods
        c.hotRuVk = hotRuVk
        c.hotRuMods = hotRuMods
        c.hotEnVk = hotEnVk
        c.hotEnMods = hotEnMods
        c.hotAutoToggleVk = hotAutoToggleVk
        c.hotAutoToggleMods = hotAutoToggleMods
        c.hotPasteVk = hotPasteVk
        c.hotPasteMods = hotPasteMods
        c.lockAutoAfterManualSwitch = lockAutoAfterManualSwitch
        c.doubleShiftSwitch = doubleShiftSwitch
        c.optionFlip = optionFlip
        c.pastePlain = pastePlain
        c.shiftShiftToggle = shiftShiftToggle
        c.showPopup = showPopup
        c.restoreClipboard = restoreClipboard
        c.devLog = devLog
        c.spaceDedupMs = spaceDedupMs
        c.tapMinMs = tapMinMs
        c.startWithSystem = startWithSystem
        c.paused = paused
        c.exclusions = exclusions
        c.pasteConvertApps = pasteConvertApps
        c.themeMode = themeMode
        c.defaultsV = defaultsV
        return c
    }
}

public enum SettingsStore {
    public static var dir: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("OpenSwitcher").path
    }

    static var filePath: String { dir + "/settings.ini" }

    public static func load() -> Settings {
        var s = Settings()
        guard let text = try? String(contentsOfFile: filePath, encoding: .utf8) else { return s }
        for line in text.components(separatedBy: .newlines) { applyLine(s, line) }
        migrate(&s)
        return s
    }

    /// Миграции дефолтов (точное совпадение со старым дефолтом —
    /// кастомные хоткеи юзера не трогаем).
    static func migrate(_ s: inout Settings) {
        var migrated = false
        if s.defaultsV < 9 {
            if s.hotUndoVk == KeyCodeMap.f15 {
                s.hotUndoVk = 0
                s.hotUndoMods = 0
            }
            if s.hotFixSelVk == KeyCodeMap.f15 && s.hotFixSelMods == HK.SHIFT {
                s.hotFixSelVk = 0
                s.hotFixSelMods = 0
            }
            s.defaultsV = 9
            migrated = true
        }
        if s.defaultsV < 10 {
            s.defaultsV = 10
            migrated = true
        }
        if s.defaultsV < 11 {
            s.lockAutoAfterManualSwitch = true
            s.defaultsV = 11
            migrated = true
        }
        if s.defaultsV < 12 {
            // defaultsV 12: замена старого виндового списка .exe / пустого дефолта на macOS-приложения
            // (терминалы и менеджеры паролей) и очистка устаревшего PasteConvertApps
            let trimmed = s.exclusions.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.contains(".exe") {
                s.exclusions = Settings.defaultMacExclusions
            }
            s.pasteConvertApps = ""
            s.defaultsV = 12
            migrated = true
        }
        if migrated { save(s) }
    }

    static func applyLine(_ s: Settings, _ line: String) {
        guard let i = line.firstIndex(of: "=") else { return }
        let k = String(line[..<i]).trimmingCharacters(in: .whitespaces)
        let v = String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
        switch k {
        case "FixOnEnter": s.fixOnEnter = v == "1"
        case "AutoConvertOnWordEnd": s.autoConvertOnWordEnd = v == "1"
        case "DoubleShiftSwitch": s.doubleShiftSwitch = v == "1"
        case "OptionFlip": s.optionFlip = v == "1"
        case "PastePlain": s.pastePlain = v == "1"
        case "ShiftShiftToggle": s.shiftShiftToggle = v == "1"
        case "ShowPopup": s.showPopup = v == "1"
        case "RestoreClipboard": s.restoreClipboard = v == "1"
        case "DevLog": s.devLog = v == "1"
        case "StartWithWindows", "StartWithSystem": s.startWithSystem = v == "1"
        case "Paused": s.paused = v == "1"
        case "SpaceDedupMs": s.spaceDedupMs = max(0, min(3000, Int(v) ?? 0))
        case "TapMinMs": s.tapMinMs = max(0, min(500, Int(v) ?? 0))
        case "MinWordLen": s.minWordLen = max(2, min(8, Int(v) ?? 3))
        case "Sensitivity": s.sensitivity = Double(v) ?? 1.0
        case "HotFixWordVk": s.hotFixWordVk = Int(v) ?? s.hotFixWordVk
        case "HotFixWordMods": s.hotFixWordMods = Int(v) ?? s.hotFixWordMods
        case "HotFixSelVk": s.hotFixSelVk = Int(v) ?? s.hotFixSelVk
        case "HotFixSelMods": s.hotFixSelMods = Int(v) ?? s.hotFixSelMods
        case "HotRuVk": s.hotRuVk = Int(v) ?? s.hotRuVk
        case "HotRuMods": s.hotRuMods = Int(v) ?? s.hotRuMods
        case "HotEnVk": s.hotEnVk = Int(v) ?? s.hotEnVk
        case "HotEnMods": s.hotEnMods = Int(v) ?? s.hotEnMods
        case "HotAutoToggleVk": s.hotAutoToggleVk = Int(v) ?? s.hotAutoToggleVk
        case "HotAutoToggleMods": s.hotAutoToggleMods = Int(v) ?? s.hotAutoToggleMods
        case "HotUndoVk": s.hotUndoVk = Int(v) ?? s.hotUndoVk
        case "HotUndoMods": s.hotUndoMods = Int(v) ?? s.hotUndoMods
        case "HotPasteVk": s.hotPasteVk = Int(v) ?? s.hotPasteVk
        case "HotPasteMods": s.hotPasteMods = Int(v) ?? s.hotPasteMods
        case "LockAutoAfterManualSwitch": s.lockAutoAfterManualSwitch = v == "1"
        case "PasteConvertApps": s.pasteConvertApps = v
        case "Exclusions": s.exclusions = v
        case "ThemeMode": s.themeMode = max(0, min(2, Int(v) ?? 0))
        case "DefaultsV": s.defaultsV = Int(v) ?? 0
        default: break
        }
    }

    @discardableResult
    public static func save(_ s: Settings) -> Bool {
        let lines = [
            "FixOnEnter=\(s.fixOnEnter ? 1 : 0)",
            "AutoConvertOnWordEnd=\(s.autoConvertOnWordEnd ? 1 : 0)",
            "DoubleShiftSwitch=\(s.doubleShiftSwitch ? 1 : 0)",
            "OptionFlip=\(s.optionFlip ? 1 : 0)",
            "PastePlain=\(s.pastePlain ? 1 : 0)",
            "ShiftShiftToggle=\(s.shiftShiftToggle ? 1 : 0)",
            "ShowPopup=\(s.showPopup ? 1 : 0)",
            "RestoreClipboard=\(s.restoreClipboard ? 1 : 0)",
            "DevLog=\(s.devLog ? 1 : 0)",
            "SpaceDedupMs=\(s.spaceDedupMs)",
            "TapMinMs=\(s.tapMinMs)",
            "StartWithSystem=\(s.startWithSystem ? 1 : 0)",
            "Paused=\(s.paused ? 1 : 0)",
            "MinWordLen=\(s.minWordLen)",
            "Sensitivity=\(String(format: "%.1f", s.sensitivity))",
            "HotFixWordVk=\(s.hotFixWordVk)",
            "HotFixWordMods=\(s.hotFixWordMods)",
            "HotFixSelVk=\(s.hotFixSelVk)",
            "HotFixSelMods=\(s.hotFixSelMods)",
            "HotRuVk=\(s.hotRuVk)",
            "HotRuMods=\(s.hotRuMods)",
            "HotEnVk=\(s.hotEnVk)",
            "HotEnMods=\(s.hotEnMods)",
            "HotAutoToggleVk=\(s.hotAutoToggleVk)",
            "HotAutoToggleMods=\(s.hotAutoToggleMods)",
            "HotUndoVk=\(s.hotUndoVk)",
            "HotUndoMods=\(s.hotUndoMods)",
            "HotPasteVk=\(s.hotPasteVk)",
            "HotPasteMods=\(s.hotPasteMods)",
            "LockAutoAfterManualSwitch=\(s.lockAutoAfterManualSwitch ? 1 : 0)",
            "PasteConvertApps=\(s.pasteConvertApps)",
            "Exclusions=\(s.exclusions)",
            "ThemeMode=\(s.themeMode)",
            "DefaultsV=\(s.defaultsV)",
        ]
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try lines.joined(separator: "\n").appending("\n")
                .write(toFile: filePath, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}

/// Автозапуск через LaunchAgent (аналог Run-ключа реестра).
public enum Autostart {
    static var plistPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.openswitcher.app.plist").path
    }

    public static func setEnabled(_ on: Bool) {
        let domain = "gui/\(getuid())"
        if !on {
            if Process.runSync("/bin/launchctl", ["bootout", domain, plistPath]) != 0 {
                _ = Process.runSync("/bin/launchctl", ["unload", plistPath])
            }
            try? FileManager.default.removeItem(atPath: plistPath)
            return
        }
        let exe = xmlEscape(Bundle.main.executableURL?.path ?? CommandLine.arguments[0])
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.openswitcher.app</string>
            <key>ProgramArguments</key>
            <array><string>\(exe)</string></array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><false/>
        </dict>
        </plist>
        """
        try? FileManager.default.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        _ = Process.runSync("/bin/launchctl", ["bootout", domain, plistPath])
        _ = Process.runSync("/bin/launchctl", ["unload", plistPath])
        try? plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
        if Process.runSync("/bin/launchctl", ["bootstrap", domain, plistPath]) != 0 {
            _ = Process.runSync("/bin/launchctl", ["load", plistPath])
        }
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    public static func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }
}

extension Process {
    @discardableResult
    static func runSync(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }
}
