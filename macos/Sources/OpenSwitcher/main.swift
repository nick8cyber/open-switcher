import AppKit
import OpenSwitcherKit

/// Точка входа (порт Program.cs): single-instance, аргументы, трей, настройки.
enum App {
    static var engine: Engine!
    static var statusItem: StatusItemService!

    /// Файл блокировки single-instance на flock(LOCK_EX|LOCK_NB):
    /// ядро само снимает замок при завершении или краше процесса, нет гонок PID.
    static var lockFd: Int32 = -1
    static var lockPath: String { SettingsStore.dir + "/openswitcher.lock" }

    /// Онбординг-окно разрешений. Engine (Core) зовёт его через хук
    /// Engine.showOnboardingHook — прямой зависимости Core → UI нет.
    static func showOnboarding() {
        OnboardingWindowController.show(engine: engine)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // LSUIElement-режим: без Dock-иконки

        let settings = SettingsStore.load()
        UiTheme.shared.applyMode(settings.themeMode)

        // хук онбординга — ДО создания Engine: startTap при провале уже в этом
        // тике ставит async-показ окна
        Engine.showOnboardingHook = { App.showOnboarding() }
        App.engine = Engine(settings)
        App.statusItem = StatusItemService(engine: App.engine)
        App.statusItem.initItem()

        // внешняя смена раскладки (системное меню, юзер) — инвалидирует
        // висящие verifySwitch-ретраи движка и сразу обновляет TIS-кэш
        // (P0-6: подписываемся строго на queue: .main — без гонок с произвольным потоком)
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleSelectedInputSourceChangedNotification"), object: nil, queue: .main) { _ in
            App.engine?.bumpSwitchSerial()
            LayoutService.refreshOnMain()
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { _ in
            UiTheme.shared.refreshFromSystem()
            ThemeEnv.shared.refresh()
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
        if App.lockFd >= 0 {
            close(App.lockFd)
            App.lockFd = -1
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

// --- single-instance через flock(LOCK_EX | LOCK_NB): без гонок /tmp и reuse PID
var running = false
try? FileManager.default.createDirectory(atPath: SettingsStore.dir, withIntermediateDirectories: true)
let lockFd = open(App.lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
if lockFd >= 0 {
    if flock(lockFd, LOCK_EX | LOCK_NB) == 0 {
        App.lockFd = lockFd
        ftruncate(lockFd, 0)
        let pidStr = "\(getpid())\n"
        _ = pidStr.withCString { write(lockFd, $0, strlen($0)) }
    } else if errno == EWOULDBLOCK || errno == EAGAIN {
        close(lockFd)
        running = true
    } else {
        close(lockFd)
    }
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
