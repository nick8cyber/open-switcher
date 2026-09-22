import AppKit
import OpenSwitcherKit

/// Точка входа (порт Program.cs): single-instance, аргументы, трей, настройки.
enum App {
    static var engine: Engine!
    static var statusItem: StatusItemService!

    /// pid-файл single-instance (аналог мьютекса); при падении не остаётся
    /// мёртвым замком — pid проверяется через kill(pid, 0).
    static let pidPath = "/tmp/com.openswitcher.pid"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // LSUIElement-режим: без Dock-иконки

        let settings = SettingsStore.load()
        UiTheme.shared.applyMode(settings.themeMode)

        App.engine = Engine(settings)
        App.statusItem = StatusItemService(engine: App.engine)
        App.statusItem.initItem()

        // внешняя смена раскладки (системное меню, юзер) — инвалидирует
        // висящие verifySwitch-ретраи движка и сразу обновляет TIS-кэш
        // (TIS-вызовы — только на main, поэтому main.async: блок наблюдателя
        // с queue: nil исполняется на произвольном потоке)
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleSelectedInputSourceChangedNotification"), object: nil, queue: nil) { _ in
            App.engine?.bumpSwitchSerial()
            DispatchQueue.main.async { LayoutService.refreshOnMain() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: nil) { _ in
            DispatchQueue.main.async {
                UiTheme.shared.refreshFromSystem()
                ThemeEnv.shared.refresh()
            }
        }
        UiTheme.shared.changed = {
            DispatchQueue.main.async {
                App.statusItem.updateTooltip()
                ThemeEnv.shared.refresh()
            }
        }

        // «--settings» при старте
        if CommandLine.arguments.contains("--settings") {
            App.statusItem.showSettings()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // живём в строке меню
    }

    func applicationWillTerminate(_ notification: Notification) {
        // удаляем pid-файл только если он наш (второй инстанс мог перезаписать своим)
        if let data = FileManager.default.contents(atPath: App.pidPath),
           let pid = Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespaces)),
           pid == getpid() {
            try? FileManager.default.removeItem(atPath: App.pidPath)
        }
    }
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--selftest") {
    let out = i + 1 < args.count ? args[i + 1] : "selftest_result.txt"
    exit(Int32(SelfTest.run(out)))
}
if let i = args.firstIndex(of: "--simtest"), i + 1 < args.count {
    exit(Int32(SelfTest.simulate(args[i + 1], sensitivity: 1.0)))
}

// --- crash-хендлер (порт Program.cs:19-31): UnhandledException пишет os_crash.log ---
enum CrashLog {
    static let path = SettingsStore.dir + "/os_crash.log"

    /// NSException: время + стектрей (аллокации допустимы — это не signal-контекст).
    static func install() {
        try? FileManager.default.createDirectory(atPath: SettingsStore.dir,
                                                 withIntermediateDirectories: true)
        NSSetUncaughtExceptionHandler { ex in
            let text = "\(Date()) OpenSwitcher: uncaught NSException \(ex.name.rawValue)\n"
                + "reason: \(ex.reason ?? "-")\n"
                + ex.callStackSymbols.joined(separator: "\n") + "\n"
            try? text.write(toFile: CrashLog.path, atomically: true, encoding: .utf8)
        }
        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGTRAP] {
            signal(sig, osCrashOnSignal)
        }
        // прогрев lazy-глобалов хендлера здесь, в обычном контексте:
        // в signal-хендлере ленивая инициализация невозможна
        _ = (osCrashLogCPath.count, osSigAbortMsg.count, osSigIllMsg.count,
             osSigSegvMsg.count, osSigFpeMsg.count, osSigTrapMsg.count)
    }
}

// Строки «signal N» собраны заранее: хендлер делает только open/write/close
// (async-signal-safe), никаких интерполяций и аллокаций.
private let osCrashLogCPath: [CChar] = Array((SettingsStore.dir + "/os_crash.log").utf8CString)
private let osSigAbortMsg: [CChar] = Array("OpenSwitcher: signal SIGABRT\n".utf8CString)
private let osSigIllMsg: [CChar] = Array("OpenSwitcher: signal SIGILL\n".utf8CString)
private let osSigSegvMsg: [CChar] = Array("OpenSwitcher: signal SIGSEGV\n".utf8CString)
private let osSigFpeMsg: [CChar] = Array("OpenSwitcher: signal SIGFPE\n".utf8CString)
private let osSigTrapMsg: [CChar] = Array("OpenSwitcher: signal SIGTRAP\n".utf8CString)

private func osCrashOnSignal(_ sig: Int32) {
    let msg: [CChar]
    switch sig {
    case SIGABRT: msg = osSigAbortMsg
    case SIGILL: msg = osSigIllMsg
    case SIGSEGV: msg = osSigSegvMsg
    case SIGFPE: msg = osSigFpeMsg
    case SIGTRAP: msg = osSigTrapMsg
    default: return // хендлер ставится только на пять сигналов выше
    }
    let fd = open(osCrashLogCPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if fd >= 0 {
        msg.withUnsafeBufferPointer { buf in
            _ = write(fd, buf.baseAddress, buf.count > 0 ? buf.count - 1 : 0)
        }
        close(fd)
    }
    // дефолтный диспоз и перевысыл — ядро фиксирует реальную причину краша
    signal(sig, SIG_DFL)
    raise(sig)
}
CrashLog.install()

// --- single-instance: живая копия = «открой настройки» у неё и выход
/// Жив ли pid И это наш процесс (защита от переиспользования PID чужим процессом).
func pidIsOurs(_ pid: Int) -> Bool {
    guard pid > 0, pid <= Int32.max, kill(pid_t(pid), 0) == 0 else { return false }
    var pathbuf = [CChar](repeating: 0, count: 4096)
    let len = proc_pidpath(pid_t(pid), &pathbuf, 4096)
    guard len > 0 else { return true } // путь недоступен — консервативно считаем живым
    let path = String(cString: pathbuf)
    return path == CommandLine.arguments[0]
        || path == Bundle.main.executableURL?.path
}

// атомарное создание (O_EXCL): два одновременных старта не смогут оба пройти
var running = false
let fd = open(App.pidPath, O_WRONLY | O_CREAT | O_EXCL, 0o644)
if fd >= 0 {
    let pidStr = "\(getpid())"
    _ = pidStr.withCString { write(fd, $0, strlen($0)) }
    close(fd)
} else if errno == EEXIST {
    // файл уже есть: живой ли это наш процесс?
    if let data = FileManager.default.contents(atPath: App.pidPath),
       let pid = Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespaces)),
       pidIsOurs(pid) {
        running = true
    } else {
        // мёртвый/чужой — забираем файл
        FileManager.default.createFile(atPath: App.pidPath, contents: Data("\(getpid())".utf8))
    }
} else {
    // неожиданная ошибка — работает без single-instance
}

if running {
    DistributedNotificationCenter.default().postNotificationName(
        NSNotification.Name("com.openswitcher.showSettings"), object: nil, deliverImmediately: true)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
DistributedNotificationCenter.default().addObserver(
    forName: NSNotification.Name("com.openswitcher.showSettings"), object: nil, queue: .main) { _ in
    App.statusItem?.showSettings()
}
app.run()
