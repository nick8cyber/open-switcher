import Foundation

/// Биты модификаторов для хоткеев (порт HK).
public enum HK {
    public static let CTRL = 1
    public static let SHIFT = 2
    public static let ALT = 4
    public static let CMD = 8   // аналог WIN
}

public final class Settings {
    // --- автоправка
    public var fixOnEnter = true
    public var autoConvertOnWordEnd = true
    public var minWordLen = 3
    public var sensitivity = 1.0

    // --- хоткеи (macOS keycodes; F15 = Pause/Break)
    public var hotUndoVk: Int = KeyCodeMap.f15
    public var hotUndoMods: Int = 0
    public var hotFixWordVk: Int = KeyCodeMap.space
    public var hotFixWordMods: Int = HK.CTRL
    public var hotFixSelVk: Int = KeyCodeMap.f15
    public var hotFixSelMods: Int = HK.SHIFT
    public var hotRuVk: Int = KeyCodeMap.leftShift
    public var hotRuMods: Int = 0
    public var hotEnVk: Int = KeyCodeMap.rightShift
    public var hotEnMods: Int = 0
    public var hotAutoToggleVk: Int = 0
    public var hotAutoToggleMods: Int = 0
    public var lockAutoAfterManualSwitch = false // v3 §18: ВЫКЛ — тапы у юзера рефлекторные
    public var doubleShiftSwitch = true

    // --- система
    public var showPopup = true
    public var restoreClipboard = true
    public var startWithSystem = false
    public var paused = false
    public var exclusions = ""
    public var themeMode = 0 // 0 системная / 1 светлая / 2 тёмная
    public var defaultsV = 7
}

public enum SettingsStore {
    public static var dir: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("OpenSwitcher").path
    }

    static var filePath: String { dir + "/settings.ini" }

    public static func load() -> Settings {
        let s = Settings()
        guard let text = try? String(contentsOfFile: filePath, encoding: .utf8) else { return s }
        for line in text.components(separatedBy: .newlines) { applyLine(s, line) }
        return s
    }

    static func applyLine(_ s: Settings, _ line: String) {
        guard let i = line.firstIndex(of: "=") else { return }
        let k = String(line[..<i]).trimmingCharacters(in: .whitespaces)
        let v = String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
        switch k {
        case "FixOnEnter": s.fixOnEnter = v == "1"
        case "AutoConvertOnWordEnd": s.autoConvertOnWordEnd = v == "1"
        case "DoubleShiftSwitch": s.doubleShiftSwitch = v == "1"
        case "ShowPopup": s.showPopup = v == "1"
        case "RestoreClipboard": s.restoreClipboard = v == "1"
        case "StartWithWindows", "StartWithSystem": s.startWithSystem = v == "1"
        case "Paused": s.paused = v == "1"
        case "MinWordLen": s.minWordLen = max(2, min(8, Int(v) ?? 3))
        case "Sensitivity": s.sensitivity = Double(v) ?? 1.0
        case "HotFixWordVk": s.hotFixWordVk = Int(v) ?? s.hotFixWordVk  // битое значение — дефолт, как в C#
        case "HotFixWordMods": s.hotFixWordMods = Int(v) ?? s.hotFixWordMods  // битое значение — дефолт, как в C#
        case "HotFixSelVk": s.hotFixSelVk = Int(v) ?? s.hotFixSelVk  // битое значение — дефолт, как в C#
        case "HotFixSelMods": s.hotFixSelMods = Int(v) ?? s.hotFixSelMods  // битое значение — дефолт, как в C#
        case "HotRuVk": s.hotRuVk = Int(v) ?? s.hotRuVk  // битое значение — дефолт, как в C#
        case "HotRuMods": s.hotRuMods = Int(v) ?? s.hotRuMods  // битое значение — дефолт, как в C#
        case "HotEnVk": s.hotEnVk = Int(v) ?? s.hotEnVk  // битое значение — дефолт, как в C#
        case "HotEnMods": s.hotEnMods = Int(v) ?? s.hotEnMods  // битое значение — дефолт, как в C#
        case "HotAutoToggleVk": s.hotAutoToggleVk = Int(v) ?? s.hotAutoToggleVk  // битое значение — дефолт, как в C#
        case "HotAutoToggleMods": s.hotAutoToggleMods = Int(v) ?? s.hotAutoToggleMods  // битое значение — дефолт, как в C#
        case "HotUndoVk": s.hotUndoVk = Int(v) ?? s.hotUndoVk  // битое значение — дефолт, как в C#
        case "HotUndoMods": s.hotUndoMods = Int(v) ?? s.hotUndoMods  // битое значение — дефолт, как в C#
        case "LockAutoAfterManualSwitch": s.lockAutoAfterManualSwitch = v == "1"
        case "Exclusions": s.exclusions = v
        case "ThemeMode": s.themeMode = max(0, min(2, Int(v) ?? 0))
        case "DefaultsV": s.defaultsV = Int(v) ?? 0
        default: break
        }
    }

    public static func save(_ s: Settings) {
        let lines = [
            "FixOnEnter=\(s.fixOnEnter ? 1 : 0)",
            "AutoConvertOnWordEnd=\(s.autoConvertOnWordEnd ? 1 : 0)",
            "DoubleShiftSwitch=\(s.doubleShiftSwitch ? 1 : 0)",
            "ShowPopup=\(s.showPopup ? 1 : 0)",
            "RestoreClipboard=\(s.restoreClipboard ? 1 : 0)",
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
            "LockAutoAfterManualSwitch=\(s.lockAutoAfterManualSwitch ? 1 : 0)",
            "Exclusions=\(s.exclusions)",
            "ThemeMode=\(s.themeMode)",
            "DefaultsV=\(s.defaultsV)",
        ]
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").appending("\n").write(toFile: filePath, atomically: true, encoding: .utf8)
    }
}

/// Автозапуск через LaunchAgent (аналог Run-ключа реестра).
public enum Autostart {
    static var plistPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.openswitcher.app.plist").path
    }

    public static func setEnabled(_ on: Bool) {
        if !on {
            // unload по пути читает plist — снимаем загрузку ДО удаления файла
            Process.launch("/bin/launchctl", ["unload", plistPath])
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
        try? plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
        Process.launch("/bin/launchctl", ["unload", plistPath])
        Process.launch("/bin/launchctl", ["load", plistPath])
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
    static func launch(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
