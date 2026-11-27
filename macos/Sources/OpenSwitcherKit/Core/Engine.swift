import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore

/// Сердце программы: неблокирующий `CGEventTap`, буфер слова, детект неверной
/// раскладки, конвейерная инжекция исправлений (`injectorQueue`), самообучение
/// и безопасный откат автозамен.
public final class Engine {
    private let stateLock = NSLock()
    private var _s: Settings
    public var s: Settings {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _s }
        set { stateLock.lock(); _s = newValue; stateLock.unlock() }
    }

    private var tap: CFMachPort?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?

    /// Единая последовательная очередь синтетического ввода: гарантирует строгий
    /// FIFO-порядок `Backspace × N -> 25 мс settle -> посимвольный Unicode + sep`
    /// и никогда не блокирует поток `CGEventTap`.
    private let injectorQueue = DispatchQueue(label: "os.injector", qos: .userInteractive)
    /// Сколько задач сейчас выполняется в `injectorQueue` (читается и меняется на потоке тапа).
    private var inFlightInjections = 0

    private let buf = WordBuffer()
    private var lastWord: [KeyRec] = []
    private var lastWordAt: TimeInterval = 0
    private var lastWordSepKey = 0        // разделитель сразу после последнего слова (0 = неизвестен/Enter)
    private var lastWordSepShift = false  // ... набран с Shift ('?', '!', RU ',')
    private var lastWordApp: pid_t = 0    // приложение, где набрано последнее слово
    private var lastBsAt: TimeInterval = 0
    private var lastPasteAt: TimeInterval = 0

    /// Токен помечен как код/логин/URL/путь (встретилась цифра, '_', '/', '@', '#') —
    /// авто-конвертация его не трогает до следующей чистой границы (пробел / Enter).
    private var wordTainted = false

    // ретро-флип одиночной буквы (§7): 'f␣ns' -> «а ты»
    private var prevSingle: [KeyRec]? = nil
    private var prevSingleLayoutID: String? = nil
    private var prevSingleApp: pid_t = 0
    private var boundaryClean = true
    private var wordStartClean = false
    private var wordStartLayoutID: String? = nil

    private var noFlipUntil: TimeInterval = 0
    private var markCount = 0
    private var wdTicks = 0
    private var suppressUntil: TimeInterval = 0

    // тап-клавиши смены раскладки (Shift / CapsLock / др.) и двойной Shift
    private var lastShiftDown: TimeInterval = 0
    private var anyKeySinceShift = true
    private var tapVk = 0
    private var lastTapDoneAt: TimeInterval = 0
    private var tapTarget = 0              // 0 = РУС, 1 = ENG
    private var tapDownAt: TimeInterval = 0
    private var tapAlone = false

    // Option-тап «как в Caramba» (принудительный переворот слова / быстрый откат ложной автозамены)
    private var optTapVk = 0
    private var optTapDownAt: TimeInterval = 0
    private var shiftPairClean = false

    // лок автодетекта после ручного выбора языка
    private var autoLocked = false
    private var autoLockedAt: TimeInterval = 0
    private var autoLockedLang = -1        // язык, выбранный вручную (0 = RU, 1 = EN, -1 = неизвестен)
    private var autoLockedWordsTyped = 0   // сколько слов уже набрано после ручного переключения

    private var lastInputAt: TimeInterval = 0
    private var lastLetterAt: TimeInterval = 0
    private var lastSpaceTextTick: TimeInterval = 0

    /// Физические клавиши, чей `keyDown` мы проглотили: их парный `keyUp` тоже глотаем,
    /// чтобы в React/Electron/Telegram не прилетал осиротевший `Space`/`Enter` keyUp.
    private var swallowedKeys: Set<Int> = []

    private var layoutRefreshTimer: Timer?

    // точка отката последней замены
    private var undoPending = false
    private var undoFromAuto = false       // true = точка поставлена АВТО-конвертацией (для авто-отказа по BS/Cmd+Z)
    private var autoRejectEligible = false // P0-4: выживает ТОЛЬКО на серии чистых BS или мгновенных Cmd+Z / Opt+BS без промежуточного ввода
    private var undoText = ""
    private var undoConvertedTail = ""     // P0-7: реально напечатанный у каретки хвост (для AX-гейта отката)
    private var undoLen = 0
    private var undoErasedByBs = 0         // сколько символов заменённого слова юзер уже стёр Backspace'ом
    private var undoPrefix = ""
    private var undoPrefixLen = 0
    private var undoSepText = ""
    private var undoLayout: LayoutService.LayoutData?
    private var undoApp: pid_t = 0
    private var undoAt: TimeInterval = 0
    private var keysSinceUndoPoint = 0
    private var undoTail: [KeyRec] = []
    private var undoTailBroken = false
    private var lastConvertInfo = "-"

    // ожидаемая раскладка и компенсация TIS-лага
    private var expectedLayoutID: String?
    private var expectedApp: pid_t = 0
    private var expectGraceUntil: TimeInterval = 0
    private var _switchSerial = 0
    private var switchSerial: Int {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _switchSerial }
        set { stateLock.lock(); _switchSerial = newValue; stateLock.unlock() }
    }

    /// Компенсация лага `TISSelectInputSource`: пока фактическая раскладка ОС не догнала
    /// `gapLayout` (до `gapDeadline`), нажатые клавиши переводятся в `gapLayout` и
    /// отправляются через `injectorQueue` без задержки отображения и без перестановки букв.
    private var gapActive = false
    private var gapLayout: LayoutService.LayoutData?
    private var gapDeadline: TimeInterval = 0

    // самообучение
    private var rejected = Set<String>()
    private var accepted = Set<String>()
    private let rejectedCap = 1000
    private let learnedLock = NSLock()

    // состояние переднего приложения и AXObserver его окон/фокуса (синхронизировано через stateLock)
    private var _fgApp: pid_t = 0
    private var _fgProc = ""
    private var _lastExternalProc = ""
    private var _fgExec = ""
    private var _fgBundle = ""
    private var _fgIsOwnApp = false
    private var fgApp: pid_t { stateLock.lock(); defer { stateLock.unlock() }; return _fgApp }
    private var fgProc: String { stateLock.lock(); defer { stateLock.unlock() }; return _fgProc }
    private var fgExec: String { stateLock.lock(); defer { stateLock.unlock() }; return _fgExec }
    private var fgBundle: String { stateLock.lock(); defer { stateLock.unlock() }; return _fgBundle }
    private var fgIsOwnApp: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _fgIsOwnApp }
    private var procCache: [pid_t: (proc: String, exec: String, bundle: String)] = [:]
    private var axObserver: AXObserver?
    private var axObservedPid: pid_t = 0
    private var lastFocusedElementHash: CFHashCode = 0

    private var _uiSettingsActive = false
    private var _sandboxFocused = false
    private var _inputSeq: UInt64 = 0
    private func bumpInputSeq() { stateLock.lock(); _inputSeq &+= 1; stateLock.unlock() }
    private var currentInputSeq: UInt64 { stateLock.lock(); defer { stateLock.unlock() }; return _inputSeq }
    public var uiSettingsActive: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _uiSettingsActive }
        set { stateLock.lock(); _uiSettingsActive = newValue; stateLock.unlock() }
    }
    public var sandboxFocused: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _sandboxFocused }
        set { stateLock.lock(); _sandboxFocused = newValue; stateLock.unlock() }
    }

    private var onboardingAutoShown = false
    private var readyInfoFired = false

    public static var showOnboardingHook: (() -> Void)?

    static func showOnboarding() {
        DispatchQueue.main.async { showOnboardingHook?() }
    }

    public var onConverted: ((String, String) -> Void)?
    public var onInfo: ((String) -> Void)?
    public var onSettingsApplied: (() -> Void)?

    static let ms: () -> TimeInterval = { CACurrentMediaTime() }

    public init(_ settings: Settings) {
        _s = settings
        _exclusionList = Engine.parseExclusions(settings.exclusions)
        _ = WordDict.ruBig
        _ = WordDict.enBig
        LanguageTables.ensureBigSets()
        _ = LanguageTables.possibleWord("тест", 0)
        _ = LanguageTables.possibleWord("test", 1)
        loadLearned()
        startLayoutRefreshTimer()
        if ProcessInfo.processInfo.environment["OS_DISABLE_TAP"] != "1" {
            startTap()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.checkConflictingSwitchersOnMain()
            }
        }
        watchForeground()
    }

    deinit {
        layoutRefreshTimer?.invalidate()
        teardownAxObserverOnMain()
        stopTap()
    }

    private func startLayoutRefreshTimer() {
        layoutRefreshTimer?.invalidate()
        LayoutService.refreshOnMain()
        PasswordGuard.refreshOnMain()
        let t = Timer(timeInterval: 0.25, repeats: true) { _ in
            LayoutService.refreshOnMain()
            PasswordGuard.refreshOnMain()
        }
        RunLoop.main.add(t, forMode: .common)
        layoutRefreshTimer = t
    }

    public func apply(_ settings: Settings) {
        let parsed = Engine.parseExclusions(settings.exclusions)
        stateLock.lock()
        _s = settings
        _exclusionList = parsed
        stateLock.unlock()
        if Thread.isMainThread {
            onSettingsApplied?()
        } else {
            DispatchQueue.main.async { [weak self] in self?.onSettingsApplied?() }
        }
    }

    // --------------------------------------------------------- детектор конфликтов

    private static let conflictingBundles: [(id: String, name: String)] = [
        ("tech.caramba.switcher", "Caramba Switcher"),
        ("ru.yandex.desktop.PuntoSwitcher", "Punto Switcher"),
    ]

    private func checkConflictingSwitchersOnMain() {
        dispatchPrecondition(condition: .onQueue(.main))
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            let bid = app.bundleIdentifier ?? ""
            let lname = (app.localizedName ?? "").lowercased()
            if let hit = Self.conflictingBundles.first(where: { $0.id == bid }) {
                logLine("CONFLICT: обнаружен запущенный \(hit.name) (pid=\(app.processIdentifier))")
                fireInfo("Конфликт: запущен \(hit.name) — закройте его, иначе ввод будет ломаться")
                return
            }
            if lname.contains("caramba switcher") || lname.contains("punto switcher") {
                let title = app.localizedName ?? "другой свитчер"
                logLine("CONFLICT: обнаружен запущенный \(title) (pid=\(app.processIdentifier))")
                fireInfo("Конфликт: запущен \(title) — закройте его")
                return
            }
        }
    }

    // ------------------------------------------------------------------ хук (CGEventTap)

    private func createTapPort() -> CFMachPort? {
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        return CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                 options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                 callback: { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<Engine>.fromOpaque(refcon).takeUnretainedValue()
            return me.tapCallback(proxy: proxy, type: type, event: event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
    }

    private func startTap() {
        guard let port = createTapPort() else {
            logLine("tap FAILED: нет разрешения («Универсальный доступ»)")
            onboardingAutoShown = true
            Self.showOnboarding()
            ensureTapThread()
            return
        }
        tap = port
        ensureTapThread(initialPort: port)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.onboardingCheckOnMain() }
    }

    private func ensureTapThread(initialPort: CFMachPort? = nil) {
        guard tapThread == nil else { return }
        let port = initialPort
        let thread = Thread { [weak self] in
            let rlCF = RunLoop.current.getCFRunLoop()
            self?.tapRunLoop = rlCF
            if let port = port ?? self?.tap {
                CFRunLoopAddSource(rlCF, CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0), .commonModes)
            }
            CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, 0, 60, 0, 0) { _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    let post = CGPreflightPostEventAccess()
                    let listen = CGPreflightListenEventAccess()
                    let ax = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary)
                    let tapAlive = self.tap != nil
                    self.logLine(String(format: "perms: post=%d listen=%d ax=%d tapAlive=%d", post ? 1 : 0, listen ? 1 : 0, ax ? 1 : 0, tapAlive ? 1 : 0))
                }
            }.map { CFRunLoopAddTimer(rlCF, $0, .commonModes) }

            CFRunLoopAddTimer(rlCF, CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, 0, 10, 0, 0) { [weak self] _ in
                guard let self = self else { return }
                if let t = self.tap {
                    if !CGEvent.tapIsEnabled(tap: t) {
                        CGEvent.tapEnable(tap: t, enable: true)
                        self.resetTapState()
                        self.logLine("tap REVIVED after death")
                    } else if self.wdTicks % 10 == 9 {
                        self.logLine("watchdog: heartbeat ok")
                    }
                    self.wdTicks += 1
                    self.onboardingCheckAsync()
                } else if let port = self.createTapPort() {
                    self.tap = port
                    CFRunLoopAddSource(CFRunLoopGetCurrent(),
                                       CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0), .commonModes)
                    self.resetTapState()
                    self.logLine("tap CREATED after permission grant")
                    self.onboardingCheckAsync()
                }
            }, .commonModes)
            RunLoop.current.run()
        }
        thread.name = "OpenSwitcherTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        tapThread = thread
    }

    private func stopTap() {
        if let t = tap { CFMachPortInvalidate(t) }
        tap = nil
    }

    public var currentAppName: String { fgProc }
    public var lastExternalAppName: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _lastExternalProc.isEmpty ? _fgProc : _lastExternalProc
    }

    public var learnedCounts: (rejected: Int, accepted: Int) {
        learnedLock.lock()
        defer { learnedLock.unlock() }
        return (rejected.count, accepted.count)
    }

    public static func openInEditor(_ path: String) {
        let exists = FileManager.default.fileExists(atPath: path)
        if !exists { FileManager.default.createFile(atPath: path, contents: nil) }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    public func bumpSwitchSerial() {
        switchSerial += 1
    }

    private func switchLayoutOnMain(_ data: LayoutService.LayoutData, source: String) {
        let from = LayoutService.currentLayout()?.id.prefix(8) ?? "?"
        let to = data.id.prefix(8)
        logLine("layout switch: \(from) -> \(to) (\(source))")
        DispatchQueue.main.async { LayoutService.switchTo(data) }
    }

    private func verifySwitch(target: LayoutService.LayoutData) {
        let serial = switchSerial
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self, self.switchSerial == serial else { return }
            LayoutService.refreshOnMain()
            if LayoutService.currentLayout()?.id == target.id { return }
            self.logLine("switch lag/ignored -> TISSelect retry")
            _ = LayoutService.switchTo(target)
        }
    }

    private func resetTapState() {
        swallowedKeys.removeAll()
        tapVk = 0
        tapAlone = false
        optTapVk = 0
        shiftPairClean = false
    }

    // ------------------------------------------------------- онбординг разрешений

    public func permissionsState() -> (tap: Bool, accessibility: Bool) {
        (tap != nil, accessibilityTrusted(prompt: false))
    }

    private func onboardingCheckAsync() {
        DispatchQueue.main.async { [weak self] in self?.onboardingCheckOnMain() }
    }

    private func onboardingCheckOnMain() {
        guard onboardingAllowed, tapThread != nil else { return }
        let tapOk = tap != nil
        let axOk = accessibilityTrusted(prompt: false)
        if !tapOk || !axOk {
            if !onboardingAutoShown {
                onboardingAutoShown = true
                Self.showOnboarding()
            }
            return
        }
        if !readyInfoFired {
            readyInfoFired = true
            fireInfo("Работаю! Напечатайте ghbdtn и пробел")
        }
    }

    public func fireReadyInfoFromOnboarding() {
        guard !readyInfoFired else { return }
        readyInfoFired = true
        fireInfo("Работаю! Напечатайте ghbdtn и пробел")
    }

    private var onboardingAllowed: Bool {
        ProcessInfo.processInfo.environment["OS_DISABLE_TAP"] != "1"
    }

    // ------------------------------------------------------- фильтрация событий тапа

    /// Проверка: несёт ли событие `virtualKey == 0` кастомную Unicode-строку (диктовка,
    /// эмодзи-панель, текстовые замены, синтетический юникод сторонних утилит), чтобы
    /// не принять `0x00` за физическую клавишу 'a' / 'ф'.
    private static func isCustomUnicodeKeyZero(_ event: CGEvent, code: Int) -> Bool {
        guard code == 0x00 else { return false }
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            return false
        }
        var len = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &chars)
        guard len > 0 else { return false }
        if len > 1 { return true }
        let s = String(utf16CodeUnits: chars, count: 1).lowercased()
        // в RU/EN раскладках клавиша 0x00 даёт 'a' или 'ф'
        return s != "a" && s != "ф"
    }

    private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            logLine("tap DISABLED by system (\(type == .tapDisabledByTimeout ? "timeout" : "user input")) — reviving")
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            resetTapState()
            return Unmanaged.passUnretained(event)
        }
        // 1) Собственная инжекция — пропускаем мгновенно
        if event.getIntegerValueField(TextConverter.userField) == TextConverter.selfMagic {
            return Unmanaged.passUnretained(event)
        }
        if consumeSessionReset() { resetSession() }

        // 2) Чужая синтетика (сторонние утилиты, автозаполнение паролей, текстовые экспандеры):
        //    у реального HID-ввода eventSourceUnixProcessID == 0.
        let srcPid = event.getIntegerValueField(.eventSourceUnixProcessID)
        if srcPid != 0 {
            if s.devLog, type == .keyDown {
                let kc = Int(event.getIntegerValueField(.keyboardEventKeycode))
                logLine(String(format: "ev-foreign: pid=%lld code=0x%02X (ignored, buffer cleared)", srcPid, kc))
            }
            if type == .keyDown {
                buf.clear()
                lastWordSepKey = 0
                prevSingle = nil
                boundaryClean = false
                wordTainted = true
                autoRejectEligible = false
                if undoPending { undoTailBroken = true }
            }
            return Unmanaged.passUnretained(event)
        }

        if s.devLog, type == .keyDown || type == .keyUp || type == .flagsChanged {
            let kc = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let fl = event.flags
            var f = ""
            if fl.contains(.maskShift) { f += "S" }
            if fl.contains(.maskCommand) { f += "C" }
            if fl.contains(.maskAlternate) { f += "A" }
            if fl.contains(.maskControl) { f += "^" }
            if fl.contains(.maskAlphaShift) { f += "caps" }
            logLine(String(format: "ev: type=%d code=0x%02X flags=[%@]", type.rawValue, kc, f))
        }

        switch type {
        case .keyDown:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if Self.isCustomUnicodeKeyZero(event, code: code) {
                buf.clear()
                lastWordSepKey = 0
                prevSingle = nil
                boundaryClean = false
                if undoPending { undoTailBroken = true }
                return Unmanaged.passUnretained(event)
            }
            if !onKeyDown(event) {
                swallowedKeys.insert(code)
                return nil
            }
            swallowedKeys.remove(code)
        case .keyUp:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let wasSwallowed = swallowedKeys.remove(code) != nil
            let passUp = onKeyUp(event)
            if wasSwallowed || !passUp { return nil }
        case .flagsChanged:
            if !onFlagsChanged(event) { return nil }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            onMouseDown()
        default: break
        }
        return Unmanaged.passUnretained(event)
    }

    private func currentFlags(_ event: CGEvent) -> CGEventFlags { event.flags }

    private func heldMods(_ event: CGEvent) -> (ctrl: Bool, alt: Bool, cmd: Bool) {
        let f = event.flags
        return (f.contains(.maskControl), f.contains(.maskAlternate), f.contains(.maskCommand))
    }

    // ------------------------------------------------------------------ переднее окно и AXObserver

    private var fgObserver: NSObjectProtocol?
    private var launchObserver: NSObjectProtocol?

    private func watchForeground() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.fgObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.foregroundChanged()
            }
            self.launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.checkConflictingSwitchersOnMain()
            }
            self.syncForegroundFromWorkspace()
        }
    }

    private let resetLock = NSLock()
    private var pendingResetFlag = false

    private func requestSessionReset() {
        resetLock.lock()
        pendingResetFlag = true
        resetLock.unlock()
    }

    private func consumeSessionReset() -> Bool {
        resetLock.lock()
        defer { resetLock.unlock() }
        if pendingResetFlag { pendingResetFlag = false; return true }
        return false
    }

    private func resetSession() {
        if buf.count > 0 { lastWord = buf.snapshot() }
        lastWordSepKey = 0
        lastWordApp = 0
        buf.clear()
        wordTainted = false
        prevSingle = nil
        boundaryClean = true
        anyKeySinceShift = true
        tapAlone = false
        optTapVk = 0
        undoPending = false
        autoRejectEligible = false
        undoTailBroken = true
        gapActive = false
        gapLayout = nil
        if !(autoLocked && Engine.ms() - autoLockedAt < 10) {
            autoLocked = false
            autoLockedLang = -1
            autoLockedWordsTyped = 0
        }
        expectedLayoutID = nil
        lastSpaceTextTick = 0
    }

    private func foregroundChanged(alwaysReset: Bool = false) {
        let prevApp = fgApp
        syncForegroundFromWorkspace()
        PasswordGuard.forceRefreshOnMain()
        guard alwaysReset || (fgApp != 0 && prevApp != 0 && prevApp != fgApp) else { return }
        requestSessionReset()
    }

    private func syncForegroundFromWorkspace() {
        dispatchPrecondition(condition: .onQueue(.main))
        let front = NSWorkspace.shared.frontmostApplication
        let appPid = front?.processIdentifier ?? 0
        var bundle = (front?.bundleIdentifier ?? "").lowercased()
        let isOwn = bundle == "com.openswitcher.app" || bundle.hasPrefix("com.openswitcher")
        var name: String
        var exec: String
        if let cached = procCache[appPid], !cached.proc.isEmpty {
            name = cached.proc
            exec = cached.exec
            bundle = cached.bundle
        } else {
            var n = (front?.localizedName ?? bundle).lowercased()
            if n.hasSuffix(".app") { n.removeLast(4) }
            var e = (front?.executableURL?.lastPathComponent ?? "").lowercased()
            if e.hasSuffix(".app") { e.removeLast(4) }
            name = n
            exec = e
            if procCache.count > 200 { procCache.removeAll() }
            if appPid != 0 && !name.isEmpty {
                procCache[appPid] = (name, exec, bundle)
            }
        }
        stateLock.lock()
        _fgApp = appPid
        _fgProc = name
        _fgExec = exec
        _fgBundle = bundle
        _fgIsOwnApp = isOwn
        if !isOwn && !name.isEmpty { _lastExternalProc = name }
        stateLock.unlock()
        installAxObserverOnMain(for: appPid)
    }

    /// Подписка на смену активного окна и поля ввода внутри переднего приложения
    /// (заменяет неработавший локальный `NSWindow.didBecomeKeyNotification`).
    private func installAxObserverOnMain(for pid: pid_t) {
        dispatchPrecondition(condition: .onQueue(.main))
        if pid == axObservedPid && axObserver != nil { return }
        teardownAxObserverOnMain()
        guard pid > 0, !fgIsOwnApp, accessibilityTrusted(prompt: false) else { return }
        var obs: AXObserver?
        let err = AXObserverCreate(pid, { _, element, notification, refcon in
            guard let refcon = refcon else { return }
            let me = Unmanaged<Engine>.fromOpaque(refcon).takeUnretainedValue()
            let notif = notification as String
            PasswordGuard.forceRefreshOnMain()
            if notif == (kAXFocusedWindowChangedNotification as String) {
                me.requestSessionReset()
            } else if notif == (kAXFocusedUIElementChangedNotification as String) {
                let h = CFHash(element)
                if h != me.lastFocusedElementHash {
                    me.lastFocusedElementHash = h
                    // Не рвём буфер во время живой печати (автокомплит-попапы меняют элемент
                    // через 10–50 мс после буквы), но сбрасываем при переходе в другое поле
                    if Engine.ms() - me.lastLetterAt > 0.25 {
                        me.requestSessionReset()
                    }
                }
            }
        }, &obs)
        guard err == .success, let observer = obs else { return }
        let axApp = AXUIElementCreateApplication(pid)
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, axApp, kAXFocusedWindowChangedNotification as CFString, ptr)
        AXObserverAddNotification(observer, axApp, kAXFocusedUIElementChangedNotification as CFString, ptr)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObserver = observer
        axObservedPid = pid
    }

    private func teardownAxObserverOnMain() {
        if let obs = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
            axObserver = nil
        }
        axObservedPid = 0
    }

    private func lockAutoSwitch(lang: Int = -1) {
        if s.lockAutoAfterManualSwitch {
            autoLocked = true
            autoLockedAt = Engine.ms()
            autoLockedLang = lang
            autoLockedWordsTyped = 0
        }
    }

    private func updateForeground() {
        guard let cur = LayoutService.currentLayout() else { return }
        if let expected = expectedLayoutID, fgApp == expectedApp, cur.id != expected,
           Engine.ms() >= expectGraceUntil {
            let probe = [KeyRec(KeyCodeMap.ansiCode(ofLatin: "a"), false, false)]
            let curLang = LanguageTables.langOf(LayoutService.render(cur, probe))
            lockAutoSwitch(lang: curLang)
            noFlipUntil = max(noFlipUntil, Engine.ms() + 1.5)
        }
        expectedLayoutID = cur.id
        expectedApp = fgApp
        TextConverter.targetPid = fgApp
    }

    private func expectLayout(_ data: LayoutService.LayoutData) {
        expectedLayoutID = data.id
        expectedApp = fgApp
        expectGraceUntil = Engine.ms() + 1.2
        switchSerial += 1
    }

    /// Эффективная текущая раскладка с учётом активного окна `gapActive`:
    /// если мы сами переключили раскладку и досылаем нажатия в `gapLayout`,
    /// то текст на экране находится именно в `gapLayout`.
    private func effectiveCurrentLayout() -> LayoutService.LayoutData? {
        if gapActive, let gl = gapLayout {
            if LayoutService.currentLayout()?.id == gl.id || Engine.ms() >= gapDeadline {
                gapActive = false
                gapLayout = nil
            } else {
                return gl
            }
        }
        return LayoutService.currentLayout()
    }

    /// Нужно ли переводить и отправлять текущую клавишу через `injectorQueue`
    /// (пока выполняется замена ИЛИ система ещё не применила новую раскладку).
    private var shouldForwardViaInjector: Bool {
        if inFlightInjections > 0 { return true }
        if gapActive, let gl = gapLayout {
            if LayoutService.currentLayout()?.id == gl.id || Engine.ms() >= gapDeadline {
                gapActive = false
                gapLayout = nil
                return false
            }
            return true
        }
        return false
    }

    private func enqueueForwardedUnicode(_ text: String) {
        guard !text.isEmpty else { return }
        inFlightInjections += 1
        injectorQueue.async { [weak self] in
            TextConverter.sendUnicode(text, interCharDelayUs: 0)
            self?.performOnTapThread { [weak self] in
                guard let self = self else { return }
                self.inFlightInjections = max(0, self.inFlightInjections - 1)
            }
        }
    }

    private func enqueueForwardedBackspace() {
        inFlightInjections += 1
        injectorQueue.async { [weak self] in
            TextConverter.sendBackspaces(1, delayUs: 0)
            self?.performOnTapThread { [weak self] in
                guard let self = self else { return }
                self.inFlightInjections = max(0, self.inFlightInjections - 1)
            }
        }
    }

    private func enqueueForwardedEnter(shift: Bool) {
        inFlightInjections += 1
        injectorQueue.async { [weak self] in
            TextConverter.sendEnter(shift: shift)
            self?.performOnTapThread { [weak self] in
                guard let self = self else { return }
                self.inFlightInjections = max(0, self.inFlightInjections - 1)
            }
        }
    }

    private func armGap(for target: LayoutService.LayoutData) {
        gapActive = true
        gapLayout = target
        gapDeadline = Engine.ms() + 0.55
    }

    private var _exclusionList: [String] = []

    private static func parseExclusions(_ raw: String) -> [String] {
        return raw.lowercased()
            .split(whereSeparator: { ",;".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func isExcludedHere() -> Bool {
        stateLock.lock()
        let isOwn = _fgIsOwnApp
        let uiActive = _uiSettingsActive
        let sboxFocused = _sandboxFocused
        let proc = _fgProc
        let exec = _fgExec
        let bundle = _fgBundle
        let list = _exclusionList
        stateLock.unlock()

        if isOwn {
            return !(uiActive && sboxFocused)
        }
        if list.isEmpty { return false }
        for item in list {
            if !proc.isEmpty && proc == item { return true }
            if !exec.isEmpty && exec == item { return true }
            if !bundle.isEmpty && bundle == item { return true }
        }
        return false
    }

    // ------------------------------------------------------------------ модификаторы (безсостоятельно)

    /// Аппаратное определение нажатия/отпускания конкретного модификатора через
    /// device-dependent маски `IOKit/IOLLEvent.h` (`NX_DEVICE*KEYMASK`).
    /// Не инвертируется после сна, Lock Screen или парольного поля (`SecureEventInput`).
    private static func isModPressed(code: Int, flags: CGEventFlags) -> Bool {
        let raw = flags.rawValue
        switch code {
        case KeyCodeMap.leftShift:
            if (raw & 0x0000_0006) != 0 { return (raw & 0x0000_0002) != 0 }
            return flags.contains(.maskShift)
        case KeyCodeMap.rightShift:
            if (raw & 0x0000_0006) != 0 { return (raw & 0x0000_0004) != 0 }
            return flags.contains(.maskShift)
        case 0x3A: // leftOption
            if (raw & 0x0000_0060) != 0 { return (raw & 0x0000_0020) != 0 }
            return flags.contains(.maskAlternate)
        case 0x3D: // rightOption
            if (raw & 0x0000_0060) != 0 { return (raw & 0x0000_0040) != 0 }
            return flags.contains(.maskAlternate)
        case 0x37: // leftCommand
            if (raw & 0x0000_0018) != 0 { return (raw & 0x0000_0008) != 0 }
            return flags.contains(.maskCommand)
        case 0x36: // rightCommand
            if (raw & 0x0000_0018) != 0 { return (raw & 0x0000_0010) != 0 }
            return flags.contains(.maskCommand)
        case 0x3B: // leftControl
            if (raw & 0x0000_2001) != 0 { return (raw & 0x0000_0001) != 0 }
            return flags.contains(.maskControl)
        case 0x3E: // rightControl
            if (raw & 0x0000_2001) != 0 { return (raw & 0x0000_2000) != 0 }
            return flags.contains(.maskControl)
        case KeyCodeMap.capsLock:
            return CGEventSource.keyState(.hidSystemState, key: CGKeyCode(KeyCodeMap.capsLock))
        default:
            return false
        }
    }

    private func onFlagsChanged(_ event: CGEvent) -> Bool {
        let flags = currentFlags(event)
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let now = Engine.ms()
        let m = heldModsFromFlags(flags)
        let isPress = Self.isModPressed(code: code, flags: flags)

        if s.devLog, KeyCodeMap.isModifier(code) {
            logLine(String(format: "flags: code=0x%02X press=%d tapVk=%d alone=%d", code, isPress ? 1 : 0, tapVk, tapAlone ? 1 : 0))
        }

        if isPress && code != 0x3A && code != 0x3D { optTapVk = 0 }

        let isShiftKey = code == KeyCodeMap.leftShift || code == KeyCodeMap.rightShift
        let shiftIsTapKey = (s.hotRuMods == 0 && (s.hotRuVk == KeyCodeMap.leftShift || s.hotRuVk == KeyCodeMap.rightShift))
            || (s.hotEnMods == 0 && (s.hotEnVk == KeyCodeMap.leftShift || s.hotEnVk == KeyCodeMap.rightShift))
        let isCapsTapKey = code == KeyCodeMap.capsLock
            && ((s.hotRuMods == 0 && s.hotRuVk == code) || (s.hotEnMods == 0 && s.hotEnVk == code))

        if isShiftKey && isPress {
            let bothShiftsHeld = (flags.rawValue & 0x0000_0006) == 0x0000_0006
            // Если зажаты оба Shift одновременно — одиночный Shift-тап ЗАПРЕЩЁН
            if bothShiftsHeld {
                tapVk = 0
                tapAlone = false
                if s.shiftShiftToggle && shiftPairClean {
                    shiftPairClean = false
                    lastShiftDown = 0
                    anyKeySinceShift = true
                    logLine("both-shifts: toggle auto")
                    toggleAuto()
                }
                return true
            }
            if !anyKeySinceShift && (now - lastShiftDown) >= 0 && (now - lastShiftDown) < 0.4
                && s.doubleShiftSwitch && !shiftIsTapKey {
                lastShiftDown = 0
                anyKeySinceShift = true
                tapAlone = false
                switchToOtherLayout()
                return true
            }
            lastShiftDown = now
            anyKeySinceShift = false
            if PasswordGuard.isSecureFocused || m.ctrl || m.alt || m.cmd {
                anyKeySinceShift = true
                tapAlone = false
                return true
            }
            if (s.hotRuMods == 0 && s.hotRuVk == code) || (s.hotEnMods == 0 && s.hotEnVk == code) {
                if lastTapDoneAt != 0 && (now - lastTapDoneAt) < 0.2 {
                    logLine("tap debounce: too soon after previous tap")
                } else {
                    tapVk = code
                    tapTarget = s.hotRuVk == code ? 0 : 1
                    tapDownAt = now
                    tapAlone = true
                }
            }
            shiftPairClean = true
            return true
        }

        if isShiftKey && !isPress {
            if s.devLog {
                logLine(String(format: "shift-up: code=0x%02X tapVk=%d alone=%d dt=%.3f", code, tapVk, tapAlone ? 1 : 0, now - tapDownAt))
            }
            _ = fireTapIfArmed(code: code, now: now, flags: flags)
            return true
        }

        if isCapsTapKey {
            if m.ctrl || m.alt || m.cmd { return true }
            if isPress {
                tapVk = code
                tapTarget = (s.hotRuMods == 0 && s.hotRuVk == code) ? 0 : 1
                tapDownAt = now
                tapAlone = true
                return false
            }
            _ = fireTapIfArmed(code: code, now: now, flags: flags)
            return false
        }

        // Option-тап «как в Caramba»
        if code == 0x3A || code == 0x3D {
            if isPress {
                anyKeySinceShift = true
                if code != tapVk { tapAlone = false }
                let mOpt = heldModsFromFlags(flags)
                if s.optionFlip && !mOpt.ctrl && !mOpt.cmd && !flags.contains(.maskShift) {
                    optTapVk = code
                    optTapDownAt = now
                } else {
                    optTapVk = 0
                    buf.clear()
                    prevSingle = nil
                    boundaryClean = false
                }
            } else {
                fireOptionTapIfArmed(code: code, now: now, flags: flags)
            }
            return true
        }

        if isPress {
            anyKeySinceShift = true
            if code != tapVk { tapAlone = false }
            if code == 0x3B || code == 0x3E || code == 0x37 || code == 0x36 {
                buf.clear()
                prevSingle = nil
                boundaryClean = false
            }
        }
        return true
    }

    private func fireTapIfArmed(code: Int, now: TimeInterval, flags: CGEventFlags) -> Bool {
        guard tapVk != 0, code == tapVk else { return true }
        tapVk = 0
        if now < suppressUntil { return true }
        let m = heldModsFromFlags(flags)
        let dt = now - tapDownAt
        let minHold = max(0.015, Double(s.tapMinMs) / 1000.0)
        // На отпускании Shift бит maskShift обязан погаснуть (второй Shift не зажат),
        // а длительность чистого тапа — до 0.40 с (удержание дольше = раздумье перед заглавной).
        let otherShiftStillHeld = (code == KeyCodeMap.leftShift || code == KeyCodeMap.rightShift) && flags.contains(.maskShift)
        let alone = tapAlone && !otherShiftStillHeld && !m.ctrl && !m.alt && !m.cmd
            && dt >= minHold && dt < 0.40
        if !alone, s.devLog {
            logLine(String(format: "tap not fired: tapAlone=%d ctrl=%d alt=%d cmd=%d dt=%.3f suppress=%d", tapAlone ? 1 : 0, m.ctrl ? 1 : 0, m.alt ? 1 : 0, m.cmd ? 1 : 0, dt, now < suppressUntil ? 1 : 0))
        }
        if alone {
            if PasswordGuard.isSecureFocused {
                logLine("tap skip: password field")
                return true
            }
            logLine("tap fired: lang=\(tapTarget)")
            lastTapDoneAt = now
            updateForeground()
            switchToLanguageOnTap(tapTarget)
        }
        return true
    }

    private func fireOptionTapIfArmed(code: Int, now: TimeInterval, flags: CGEventFlags) {
        guard optTapVk != 0, code == optTapVk else { return }
        optTapVk = 0
        if now < suppressUntil && !(undoPending && keysSinceUndoPoint == 0) { return }
        let m = heldModsFromFlags(flags)
        guard !m.ctrl && !m.alt && !m.cmd && !flags.contains(.maskShift) else { return }
        let dt = now - optTapDownAt
        guard dt >= 0.012 && dt < 0.45 else { return }
        logLine("option-tap fired")
        carambaFlip()
    }

    private func heldModsFromFlags(_ f: CGEventFlags) -> (ctrl: Bool, alt: Bool, cmd: Bool) {
        (f.contains(.maskControl), f.contains(.maskAlternate), f.contains(.maskCommand))
    }

    private func matchHot(codeEvent: Int, _ event: CGEvent?, vkHot: Int, modsHot: Int) -> Bool {
        if vkHot == 0 || codeEvent != vkHot { return false }
        var ctrl = false, shift = false, alt = false, cmd = false
        if let e = event {
            let f = e.flags
            ctrl = f.contains(.maskControl)
            shift = f.contains(.maskShift)
            alt = f.contains(.maskAlternate)
            cmd = f.contains(.maskCommand)
        }
        if ((modsHot & HK.CTRL) != 0) != ctrl { return false }
        if ((modsHot & HK.SHIFT) != 0) != shift { return false }
        if ((modsHot & HK.ALT) != 0) != alt { return false }
        if ((modsHot & HK.CMD) != 0) != cmd { return false }
        return true
    }

    private func isUndoHotkey(_ code: Int, _ event: CGEvent) -> Bool {
        matchHot(codeEvent: code, event, vkHot: s.hotUndoVk, modsHot: s.hotUndoMods)
    }

    private func isFixWordHotkey(_ code: Int, _ event: CGEvent) -> Bool {
        matchHot(codeEvent: code, event, vkHot: s.hotFixWordVk, modsHot: s.hotFixWordMods)
    }

    // ------------------------------------------------------------------ обработка клавиш

    private func onKeyDown(_ event: CGEvent) -> Bool {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        PasswordGuard.notifyActivity()

        optTapVk = 0
        shiftPairClean = false

        if !KeyCodeMap.isModifier(code) &&
            !matchHot(codeEvent: code, event, vkHot: s.hotFixSelVk, modsHot: s.hotFixSelMods) &&
            !isFixWordHotkey(code, event) {
            bumpInputSeq()
        }

        // F8 (kVK_F8 = 0x64) — метка состояния в журнале
        if code == 0x64 {
            markCount += 1
            updateForeground()
            if !s.devLog {
                fireInfo("Журнал отключён — включите «Режим разработчика»")
                return true
            }
            let curL = effectiveCurrentLayout()
            let mBuf = buf.count > 0 ? (curL.map { LayoutService.render($0, buf.snapshot()) } ?? "") : ""
            let mLast = lastWord.isEmpty ? "" : (curL.map { LayoutService.render($0, lastWord) } ?? "")
            var mRetro = "-"
            if let ps = prevSingle, let pl = LayoutService.getLayouts().first(where: { $0.id == prevSingleLayoutID }) {
                mRetro = "'" + LayoutService.render(pl, ps) + "'"
            }
            logLine("================ USER MARK #\(markCount) ================")
            logLine("mark: proc=\(fgProc) buf='\(mBuf)' lastWord='\(mLast)' (\(String(format: "%.1f", Engine.ms() - lastWordAt))s ago)" +
                " undo=\(undoPending ? "pending ('\(undoText)'\(undoTailBroken ? ", tail broken" : ""))" : "no") locked=\(autoLocked ? 1 : 0)" +
                " tainted=\(wordTainted ? 1 : 0) retroCand=\(mRetro)" +
                " inFlight=\(inFlightInjections) lastConvert=\(lastConvertInfo)")
            fireInfo("Метка #\(markCount) записана в лог")
            return true
        }

        let flags = currentFlags(event)
        let shift = flags.contains(.maskShift)
        let caps = flags.contains(.maskAlphaShift)
        let m = heldMods(event)
        let now = Engine.ms()

        if code == KeyCodeMap.backspace {
            lastBsAt = now
        }

        if !KeyCodeMap.isModifier(code) {
            if autoLocked && (now - lastInputAt) >= 3.0 {
                autoLocked = false
                autoLockedLang = -1
                autoLockedWordsTyped = 0
                logLine(String(format: "auto-unlock: session pause %.0f ms", (now - lastInputAt) * 1000))
            }
            lastInputAt = now
        }

        // Cmd+V / Cmd+A / Cmd+X / Cmd+T / Cmd+C / Cmd+W — команды меняют выделение/документ/вкладку: ломаем откат
        if m.cmd && (code == KeyCodeMap.ansiCode(ofLatin: "v") || code == KeyCodeMap.ansiCode(ofLatin: "a") ||
                     code == KeyCodeMap.ansiCode(ofLatin: "x") || code == KeyCodeMap.ansiCode(ofLatin: "t") ||
                     code == KeyCodeMap.ansiCode(ofLatin: "w")) {
            if code == KeyCodeMap.ansiCode(ofLatin: "v") { lastPasteAt = now }
            autoRejectEligible = false
            if undoPending { undoPending = false; undoTailBroken = true }
        }

        // Cmd+Z сразу после автозамены — юзер отменил нашу автозамену стандартным Undo:
        // заносим слово в rejected и включаем кулдаун 5 с (только если это первое действие после автозамены!)
        if m.cmd && !shift && !m.alt && !m.ctrl && code == KeyCodeMap.ansiCode(ofLatin: "z") {
            if undoPending && undoFromAuto && autoRejectEligible && !undoTailBroken && keysSinceUndoPoint == 0 && (now - undoAt) < 8.0 {
                let bad = undoText
                logLine("auto-reject via Cmd+Z: '\(bad)'")
                rememberRejected(bad)
                removeAccepted(bad)
                noFlipUntil = now + 5.0
                undoPending = false
            }
            autoRejectEligible = false
            if undoPending { undoTailBroken = true }
        }

        anyKeySinceShift = true
        tapAlone = false

        // global / manual hotkeys + tap keys — игнорируем key-autorepeat при удержании (P2-5)
        let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        // глобальный тумблер паузы
        if !isAutoRepeat && s.hotAutoToggleVk != 0 && matchHot(codeEvent: code, event, vkHot: s.hotAutoToggleVk, modsHot: s.hotAutoToggleMods) {
            toggleAuto()
            return false
        }

        // P2-1: убран 600 мс space-echo фильтр (собственная инжекция уже отфильтрована по PID источника),
        // чтобы не съедать намеренный второй пробел при SpaceDedupMs = 0
        if code != KeyCodeMap.space && code != 0x64 {
            lastSpaceTextTick = 0
        }

        if !KeyCodeMap.isModifier(code) && !isUndoHotkey(code, event) && !isFixWordHotkey(code, event)
            && !(undoPending && code == KeyCodeMap.backspace) {
            keysSinceUndoPoint += 1
        }

        updateForeground()

        // ---- ручные хоткеи (работают и вне авто-режима)
        if !isAutoRepeat && matchHot(codeEvent: code, event, vkHot: s.hotUndoVk, modsHot: s.hotUndoMods) {
            prevSingle = nil
            if let undoBlock = undoBlockReason() {
                logLine("hotkey: undo -> \(undoBlock), force flip")
                if !forceFlipLastWord() {
                    fireInfo(undoPending ? Engine.undoBlockMessage(undoBlock)
                                         : "Курсор не сразу после слова — выдели его и нажми Option")
                }
            } else {
                logLine("hotkey: undo")
                noFlipUntil = Engine.ms() + 5.0
                undoLastConversion()
            }
            return false
        }
        if !isAutoRepeat && matchHot(codeEvent: code, event, vkHot: s.hotFixWordVk, modsHot: s.hotFixWordMods) {
            logLine("hotkey: fix-last-word")
            prevSingle = nil
            doFixLastWord()
            return false
        }
        if !isAutoRepeat && matchHot(codeEvent: code, event, vkHot: s.hotFixSelVk, modsHot: s.hotFixSelMods) {
            logLine("hotkey: fix-selection")
            prevSingle = nil; boundaryClean = false
            beginFixSelection(fromFixWord: false)
            return false
        }
        if !isAutoRepeat && s.pastePlain && !isExcludedHere() && !PasswordGuard.isSecureFocused &&
            matchHot(codeEvent: code, event, vkHot: s.hotPasteVk, modsHot: s.hotPasteMods) {
            logLine("hotkey: paste-plain")
            prevSingle = nil; boundaryClean = false
            pastePlainAction()
            return false
        }
        if !isAutoRepeat && s.hotRuMods != 0 && s.hotRuVk != 0 && matchHot(codeEvent: code, event, vkHot: s.hotRuVk, modsHot: s.hotRuMods) {
            switchToLanguage(0)
            return false
        }
        if !isAutoRepeat && s.hotEnMods != 0 && s.hotEnVk != 0 && matchHot(codeEvent: code, event, vkHot: s.hotEnVk, modsHot: s.hotEnMods) {
            switchToLanguage(1)
            return false
        }
        if !isAutoRepeat && ((s.hotRuMods == 0 && s.hotRuVk != 0 && code == s.hotRuVk) ||
           (s.hotEnMods == 0 && s.hotEnVk != 0 && code == s.hotEnVk)) {
            if m.ctrl || m.alt || m.cmd { return true }
            tapVk = code
            tapTarget = (s.hotRuMods == 0 && code == s.hotRuVk) ? 0 : 1
            tapDownAt = now
            tapAlone = true
            return false
        }

        // В исключённых приложениях и полях пароля не вмешиваемся в ввод вовсе
        if isExcludedHere() || PasswordGuard.isSecureFocused {
            buf.clear()
            wordTainted = false
            gapActive = false
            return true
        }

        let cmdMods = m.ctrl || m.alt || m.cmd
        let backslashYo = LayoutService.usesBackslashForYo()

        // ---- Буквы (включая знаки-двойники, '-' и 'ё' на 0x2A в стандартной раскладке Apple)
        if KeyCodeMap.isLetterKey(code, allowBackslashYo: backslashYo) {
            if cmdMods {
                buf.clear()
                lastWordSepKey = 0
                wordTainted = false
                prevSingle = nil
                boundaryClean = false
                autoRejectEligible = false
                if undoPending { undoTailBroken = true }
                return true
            }
            // '-' или Shift + '-' ('_'): если в начале буфера (-rf, --help) или snake_case -> токен не-слово
            if code == KeyCodeMap.minus {
                if buf.count == 0 || shift {
                    wordTainted = true
                }
            }
            autoRejectEligible = false
            lastLetterAt = now
            let effLayout = effectiveCurrentLayout()
            let rec = KeyRec(code, shift, caps)
            if buf.count == 0 {
                wordStartClean = boundaryClean && !wordTainted
                wordStartLayoutID = effLayout?.id
            }
            buf.push(rec)
            if buf.overflowed {
                wordTainted = true
                prevSingle = nil
            }
            if undoPending && !undoTailBroken {
                if undoTail.count < 16 { undoTail.append(rec) }
                else { undoTailBroken = true }
            }
            if shouldForwardViaInjector, let gl = effLayout, let ch = LayoutService.renderKey(gl, rec) {
                enqueueForwardedUnicode(ch)
                return false
            }
            return true
        }

        // ---- Голые цифры 0..9 + Numpad-цифры / операторы (P1-7):
        // НЕ конвертируем предшествующий кусок слова ('snow7', 'gpt4'), помечаем токен смешанным
        if KeyCodeMap.isDigitKey(code) && (!shift || KeyCodeMap.isKeypadDigitKey(code)) {
            if cmdMods {
                buf.clear()
                lastWordSepKey = 0
                prevSingle = nil
                boundaryClean = false
                autoRejectEligible = false
                if undoPending { undoTailBroken = true }
                return true
            }
            buf.clear()
            wordTainted = true
            autoRejectEligible = false
            lastWordSepKey = 0
            prevSingle = nil
            boundaryClean = false
            if undoPending && !undoTailBroken {
                if undoTail.count < 16 { undoTail.append(KeyRec(code, false, caps)) }
                else { undoTailBroken = true }
            }
            if shouldForwardViaInjector, let gl = effectiveCurrentLayout(),
               let ch = LayoutService.renderKey(gl, KeyRec(code, false, false)) {
                enqueueForwardedUnicode(ch)
                return false
            }
            return true
        }

        if KeyCodeMap.isKeypadOpKey(code) {
            buf.clear()
            wordTainted = true
            autoRejectEligible = false
            lastWordSepKey = 0
            prevSingle = nil
            boundaryClean = false
            if undoPending { undoTailBroken = true }
            return true
        }

        // ---- Backspace
        if code == KeyCodeMap.backspace {
            if cmdMods {
                // Opt+BS / Cmd+BS сразу после ложной автозамены — тоже явное стирание нашего слова
                if undoPending && undoFromAuto && autoRejectEligible && !undoTailBroken && undoTail.isEmpty && keysSinceUndoPoint == 0 && (now - undoAt) < 8.0 {
                    let bad = undoText
                    logLine("auto-reject via word-BS: '\(bad)'")
                    rememberRejected(bad)
                    removeAccepted(bad)
                    noFlipUntil = now + 5.0
                }
                autoRejectEligible = false
                buf.clear()
                lastWordSepKey = 0
                prevSingle = nil
                boundaryClean = false
                if undoPending { undoPending = false; undoTailBroken = true }
                return true
            }
            if buf.count == 0 {
                lastWordSepKey = 0
                prevSingle = nil
                boundaryClean = false
            }
            buf.pop()
            if undoPending {
                if !undoTailBroken && !undoTail.isEmpty {
                    undoTail.removeLast()
                    autoRejectEligible = false
                } else {
                    undoTailBroken = true
                    // Если юзер сразу после автозамены вручную стирает само заменённое слово
                    // Backspace'ами — учимся на ошибке (только если серия BS пошла без промежуточных символов!)
                    if undoFromAuto && autoRejectEligible && (now - undoAt) < 8.0 {
                        undoErasedByBs += 1
                        let threshold = max(2, undoLen - 1)
                        if undoErasedByBs >= threshold {
                            let bad = undoText
                            logLine("auto-reject via BS×\(undoErasedByBs): '\(bad)'")
                            rememberRejected(bad)
                            removeAccepted(bad)
                            noFlipUntil = now + 5.0
                            undoPending = false
                            autoRejectEligible = false
                        }
                    }
                }
            }
            if inFlightInjections > 0 {
                enqueueForwardedBackspace()
                return false
            }
            return true
        }

        // ---- Enter / KeypadEnter
        if code == KeyCodeMap.enter || code == KeyCodeMap.keypadEnter {
            let modified = cmdMods || shift
            var converted = false
            let word = buf.snapshot()
            if !word.isEmpty && !modified {
                lastWord = word
                lastWordAt = now
                lastWordApp = fgApp
            }
            lastWordSepKey = 0
            if !modified && code == KeyCodeMap.enter && s.fixOnEnter && now >= suppressUntil && !word.isEmpty {
                converted = tryConvertWord(word, resendKey: KeyCodeMap.enter, resendShift: false, manual: false)
            }
            if !converted && autoLocked && !word.isEmpty {
                autoLockedWordsTyped += 1
            }
            prevSingle = nil
            boundaryClean = true
            wordTainted = false
            undoTailBroken = true
            autoRejectEligible = false
            buf.clear()
            if converted { return false }
            if inFlightInjections > 0 && !cmdMods {
                enqueueForwardedEnter(shift: shift)
                return false
            }
            return true
        }

        // ---- Tab / Esc
        if code == KeyCodeMap.tab || code == KeyCodeMap.esc {
            buf.clear()
            lastWordSepKey = 0
            wordTainted = false
            prevSingle = nil
            boundaryClean = false
            autoRejectEligible = false
            if undoPending { undoTailBroken = true }
            return true
        }

        // ---- Разделители конца слова (пробел, '=', '/', '\' если не ё, Shift+цифра)
        if KeyCodeMap.isSeparatorKey(code, shift: shift, allowBackslashYo: backslashYo) {
            let modified = cmdMods || shift
            var converted = false
            let bufWas = buf.count

            // Дедуп двойных пробелов
            if code == KeyCodeMap.space && !cmdMods && !s.paused && s.spaceDedupMs > 0 &&
                buf.count == 0 && lastSpaceTextTick != 0 && (now - lastSpaceTextTick) < Double(s.spaceDedupMs) / 1000.0 {
                logLine("space: dedup swallowed")
                return false
            }

            // Префиксы команд/упоминаний/путей при пустом буфере ('/plan', '@nick', '#tag', '$var'):
            // помечают следующий за ними токен как не-слово до пробела/Enter
            let isSlashPrefix = (code == KeyCodeMap.slash && !shift && buf.count == 0)
            let isMentionOrTagPrefix = (shift && buf.count == 0 && (code == 0x13 /* @ */ || code == 0x14 /* # */ || code == 0x15 /* $ */))
            if isSlashPrefix || isMentionOrTagPrefix {
                wordTainted = true
            }

            if !cmdMods && s.autoConvertOnWordEnd && now >= suppressUntil && buf.count > 0 {
                let word = buf.snapshot()
                converted = tryConvertWord(word, resendKey: code, resendShift: shift, manual: false)
            }

            // Если голый '/' после слова НЕ сконвертировал его ('fix/branch', 'https://site/path'),
            // остаток пути до пробела тоже считаем путём/URL и не трогаем
            if !converted && code == KeyCodeMap.slash && !shift && !cmdMods {
                wordTainted = true
            }

            if buf.count > 0 && !cmdMods {
                lastWord = buf.snapshot()
                lastWordAt = now
                lastWordApp = fgApp
                lastWordSepKey = code
                lastWordSepShift = shift
                if !converted && autoLocked && code == KeyCodeMap.space {
                    autoLockedWordsTyped += 1
                }
            } else {
                lastWordSepKey = 0
            }

            if !cmdMods && !converted && undoPending && !undoTailBroken {
                if undoTail.count < 16 { undoTail.append(KeyRec(code, shift, caps)) }
                else { undoTailBroken = true }
            }

            if code == KeyCodeMap.space && !cmdMods && !converted {
                lastSpaceTextTick = now
            }
            if code == KeyCodeMap.space && !modified {
                let curL = effectiveCurrentLayout()
                let wordText = buf.count > 0 ? (curL.map { LayoutService.render($0, buf.snapshot()) } ?? "?") : "-"
                logLine("space: \(converted ? "flip+resend" : "pass") bufWas=\(bufWas) word='\(wordText)'")
            }

            let plainSpace = code == KeyCodeMap.space && !modified
            if plainSpace && !converted && buf.count == 1 && wordStartClean && !wordTainted {
                prevSingle = buf.snapshot()
                prevSingleLayoutID = effectiveCurrentLayout()?.id
                prevSingleApp = fgApp
            } else {
                prevSingle = nil
            }

            if !converted {
                autoRejectEligible = false
            }
            if cmdMods && undoPending {
                undoTailBroken = true
            }
            if plainSpace {
                wordTainted = false
            }
            boundaryClean = plainSpace
            buf.clear()

            if converted { return false }
            if !cmdMods && shouldForwardViaInjector, let gl = effectiveCurrentLayout(),
               let ch = LayoutService.renderKey(gl, KeyRec(code, shift, false)), !ch.isEmpty {
                enqueueForwardedUnicode(ch)
                return false
            }
            return true
        }

        // ---- Навигация, стрелки, F-клавиши
        if KeyCodeMap.isNavigationKey(code) {
            buf.clear()
            lastWordSepKey = 0
            wordTainted = false
            prevSingle = nil
            boundaryClean = false
            autoRejectEligible = false
            if undoPending { undoTailBroken = true }
            return true
        }

        return true
    }

    private func onKeyUp(_ event: CGEvent) -> Bool {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if tapVk != 0 && code == tapVk && code != KeyCodeMap.leftShift && code != KeyCodeMap.rightShift {
            _ = fireTapIfArmed(code: code, now: Engine.ms(), flags: event.flags)
            return false
        }
        return true
    }

    private func onMouseDown() {
        PasswordGuard.notifyActivity()
        bumpInputSeq()
        if buf.count > 0 { lastWord = buf.snapshot() }
        lastWordSepKey = 0
        lastWordApp = 0
        buf.clear()
        wordTainted = false
        tapAlone = false
        optTapVk = 0
        shiftPairClean = false
        prevSingle = nil
        lastSpaceTextTick = 0
        boundaryClean = true
        keysSinceUndoPoint += 1
        autoRejectEligible = false
        if undoPending { undoTailBroken = true }
    }

    // ------------------------------------------------------------------ потоки и AX-проверка экрана

    private func performOnTapThread(_ body: @escaping () -> Void) {
        if CFRunLoopGetCurrent() === tapRunLoop {
            body()
        } else if let rl = tapRunLoop {
            CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) { body() }
            CFRunLoopWakeUp(rl)
        } else {
            body()
        }
    }

    private enum AutoScreenVerdict { case proceed, alreadyTarget }

    /// Быстрая проверка экрана ПЕРЕД авто-инжекцией (вызывается на `injectorQueue`,
    /// ВНЕ `tapCallback`!). Не блокирует ввод пользователя.
    private func checkScreenBeforeAutoInject(expectedTail: String, targetText: String) -> AutoScreenVerdict {
        let gate = screenTailAtCaretOnMain(expectedTail, timeout: 0.06)
        if gate.available && !gate.matches && gate.actual.hasSuffix(targetText) {
            return .alreadyTarget
        }
        return .proceed
    }

    /// Строгая проверка хвоста у каретки для РУЧНЫХ действий (`Option`-тап / `Undo`),
    /// вызывается на `injectorQueue` вне `tapCallback`.
    private func verifyTailForManualAction(_ expectedTail: String) -> (available: Bool, matches: Bool, actual: String) {
        let g1 = screenTailWithOptionalTrimmedSpace(expectedTail, timeout: 0.08)
        if g1.matches || !g1.available { return g1 }
        usleep(35_000)
        return screenTailWithOptionalTrimmedSpace(expectedTail, timeout: 0.08)
    }

    private func screenTailWithOptionalTrimmedSpace(_ expectedTail: String, timeout: TimeInterval) -> (available: Bool, matches: Bool, actual: String) {
        let gate = screenTailAtCaretOnMain(expectedTail, timeout: timeout)
        if gate.matches || !gate.available { return gate }
        if expectedTail.hasSuffix(" ") {
            let trimmed = String(expectedTail.dropLast())
            let g2 = screenTailAtCaretOnMain(trimmed, timeout: timeout)
            if g2.matches { return (g2.available, true, g2.actual) }
        }
        return gate
    }

    private final class TailCheckBox {
        private let lock = NSLock()
        private var available = false
        private var matches = false
        private var actual = ""
        func set(available: Bool, matches: Bool, actual: String) {
            lock.lock()
            self.available = available
            self.matches = matches
            self.actual = actual
            lock.unlock()
        }
        func get() -> (available: Bool, matches: Bool, actual: String) {
            lock.lock()
            defer { lock.unlock() }
            return (available, matches, actual)
        }
    }

    private final class SelectedTextBox {
        private let lock = NSLock()
        private var value: String? = nil
        func set(_ v: String?) { lock.lock(); value = v; lock.unlock() }
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Читает текст до каретки на `main`. Если каретка не читается (`caret == nil`) или
    /// активно выделение (`hasSelection == true` при ожидании каретки), НЕ подставляет
    /// конец всего документа, чтобы никогда не стереть середину чужого абзаца.
    private func screenTailAtCaretOnMain(_ expectedTail: String, timeout: TimeInterval = 0.08) -> (available: Bool, matches: Bool, actual: String) {
        let box = TailCheckBox()
        let read = {
            guard let focused = PasswordGuard.focusedTextAndCaret() else { return }
            let (text, caret, hasSelection) = focused
            if hasSelection {
                box.set(available: true, matches: false, actual: "<selection>")
                return
            }
            // Если каретка не отдана элементом — достоверно проверить точку вставки нельзя:
            // возвращаем available=false вместо ложного предположения «курсор в конце текста».
            guard let c = caret, c >= 0, c <= text.utf16.count else { return }
            let before = String(decoding: text.utf16.prefix(c), as: UTF16.self)
            let act = String(before.suffix(expectedTail.count + 4))
            box.set(available: true, matches: before.hasSuffix(expectedTail), actual: act)
        }
        if Thread.isMainThread {
            read()
        } else {
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                read()
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + timeout)
        }
        return box.get()
    }

    private func selectedTextOnMain(timeout: TimeInterval = 0.08) -> String? {
        if Thread.isMainThread { return PasswordGuard.selectedText() }
        let box = SelectedTextBox()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            box.set(PasswordGuard.selectedText())
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
        return box.get()
    }

    // ------------------------------------------------------------------ переключение раскладки

    public func switchToLanguage(_ lang: Int) {
        performOnTapThread { [weak self] in self?.switchToLanguageOnTap(lang) }
    }

    private func switchToLanguageOnTap(_ lang: Int) {
        updateForeground()
        prevSingle = nil
        guard let target = LayoutService.findLayoutByLang(lang) else {
            fireInfo(lang == 0 ? "Русская раскладка не найдена" : "Английская раскладка не найдена")
            return
        }
        switchLayoutOnMain(target, source: "switch-to-lang")
        verifySwitch(target: target)
        expectLayout(target)
        lockAutoSwitch(lang: lang)
        noFlipUntil = Engine.ms() + 1.5
        armGap(for: target)
        fireInfo(lang == 0 ? "РУС" : "ENG")
    }

    public func switchToOtherLayout() {
        performOnTapThread { [weak self] in self?.switchToOtherLayoutOnTap() }
    }

    private func switchToOtherLayoutOnTap() {
        updateForeground()
        prevSingle = nil
        let layouts = LayoutService.getLayouts()
        guard let curID = effectiveCurrentLayout()?.id,
              let other = layouts.first(where: { $0.id != curID }) else { return }
        let probe = [KeyRec(KeyCodeMap.ansiCode(ofLatin: "a"), false, false)]
        let lang = LanguageTables.langOf(LayoutService.render(other, probe))
        let name = lang == 0 ? "РУС" : "ENG"
        switchLayoutOnMain(other, source: "switch-other")
        verifySwitch(target: other)
        expectLayout(other)
        lockAutoSwitch(lang: lang)
        noFlipUntil = Engine.ms() + 1.5
        armGap(for: other)
        fireInfo("Раскладка: \(name)")
    }

    // ------------------------------------------------------------------ защита регистра / кода

    /// Есть ли переход `строчная -> ЗАГЛАВНАЯ` внутри слова (`JoeSnow`, `iPhone`, `macOS`, `OpenSwitcher`).
    /// Учитывает `shift != caps`. Быстрое зажатие Shift на первых двух буквах (`GHbdtn`)
    /// перехода `lower -> UPPER` НЕ имеет и продолжает конвертироваться нормально.
    public static func hasCamelCaseTransition(_ keys: [KeyRec]) -> Bool {
        guard keys.count >= 2 else { return false }
        // P2-3: инвертированный CapsLock ('gHBDTN' -> 'пРИВЕТ': Caps ON + Shift только на первой букве) —
        // это случайный сбой регистра, а не camelCase-идентификатор
        if keys[0].caps && keys[0].shift && keys.dropFirst().allSatisfy({ !$0.shift && $0.caps }) {
            return false
        }
        var prevUpper = keys[0].shift != keys[0].caps
        for i in 1..<keys.count {
            guard KeyCodeMap.letters[keys[i].code] != nil ||
                  KeyCodeMap.signLetterKeys[keys[i].code] != nil ||
                  keys[i].code == KeyCodeMap.backslash else {
                continue
            }
            let curUpper = keys[i].shift != keys[i].caps
            if !prevUpper && curUpper { return true }
            prevUpper = curUpper
        }
        return false
    }

    /// Аббревиатура `ALL_CAPS`, набранная с зажатым Shift (при выключенном CapsLock), 2..5 букв:
    /// `TV`, `PR`, `UI`, `API`, `SDK`, `VIP`, `SQL` — не трогаем автоконвертацией.
    public static func isAllCapsAcronym(_ keys: [KeyRec]) -> Bool {
        guard keys.count >= 2 && keys.count <= 5 else { return false }
        return keys.allSatisfy { $0.shift && !$0.caps && KeyCodeMap.letters[$0.code] != nil }
    }

    // ------------------------------------------------------------------ авто-конвертация слова

    private func tryConvertWord(_ word: [KeyRec], resendKey: Int, resendShift: Bool, manual: Bool) -> Bool {
        if s.paused { logLine("convert skip: paused"); return false }
        if word.count < 2 {
            let letter = word.count == 1 ? (effectiveCurrentLayout().map { " '\(LayoutService.render($0, word))'" } ?? "") : ""
            logLine("convert skip: too-short (\(word.count)\(letter))")
            return false
        }
        if !manual && PasswordGuard.isSecureFocused {
            logLine("convert skip: password field")
            return false
        }
        if !manual && wordTainted {
            logLine("convert skip: tainted token (code/digits/path)")
            return false
        }

        updateForeground()
        if isExcludedHere() { logLine("convert skip: excluded app"); return false }

        let layouts = LayoutService.getLayouts()
        if layouts.count < 2 { logLine("convert skip: one layout"); return false }
        let cands = LayoutService.renderAll(word, layouts)

        guard let curID = effectiveCurrentLayout()?.id,
              let cur = cands.first(where: { $0.layoutID == curID }),
              cur.lang >= 0 else {
            logLine("convert skip: cur unknown")
            return false
        }

        if !manual, let startID = wordStartLayoutID, startID != cur.layoutID {
            logLine("convert skip: раскладка сменилась посреди слова")
            return false
        }

        // Защита camelCase/PascalCase (JoeSnow, OpenSwitcher); ALL_CAPS проверяем ниже после анализа цели (P2-3)
        if !manual {
            if Self.hasCamelCaseTransition(word) {
                logLine("convert skip: camelCase ('\(cur.text)')")
                return false
            }
        }

        let typedLow = cur.text.lowercased()
        learnedLock.lock()
        let isRejectedWord = !manual && rejected.contains(typedLow)
        let acceptedWord = !manual && accepted.contains(typedLow)
        learnedLock.unlock()

        if isRejectedWord {
            logLine("convert skip: learned-rejected '\(cur.text)'")
            return false
        }

        guard let best = cands.filter({ $0.layoutID != curID && $0.lang >= 0 }).max(by: { $0.score < $1.score }) else {
            logLine("convert skip: no candidate")
            return false
        }

        // Умный лок после ручного переключения раскладки:
        // Первое слово после тапа Shift защищено на 100% (пароли, ники, одиночные вставки).
        // На последующих словах (autoLockedWordsTyped >= 1), если юзер забыл переключиться обратно
        // и набрал >= 4 букв явного слова другого языка (цель в основном словаре, а набранное
        // биграммно невозможно в текущем языке: 'cfqn'->'сайт', 'ghbdtn'->'привет') — снимаем лок.
        if !manual && s.lockAutoAfterManualSwitch && autoLocked {
            let elapsed = Engine.ms() - autoLockedAt
            if elapsed >= 10.0 {
                autoLocked = false
                autoLockedLang = -1
                autoLockedWordsTyped = 0
                logLine("lock expired (10s)")
            } else {
                let bestCore = LanguageTables.lettersOnly(best.text)
                let curCore = LanguageTables.lettersOnly(cur.text)
                let unambiguousForgotSwitch = autoLockedWordsTyped >= 1
                    && word.count >= 4
                    && WordDict.hasCore(bestCore, best.lang)
                    && !WordDict.has(curCore, cur.lang)
                    && !LanguageTables.possibleWord(curCore, cur.lang)
                if unambiguousForgotSwitch {
                    autoLocked = false
                    autoLockedLang = -1
                    autoLockedWordsTyped = 0
                    logLine("auto-unlock: unambiguous wrong-layout word '\(cur.text)' -> '\(best.text)'")
                } else {
                    logLine("convert skip: locked")
                    return false
                }
            }
        }

        // Порог минимальной длины (s.minWordLen, по умолчанию 3) + закрытый белый список частых 2-буквенных слов
        if !manual && !acceptedWord && word.count < s.minWordLen {
            let allowedEnd: Bool
            if (resendKey == KeyCodeMap.space || resendKey == KeyCodeMap.enter) && !resendShift {
                allowedEnd = true
            } else if resendKey != 0 {
                allowedEnd = (resendKey == KeyCodeMap.comma || resendKey == KeyCodeMap.period ||
                              (resendShift && resendKey == 0x12 /* 1 = ! */) ||
                              (resendShift && (resendKey == 0x1A /* 7 = ? */ || resendKey == KeyCodeMap.slash /* ? */)) ||
                              resendKey == KeyCodeMap.semicolon || resendKey == KeyCodeMap.quote)
            } else {
                allowedEnd = false
            }
            let bestCore = LanguageTables.lettersOnly(best.text)
            if !(word.count == 2 && wordStartClean && allowedEnd &&
                 WordDict.isAllowedTwoLetterAuto(curText: cur.text, bestCore: bestCore, curLang: cur.lang, bestLang: best.lang)) {
                logLine("convert skip: below minWordLen ('\(cur.text)' -> '\(best.text)')")
                return false
            }
        }

        let curCoreLetters = LanguageTables.lettersOnly(cur.text)
        // РУ -> EN короткие слова
        if !manual && !acceptedWord && cur.lang == 0 && best.lang == 1 && word.count < 5 &&
            (word.count < 3 || WordDict.has(curCoreLetters, 0)) {
            logLine("convert skip: ru->en short ('\(cur.text)' -> '\(best.text)')")
            return false
        }

        // РУ -> EN защита любого реального/возможного русского слова
        if !manual && !acceptedWord && cur.lang == 0 && best.lang == 1 &&
            (WordDict.has(curCoreLetters, 0) || LanguageTables.possibleWord(curCoreLetters, 0)) {
            logLine("convert skip: ru->en real ('\(cur.text)' -> '\(best.text)')")
            return false
        }

        if !manual && !acceptedWord && Engine.ms() < noFlipUntil {
            logLine("convert skip: cool-down")
            return false
        }

        var bestText = best.text
        var fuzzyNeighbor: (neighbor: String, dist: Int)? = nil
        if !manual && !acceptedWord {
            if let lastKey = word.last, word.count > 1, KeyCodeMap.isPunctTwinKey(lastKey.code),
               bestText.count > 1, let pc = KeyCodeMap.punctCharOfKey(lastKey.code) {
                let alt = String(bestText.dropLast()) + String(pc)
                let altCore = LanguageTables.lettersOnly(alt)
                let baseCore = LanguageTables.lettersOnly(bestText)
                let altValid = WordDict.has(altCore, best.lang) ||
                    (altCore.count >= 3 && LanguageTables.possibleWord(altCore, best.lang))
                let baseValid = WordDict.has(baseCore, best.lang) ||
                    (baseCore.count >= 3 && LanguageTables.possibleWord(baseCore, best.lang))
                let altDict = WordDict.has(altCore, best.lang), baseDict = WordDict.has(baseCore, best.lang)
                if altValid && (!baseValid || (altDict && !baseDict)) { bestText = alt }
            }
            let core = LanguageTables.lettersOnly(bestText)
            if !WordDict.has(core, best.lang) &&
                (core.count < 3 || !LanguageTables.possibleWord(core, best.lang)) {
                let curCore = LanguageTables.lettersOnly(cur.text)
                if core.count >= 4,
                   !WordDict.has(curCore, cur.lang),
                   !(curCore.count >= 3 && LanguageTables.possibleWord(curCore, cur.lang)) {
                    fuzzyNeighbor = WordDict.dictNeighbor(core, best.lang, maxSubs: 2)
                }
                guard let fuzzy = fuzzyNeighbor else {
                    logLine("convert skip: target-not-in-dict ('\(bestText)')")
                    return false
                }
                logLine("convert: fuzzy-target ('\(bestText)' ≈ '\(fuzzy.neighbor)' dist\(fuzzy.dist))")
            }
        }

        if !manual && !Engine.targetShapeOk(bestText) {
            logLine("convert skip: target-not-letters ('\(bestText)')")
            return false
        }

        var pass = LanguageTables.shouldConvert(curText: cur.text, curLang: cur.lang, curScore: cur.score,
                                                bestText: bestText, bestLang: best.lang, bestScore: best.score,
                                                sensitivity: s.sensitivity)
        if !pass && acceptedWord && bestText == LanguageTables.lettersOnly(bestText) {
            pass = true
        }

        let bestCore = LanguageTables.lettersOnly(bestText)
        let curCore = LanguageTables.lettersOnly(cur.text)

        // P2-3: аббревиатуры (TV, API, SQL) защищаем, НО русские слова в ALL_CAPS без английских
        // гласных (XNJ -> ЧТО, YTN -> НЕТ, GJRF -> ПОКА) разрешаем к автоконвертации
        if !manual && cur.lang == 1 && Self.isAllCapsAcronym(word) {
            let hasEnVowel = curCore.lowercased().contains(where: { "aeiou".contains($0) })
            let isRuCapsWord = word.count >= 3 && best.lang == 0 && !hasEnVowel &&
                fuzzyNeighbor == nil && !WordDict.has(curCore, 1) && WordDict.hasCore(bestCore, 0)
            if !isRuCapsWord {
                logLine("convert skip: all-caps acronym ('\(cur.text)')")
                return false
            }
            logLine("convert: ru all-caps word ('\(cur.text)' -> '\(bestText)')")
        }

        if !manual && !acceptedWord && cur.lang == 1 && Engine.isDomainOrFileName(cur.text) {
            logLine("convert skip: domain/filename ('\(cur.text)')")
            return false
        }

        // P0-2: Защита английских слов со знаками препинания ("here.", "it.", "her,", "keys.", "vs."):
        // если набранное английское ядро — валидное слово в словаре, не переключаем на русский
        if !manual && !acceptedWord && cur.lang == 1 && best.lang == 0 && WordDict.has(curCore, 1) {
            logLine("convert skip: en-word with punctuation ('\(cur.text)' -> '\(bestText)')")
            return false
        }

        if !manual && !acceptedWord && cur.lang == 1 && cur.text.contains("-") {
            let parts = cur.text.split(separator: "-")
            if parts.count >= 2 && parts.allSatisfy({ WordDict.has(String($0), 1) }) {
                logLine("convert skip: en compound word ('\(cur.text)')")
                return false
            }
        }

        // dict-over-score разрешён ТОЛЬКО для чистого основного словаря (hasCore),
        // чтобы шум из 350k субтитров (Huge) не пробивал скоринг в одиночку
        if !pass && !acceptedWord && WordDict.hasCore(bestCore, best.lang) && !WordDict.has(curCore, cur.lang) {
            pass = true
            logLine("convert: dict-over-score ('\(cur.text)' -> '\(bestText)')")
        }

        if !pass && !acceptedWord && cur.lang == 1 && best.lang == 0 &&
            cur.text.contains(where: { ",.;'".contains($0) }) &&
            bestText == bestCore &&
            LanguageTables.possibleWord(bestCore, 0) &&
            !WordDict.has(curCore, 1) &&
            bestCore.count >= 5 {
            pass = true
            logLine("convert: punct-twin signal ('\(cur.text)' -> '\(bestText)')")
        }

        if pass && !acceptedWord && !WordDict.has(bestCore, best.lang) {
            let need = ((fuzzyNeighbor?.dist ?? 2) == 1 ? 1 : 2) * LanguageTables.baseMargin / max(0.3, s.sensitivity)
            if best.score - cur.score < need {
                logLine("convert skip: non-dict margin ('\(cur.text)' -> '\(bestText)')")
                return false
            }
        }

        if pass && !acceptedWord && WordDict.has(curCore, cur.lang) && !WordDict.has(bestCore, best.lang) {
            logLine("convert skip: cur-in-dict, target-not ('\(cur.text)' -> '\(bestText)')")
            return false
        }
        if !pass {
            logLine("convert skip: score ('\(cur.text)' -> '\(bestText)')")
            return false
        }

        if Engine.ms() - lastPasteAt < 0.35 {
            logLine("convert skip: paste settle window")
            return false
        }

        // Ретро-флип одиночной буквы перед словом ('f␣ns' -> «а ты»)
        var retroFrom: String? = nil, retroTo = ""
        if !manual && resendKey != 0, let ps = prevSingle, prevSingleApp == fgApp,
           prevSingleLayoutID == cur.layoutID,
           let curL = layouts.first(where: { $0.id == cur.layoutID }),
           let bestL = layouts.first(where: { $0.id == best.layoutID }) {
            let pCur = LayoutService.render(curL, ps)
            let pBest = LayoutService.render(bestL, ps)
            if Engine.retroFlipLetterOk(pCur, cur.lang, pBest, best.lang) {
                retroFrom = pCur
                retroTo = pBest
            }
        }
        prevSingle = nil
        let retroPrefix = retroFrom.map { $0 + " " } ?? ""
        let retroText = retroFrom != nil ? retroTo + " " : ""
        let retroLog = retroFrom != nil ? " (+retro '\(retroFrom!)' -> '\(retroTo)')" : ""

        let curLayoutObj = layouts.first(where: { $0.id == cur.layoutID })
        let bestLayoutObj = layouts.first(where: { $0.id == best.layoutID })
        let sepText = (resendKey != 0 && resendKey != KeyCodeMap.enter)
            ? TextConverter.renderKeyChar(keyCode: resendKey, shift: resendShift, layout: curLayoutObj) : ""
        let sentSep = Engine.sepInLayout(resendKey, resendShift, bestLayoutObj, sepText)

        let bsCount = word.count + retroPrefix.count
        let expectedTail = retroPrefix + cur.text
        logLine("convert OK: '\(cur.text)' -> '\(bestText)'\(retroLog) (resend=\(resendKey) bs=\(bsCount) app=\(fgProc))")
        lastConvertInfo = "'\(retroPrefix)\(cur.text)' -> '\(retroText)\(bestText)'"
        lastWord = word
        lastWordSepKey = 0

        if resendKey == KeyCodeMap.space {
            lastSpaceTextTick = Engine.ms()
        }

        let sureFix = acceptedWord || WordDict.has(bestCore, best.lang)
        let targetSwitchLayout: LayoutService.LayoutData? = (resendKey != KeyCodeMap.enter || sureFix) ? bestLayoutObj : nil
        if let bl = targetSwitchLayout {
            expectLayout(bl)
            armGap(for: bl)
        }

        let injOk = accessibilityTrusted(prompt: false)
        undoPending = resendKey != KeyCodeMap.enter && injOk
        undoFromAuto = !manual
        autoRejectEligible = !manual && undoPending
        undoErasedByBs = 0
        undoText = cur.text
        undoConvertedTail = retroText + bestText + sentSep
        undoLen = bestText.count + sentSep.count
        undoPrefix = retroPrefix
        undoPrefixLen = retroText.count
        undoSepText = sepText
        undoLayout = curLayoutObj
        undoApp = fgApp
        undoAt = Engine.ms()
        keysSinceUndoPoint = 0
        undoTail.removeAll()
        undoTailBroken = false

        // Асинхронная инжекция на serial-очереди (0 мс блокировки потока тапа!)
        inFlightInjections += 1
        let finalTargetText = bestText
        injectorQueue.async { [weak self] in
            guard let self = self else { return }
            let verdict = self.checkScreenBeforeAutoInject(expectedTail: expectedTail, targetText: finalTargetText)
            if verdict == .alreadyTarget {
                self.logLine("convert skip-inject: экран уже показывает '\(finalTargetText)' — досылаю только разделитель")
                self.performOnTapThread { [weak self] in
                    self?.undoPending = false
                    self?.autoRejectEligible = false
                }
                if resendKey == KeyCodeMap.enter { TextConverter.sendEnter() }
                else if !sentSep.isEmpty { TextConverter.sendUnicode(sentSep) }
            } else {
                TextConverter.sendBackspaces(bsCount)
                usleep(25_000) // 25 мс settle: редактор гарантированно коммитит все deleteBackward:
                TextConverter.sendUnicode(retroText + finalTargetText)
                if resendKey == KeyCodeMap.enter {
                    usleep(6_000)
                    TextConverter.sendEnter()
                } else if !sentSep.isEmpty {
                    TextConverter.sendUnicode(sentSep)
                }
            }
            if let bl = targetSwitchLayout {
                self.switchLayoutOnMain(bl, source: "convert")
                self.verifySwitch(target: bl)
            }
            self.performOnTapThread { [weak self] in
                guard let self = self else { return }
                self.inFlightInjections = max(0, self.inFlightInjections - 1)
            }
        }

        // ВАЖНО: слепая авто-запись в accepted.txt по 15-секундному таймеру УДАЛЕНА —
        // без клавиши Break на Mac она навсегда цементировала любые случайные срабатывания.
        fireConverted(retroPrefix + cur.text, retroText + bestText)
        return true
    }

    public static func targetShapeOk(_ t: String) -> Bool {
        let core = LanguageTables.lettersOnly(t)
        if core.isEmpty { return false }
        if t == core || (t.count == core.count + 1 && t.hasPrefix(core)) {
            return true
        }
        // Разрешаем дефисные слова: "какой-то", "из-за", "кто-нибудь" (P1-3)
        // Но не ведущие/хвостовые дефисы и не двойные дефисы
        let wordPart = (t.count > 0 && ",.;:!?\"'".contains(t.last!)) ? String(t.dropLast()) : t
        if wordPart.contains("-") && !wordPart.hasPrefix("-") && !wordPart.hasSuffix("-") && !wordPart.contains("--") {
            let parts = wordPart.split(separator: "-", omittingEmptySubsequences: false)
            if parts.count >= 2 && parts.allSatisfy({ !$0.isEmpty && LanguageTables.lettersOnly(String($0)) == String($0) }) {
                return true
            }
        }
        return false
    }

    public static func isDomainOrFileName(_ text: String) -> Bool {
        guard text.contains(".") else { return false }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        for (i, p) in parts.enumerated() {
            if p.isEmpty { return false }
            if i == parts.count - 1 {
                if p.count < 1 || p.count > 6 { return false }
                if !p.allSatisfy({ ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") }) { return false }
            } else {
                if !p.allSatisfy({ ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9") || $0 == "-" || $0 == "_" }) { return false }
            }
        }
        return true
    }

    static func sepInLayout(_ code: Int, _ shift: Bool, _ layout: LayoutService.LayoutData?, _ typed: String) -> String {
        guard !typed.isEmpty, let l = layout, let t = LayoutService.renderKey(l, KeyRec(code, shift, false)),
              t.count == 1 else { return typed }
        return t
    }

    public static func retroFlipLetterOk(_ typed: String, _ typedLang: Int, _ target: String, _ targetLang: Int) -> Bool {
        return typed.count == 1 && target.count == 1 &&
            typedLang >= 0 && targetLang >= 0 && typedLang != targetLang &&
            LanguageTables.langOf(typed) == typedLang && LanguageTables.langOf(target) == targetLang &&
            !WordDict.hasSingleLetterWord(typed, typedLang) &&
            WordDict.hasSingleLetterWord(target, targetLang)
    }

    public func toggleAuto() {
        let next = s.clone()
        next.paused.toggle()
        if !next.paused {
            autoLocked = false
            autoLockedLang = -1
            autoLockedWordsTyped = 0
        }
        let paused = next.paused
        stateLock.lock()
        _s = next
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            SettingsStore.save(next)
            self.apply(next)
        }
        fireInfo(paused ? "Автоисправление выключено" : "Автоисправление включено")
    }

    // ------------------------------------------------------------------ откат (Undo) и ручной флип

    private func undoBlockReason() -> String? {
        if !undoPending { return "nothing pending" }
        if undoTailBroken { return "tail broken" }
        updateForeground()
        if undoApp != fgApp { return "other window" }
        let age = Engine.ms() - undoAt
        if age < 0 || age > 15 { return "stale" }
        return nil
    }

    private static func undoBlockMessage(_ reason: String) -> String {
        switch reason {
        case "tail broken": return "Слишком много набрано после"
        case "other window": return "Уже в другом окне"
        case "stale": return "Слишком поздно"
        default: return "Нечего отменять"
        }
    }

    public func undoLastConversion() {
        performOnTapThread { [weak self] in self?.undoLastConversionOnTap() }
    }

    private func undoLastConversionOnTap() {
        if let block = undoBlockReason() {
            logLine("undo skip: \(block)")
            fireInfo(Engine.undoBlockMessage(block))
            return
        }

        let bs = undoPrefixLen + undoLen + undoTail.count
        let tailText = undoTail.isEmpty ? "" : (undoLayout.map { LayoutService.render($0, undoTail) } ?? "")
        let restore = undoPrefix + undoText + undoSepText + tailText
        let expectedScreenTail = undoConvertedTail + tailText
        let ul = undoLayout
        let learned = undoText
        let wasAuto = undoFromAuto

        prevSingle = nil
        undoPending = false
        autoRejectEligible = false

        inFlightInjections += 1
        injectorQueue.async { [weak self] in
            guard let self = self else { return }
            // P0-7: AX-гейт перед откатом — не стирать чужой текст при рассинхроне каретки
            if !expectedScreenTail.isEmpty {
                let gate = self.verifyTailForManualAction(expectedScreenTail)
                if gate.available && !gate.matches {
                    self.logLine("undo REFUSED: у каретки '\(gate.actual)' вместо '\(expectedScreenTail)'")
                    self.fireInfo("У курсора другой текст — отмена пропущена")
                    self.performOnTapThread { [weak self] in
                        guard let self = self else { return }
                        self.inFlightInjections = max(0, self.inFlightInjections - 1)
                    }
                    return
                }
            }
            TextConverter.sendBackspaces(bs)
            usleep(25_000)
            TextConverter.sendUnicode(restore)
            if let targetL = ul {
                self.switchLayoutOnMain(targetL, source: "undo")
                self.verifySwitch(target: targetL)
            }
            if wasAuto {
                self.rememberRejected(learned)
                self.removeAccepted(learned)
            }
            self.fireInfo(wasAuto ? "Отменено: \(restore) · больше не исправлять" : "Возвращено: \(restore)")
            self.performOnTapThread { [weak self] in
                guard let self = self else { return }
                self.noFlipUntil = Engine.ms() + 5.0
                if restore.hasSuffix(" ") { self.lastSpaceTextTick = Engine.ms() }
                if let targetL = ul {
                    let probe = [KeyRec(KeyCodeMap.ansiCode(ofLatin: "a"), false, false)]
                    let lang = LanguageTables.langOf(LayoutService.render(targetL, probe))
                    self.expectLayout(targetL)
                    self.armGap(for: targetL)
                    self.lockAutoSwitch(lang: lang)
                }
                self.inFlightInjections = max(0, self.inFlightInjections - 1)
            }
        }
    }

    public func forgetAllWords() {
        learnedLock.lock()
        rejected.removeAll()
        accepted.removeAll()
        learnedLock.unlock()
        ioQueue.async {
            try? FileManager.default.createDirectory(atPath: SettingsStore.dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: self.learnedPath, contents: nil)
            FileManager.default.createFile(atPath: self.acceptedPath, contents: nil)
        }
        fireInfo("Память слов очищена")
    }

    public func doFixLastWord() {
        performOnTapThread { [weak self] in self?.doFixLastWordOnTap() }
    }

    private func doFixLastWordOnTap() {
        updateForeground()
        if buf.count >= 1 {
            _ = forceConvertWord(buf.snapshot(), trailSepKey: 0, skipRejected: true, skipLearn: false)
            buf.clear()
            return
        }
        if !lastWord.isEmpty && lastWordSepKey != 0 && lastWordApp == fgApp &&
            (Engine.ms() - lastWordAt) < 10 && lastBsAt <= lastWordAt {
            _ = forceConvertWord(lastWord, trailSepKey: lastWordSepKey, trailSepShift: lastWordSepShift,
                                 skipRejected: true, skipLearn: false)
            return
        }
        logLine("fix-last-word: select-left path")
        TextConverter.sendCombo(keyCode: 0x7B /* Left */, mods: HK.ALT | HK.SHIFT)
        beginFixSelection(fromFixWord: true)
    }

    @discardableResult
    public func forceFlipLastWord() -> Bool {
        updateForeground()
        if buf.count >= 1 {
            logLine("force-flip: current buffer (\(buf.count) keys)")
            let ok = forceConvertWord(buf.snapshot(), trailSepKey: 0, skipRejected: true, skipLearn: false)
            buf.clear()
            return ok
        }
        if buf.count == 0 && !lastWord.isEmpty && lastWordSepKey != 0 &&
            lastWordApp == fgApp && (Engine.ms() - lastWordAt) < 10 && lastBsAt <= lastWordAt {
            logLine("force-flip: exact path (last word, sep=0x\(String(lastWordSepKey, radix: 16)))")
            return forceConvertWord(lastWord, trailSepKey: lastWordSepKey, trailSepShift: lastWordSepShift,
                                    skipRejected: true, skipLearn: false)
        }
        logLine("force-flip skip: no fresh word at caret")
        return false
    }

    /// Ручной переворот слова через единую очередь `injectorQueue` (БЕЗ затирания
    /// `NSPasteboard`, работает при скриншотах в буфере обмена и не оставляет
    /// открытых выделений под пальцами).
    private func forceConvertWord(_ word: [KeyRec], trailSepKey: Int, trailSepShift: Bool = false,
                                  skipRejected: Bool = false, skipLearn: Bool = false) -> Bool {
        updateForeground()
        if isExcludedHere() || PasswordGuard.isSecureFocused {
            logLine("force-flip skip: excluded/password")
            return false
        }
        let layouts = LayoutService.getLayouts()
        if layouts.count < 2 { logLine("force-flip skip: one layout"); return false }
        let cands = LayoutService.renderAll(word, layouts)

        guard let curID = effectiveCurrentLayout()?.id,
              let cur = cands.first(where: { $0.layoutID == curID }), cur.lang >= 0 else {
            logLine("force-flip skip: cur unknown")
            return false
        }
        guard let best = cands.filter({ $0.layoutID != curID && $0.lang >= 0 }).max(by: { $0.score < $1.score }),
              best.text != cur.text else {
            logLine("force-flip skip: no other reading")
            return false
        }

        if Engine.ms() - lastPasteAt < 0.35 {
            logLine("force-flip REFUSED: paste settle window")
            fireInfo("Только что была вставка — повтори через долю секунды")
            return false
        }

        let curLayoutObj = layouts.first(where: { $0.id == cur.layoutID })
        let bestLayoutObj = layouts.first(where: { $0.id == best.layoutID })
        // P2-5: правило хвостового знака-двойника и в ручном флипе ('ghbdtn,' -> 'привет,')
        var targetText = best.text
        if let lastKey = word.last, word.count > 1, KeyCodeMap.isPunctTwinKey(lastKey.code),
           targetText.count > 1, let pc = KeyCodeMap.punctCharOfKey(lastKey.code) {
            let alt = String(targetText.dropLast()) + String(pc)
            let altCore = LanguageTables.lettersOnly(alt)
            let baseCore = LanguageTables.lettersOnly(targetText)
            let altValid = WordDict.has(altCore, best.lang) ||
                (altCore.count >= 3 && LanguageTables.possibleWord(altCore, best.lang))
            let baseValid = WordDict.has(baseCore, best.lang) ||
                (baseCore.count >= 3 && LanguageTables.possibleWord(baseCore, best.lang))
            let altDict = WordDict.has(altCore, best.lang), baseDict = WordDict.has(baseCore, best.lang)
            if altValid && (!baseValid || (altDict && !baseDict)) { targetText = alt }
        }
        let trailLen = trailSepKey != 0 ? 1 : 0
        let trailTyped = trailSepKey != 0 ? TextConverter.renderKeyChar(keyCode: trailSepKey, shift: trailSepShift, layout: curLayoutObj) : ""
        let trailSent = Engine.sepInLayout(trailSepKey, trailSepShift, bestLayoutObj, trailTyped)
        let expectedTail = cur.text + trailTyped
        let bsCount = word.count + trailLen

        logLine("force-flip: '\(cur.text)' -> '\(targetText)' (bs=\(bsCount) app=\(fgProc))")
        lastConvertInfo = "force '\(cur.text)' -> '\(targetText)'"

        let fromText = cur.text
        let toText = targetText
        let fromLang = cur.lang
        let toCore = LanguageTables.lettersOnly(targetText)
        let switchTarget: LayoutService.LayoutData? = (word.count > 1) ? bestLayoutObj : nil

        if let bl = switchTarget {
            expectLayout(bl)
            armGap(for: bl)
        }
        if trailSepKey == KeyCodeMap.space {
            lastSpaceTextTick = Engine.ms()
        }

        // P1-7: инициализируем состояние отката и lastWord СИНХРОННО на потоке тапа (до injectorQueue),
        // чтобы быстрый ввод следующих клавиш не затирался асинхронно по завершении очереди;
        // если AX-гейт откажет, undoPending откатывается назад.
        let prevLastWord = lastWord
        let prevLastWordAt = lastWordAt
        let prevLastWordApp = lastWordApp
        let prevLastWordSepKey = lastWordSepKey
        let prevLastWordSepShift = lastWordSepShift

        undoPending = true
        undoFromAuto = false
        autoRejectEligible = false
        undoErasedByBs = 0
        undoText = fromText
        undoConvertedTail = toText + trailSent
        undoLen = toText.count + trailSent.count
        undoPrefix = ""
        undoPrefixLen = 0
        prevSingle = nil
        undoSepText = trailTyped
        undoLayout = curLayoutObj
        undoApp = fgApp
        undoAt = Engine.ms()
        keysSinceUndoPoint = 0
        undoTail.removeAll()
        undoTailBroken = false

        lastWord = word
        lastWordAt = undoAt
        lastWordApp = fgApp
        lastWordSepKey = trailSepKey
        lastWordSepShift = trailSepShift

        inFlightInjections += 1
        injectorQueue.async { [weak self] in
            guard let self = self else { return }
            let gate = self.verifyTailForManualAction(expectedTail)
            if gate.available && !gate.matches {
                self.logLine("force-flip REFUSED: у каретки '\(gate.actual)' вместо '\(expectedTail)'")
                self.fireInfo("У курсора другое слово — выдели его и нажми Option")
                self.performOnTapThread { [weak self] in
                    guard let self = self else { return }
                    self.undoPending = false
                    self.undoTailBroken = true
                    self.lastWord = prevLastWord
                    self.lastWordAt = prevLastWordAt
                    self.lastWordApp = prevLastWordApp
                    self.lastWordSepKey = prevLastWordSepKey
                    self.lastWordSepShift = prevLastWordSepShift
                    self.inFlightInjections = max(0, self.inFlightInjections - 1)
                }
                return
            }

            TextConverter.sendBackspaces(bsCount)
            usleep(25_000)
            TextConverter.sendUnicode(toText + trailSent)

            if let bl = switchTarget {
                self.switchLayoutOnMain(bl, source: "force-flip")
                self.verifySwitch(target: bl)
            }
            self.fireConverted(fromText, toText)

            self.performOnTapThread { [weak self] in
                guard let self = self else { return }
                self.inFlightInjections = max(0, self.inFlightInjections - 1)
                let low = fromText.lowercased()
                if self.isRejected(low) && !skipLearn {
                    self.removeRejected(low)
                }
                // P2-5: защита RU->EN в rememberAccepted — не запоминаем возможное русское слово и мусорные EN-цели
                let canLearnAccepted = (fromLang == 1) ||
                    (!LanguageTables.possibleWord(fromText, 0) && WordDict.hasCore(toCore, 1))
                if !skipLearn && canLearnAccepted && fromText.count >= 3 && fromText == LanguageTables.lettersOnly(fromText) &&
                    !WordDict.has(fromText, fromLang) {
                    self.rememberAccepted(low)
                }
            }
        }
        return true
    }

    /// Option-тап («как в Caramba»):
    /// P1-7: проверяет `isExcludedHere() / PasswordGuard.isSecureFocused` ПЕРВЫМ делом и не блокирует `tapCallback`
    /// синхронным ожиданием AX-выделения на main-очереди.
    private func carambaFlip() {
        updateForeground()
        if isExcludedHere() || PasswordGuard.isSecureFocused {
            logLine("caramba-flip skip: excluded/password")
            return
        }
        if undoPending && undoFromAuto && keysSinceUndoPoint == 0 && undoBlockReason() == nil {
            logLine("caramba-flip: undo recent auto-convert ('\(undoText)')")
            undoLastConversionOnTap()
            return
        }
        if buf.count >= 1 {
            logLine("caramba-flip: live buffer (\(buf.count) keys)")
            _ = forceConvertWord(buf.snapshot(), trailSepKey: 0, skipRejected: true, skipLearn: true)
            buf.clear()
            return
        }
        let seqAtTap = currentInputSeq
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.currentInputSeq == seqAtTap else { return }
            if let sel = PasswordGuard.selectedText(), !sel.isEmpty, sel.count <= 500 {
                self.logLine("caramba-flip: user selection (\(sel.count) chars)")
                self.beginFixSelection(fromFixWord: false)
                return
            }
            self.performOnTapThread { [weak self] in
                guard let self = self else { return }
                guard self.currentInputSeq == seqAtTap else { return }
                self.updateForeground()
                if self.isExcludedHere() || PasswordGuard.isSecureFocused { return }
                if !self.lastWord.isEmpty && self.lastWordSepKey != 0 &&
                    self.lastWordApp == self.fgApp && (Engine.ms() - self.lastWordAt) < 10 && self.lastBsAt <= self.lastWordAt {
                    self.logLine("caramba-flip: exact path (last word, sep=0x\(String(self.lastWordSepKey, radix: 16)))")
                    _ = self.forceConvertWord(self.lastWord, trailSepKey: self.lastWordSepKey, trailSepShift: self.lastWordSepShift,
                                              skipRejected: true, skipLearn: true)
                    return
                }
                if !self.lastWord.isEmpty && self.lastWordSepKey == 0 && self.keysSinceUndoPoint == 0 &&
                    self.lastWordApp == self.fgApp && (Engine.ms() - self.lastWordAt) < 10 && self.lastBsAt <= self.lastWordAt {
                    self.logLine("caramba-flip: last word without sep")
                    _ = self.forceConvertWord(self.lastWord, trailSepKey: 0, skipRejected: true, skipLearn: true)
                    return
                }
                self.logLine("caramba-flip: refuse (no fresh word or selection)")
                self.fireInfo("Нет свежего слова у курсора — выдели текст и нажми Option")
            }
        }
    }

    private func pastePlainAction() {
        let app = fgApp
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let pb = NSPasteboard.general
            let tiffData = pb.data(forType: .tiff)
            let pngData = pb.data(forType: .png)
            let text = TextConverter.getClipboardTextOnMain()
            if (text == nil || text?.isEmpty == true) && (tiffData != nil || pngData != nil) {
                // P2-2: в буфере только картинка (скриншот) — вставляем без перезаписи буфера
                TextConverter.targetPid = app
                self.lastPasteAt = Engine.ms()
                TextConverter.sendCombo(keyCode: KeyCodeMap.ansiCode(ofLatin: "v"), mods: HK.CMD)
                self.logLine("paste-plain: image-only paste preserved")
                return
            }
            guard let cleanText = text, !cleanText.isEmpty else {
                self.logLine("paste-plain skip: no text in clipboard")
                self.fireInfo("В буфере обмена нет текста")
                return
            }
            pb.clearContents()
            pb.setString(cleanText, forType: .string)
            // Сохраняем растровую картинку, если она шла в паре с богатым текстом
            if let tiff = tiffData { pb.setData(tiff, forType: .tiff) }
            if let png = pngData { pb.setData(png, forType: .png) }
            TextConverter.targetPid = app
            self.lastPasteAt = Engine.ms()
            TextConverter.sendCombo(keyCode: KeyCodeMap.ansiCode(ofLatin: "v"), mods: HK.CMD)
            self.logLine("paste-plain: sent Cmd+V (\(cleanText.count) chars)")
        }
    }

    // ------------------------------------------------------------------ конвертация выделенного (строго на main!)

    private var selTimer: Timer?
    private var selApp: pid_t = 0
    private var selTries = 0
    private var selPhase = 0
    private var selFromFixWord = false
    private var selRetried = false
    private var selSnapshot: PasteboardSnapshot?
    private var selBaseSeq = 0
    private var selStartInputSeq: UInt64 = 0
    private var pendingRestoreSnapshot: PasteboardSnapshot?
    private var pendingRestorePasteSeq = 0

    public func beginFixSelection(fromFixWord: Bool) {
        updateForeground()
        let app = fgApp
        let startInputSeq = currentInputSeq
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.selApp = app
            self.selFromFixWord = fromFixWord
            self.selRetried = false
            self.selStartInputSeq = startInputSeq
            let snap: PasteboardSnapshot
            if let pending = self.pendingRestoreSnapshot,
               TextConverter.clipboardChangeCountOnMain() == self.pendingRestorePasteSeq {
                snap = pending
                self.pendingRestoreSnapshot = nil
            } else {
                snap = TextConverter.savePasteboardOnMain()
            }
            self.selSnapshot = snap
            self.selBaseSeq = snap.changeCount
            self.selPhase = 0
            self.selTries = 0
            self.restartSelTimerOnMain()
            self.logLine("sel: started (savedItems=\(snap.items.count))")
        }
    }

    private func restartSelTimerOnMain() {
        dispatchPrecondition(condition: .onQueue(.main))
        selTimer?.invalidate()
        selTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.selPollTickOnMain()
        }
    }

    private func deselectIfOursOnMain() {
        guard selFromFixWord else { return }
        if let s = PasswordGuard.selectedText(), s.isEmpty { return }
        TextConverter.sendCombo(keyCode: 0x7C /* Right */, mods: 0)
    }

    private func selPollTickOnMain() {
        dispatchPrecondition(condition: .onQueue(.main))
        if selPhase == 0 {
            let f = CGEventSource.flagsState(.hidSystemState)
            let held = f.contains(.maskShift) || f.contains(.maskControl) || f.contains(.maskAlternate) || f.contains(.maskCommand)
            selTries += 1
            if held && selTries < 10 { return }
            selPhase = 1
            selTries = 0
            TextConverter.targetPid = selApp
            TextConverter.sendCombo(keyCode: KeyCodeMap.ansiCode(ofLatin: "c"), mods: HK.CMD)
            logLine("sel: cmd+c sent")
            return
        }

        let curSeq = TextConverter.clipboardChangeCountOnMain()
        let text = TextConverter.getClipboardTextOnMain() ?? ""
        let seqChanged = curSeq != selBaseSeq
        selTries += 1
        if (!seqChanged || text.isEmpty) && selTries < 16 { return }
        selTimer?.invalidate()
        selTimer = nil

        guard seqChanged, !text.isEmpty else {
            if selFromFixWord && !selRetried {
                selRetried = true
                selPhase = 0
                selTries = 0
                TextConverter.targetPid = selApp
                TextConverter.sendCombo(keyCode: 0x7B, mods: HK.ALT | HK.SHIFT)
                TextConverter.sendCombo(keyCode: 0x7B, mods: HK.ALT | HK.SHIFT)
                restartSelTimerOnMain()
                logLine("sel: retry with 2 words left")
                return
            }
            logLine("sel: failed to copy selection")
            deselectIfOursOnMain()
            if let snap = selSnapshot, s.restoreClipboard {
                TextConverter.restorePasteboardOnMain(snap, expectedChangeCount: curSeq)
            }
            selSnapshot = nil
            fireInfo("Не удалось скопировать выделение")
            return
        }

        let lang = LanguageTables.langOf(LanguageTables.lettersOnly(text))
        if lang < 0 {
            logLine("sel: lang unknown")
            deselectIfOursOnMain()
            if let snap = selSnapshot, s.restoreClipboard {
                TextConverter.restorePasteboardOnMain(snap, expectedChangeCount: curSeq)
            }
            selSnapshot = nil
            fireInfo("Не удалось определить язык выделенного текста")
            return
        }

        guard currentInputSeq == selStartInputSeq else {
            logLine("sel REFUSED: ввод пользователя во время опроса буфера")
            deselectIfOursOnMain()
            if let snap = selSnapshot, s.restoreClipboard {
                TextConverter.restorePasteboardOnMain(snap, expectedChangeCount: curSeq)
            }
            selSnapshot = nil
            return
        }

        let converted = CharMaps.mapText(text, toRu: lang == 1)
        if let liveSel = PasswordGuard.selectedText(), liveSel != text {
            logLine("sel REFUSED: выделение изменилось ('\(liveSel.prefix(20))' != '\(text.prefix(20))')")
            deselectIfOursOnMain()
            if let snap = selSnapshot, s.restoreClipboard {
                TextConverter.restorePasteboardOnMain(snap, expectedChangeCount: curSeq)
            }
            selSnapshot = nil
            fireInfo("Выделение изменилось — конвертация отменена")
            return
        }

        let pasteSeq = TextConverter.setTransientClipboardTextOnMain(converted)
        TextConverter.targetPid = selApp
        lastPasteAt = Engine.ms()
        TextConverter.sendCombo(keyCode: KeyCodeMap.ansiCode(ofLatin: "v"), mods: HK.CMD)
        logLine("sel: pasted converted (\(text.count) chars, lang=\(lang))")
        lastConvertInfo = "sel '\(text)' -> '\(converted)'"

        let targetLang = lang == 1 ? 0 : 1
        if let target = LayoutService.findLayoutByLang(targetLang) {
            logLine("layout switch: ? -> \(target.id.prefix(8)) (fix-selection)")
            _ = LayoutService.switchTo(target)
            performOnTapThread { [weak self] in
                guard let self = self else { return }
                self.expectLayout(target)
                self.armGap(for: target)
                self.lockAutoSwitch(lang: targetLang)
            }
        }

        if let snap = selSnapshot, s.restoreClipboard {
            self.pendingRestoreSnapshot = snap
            self.pendingRestorePasteSeq = pasteSeq
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self = self else { return }
                if let pSnap = self.pendingRestoreSnapshot, self.pendingRestorePasteSeq == pasteSeq {
                    TextConverter.restorePasteboardOnMain(pSnap, expectedChangeCount: pasteSeq)
                    self.pendingRestoreSnapshot = nil
                }
            }
        }
        selSnapshot = nil

        if converted != text { fireConverted(text, converted) }
        else { fireInfo("Раскладка уже верная") }
    }

    // ------------------------------------------------------------------ обучение

    var learnedPath: String { SettingsStore.dir + "/learned.txt" }
    var acceptedPath: String { SettingsStore.dir + "/accepted.txt" }

    private func loadLearned() {
        if let t = try? String(contentsOfFile: learnedPath, encoding: .utf8) {
            for line in t.components(separatedBy: .newlines) {
                let w = line.trimmingCharacters(in: .whitespaces).lowercased()
                if !w.isEmpty { rejected.insert(w) }
            }
        }
        if let t = try? String(contentsOfFile: acceptedPath, encoding: .utf8) {
            for line in t.components(separatedBy: .newlines) {
                let w = line.trimmingCharacters(in: .whitespaces).lowercased()
                if !w.isEmpty { accepted.insert(w) }
            }
        }
    }

    private func isRejected(_ word: String) -> Bool {
        learnedLock.lock()
        defer { learnedLock.unlock() }
        return rejected.contains(word)
    }

    private func rememberRejected(_ typed: String) {
        learnedLock.lock()
        defer { learnedLock.unlock() }
        guard rejected.count < rejectedCap else { return }
        let w = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !w.isEmpty, !rejected.contains(w) else { return }
        rejected.insert(w)
        accepted.remove(w)
        appendFile(learnedPath, w)
    }

    private func rememberAccepted(_ typed: String) {
        learnedLock.lock()
        defer { learnedLock.unlock() }
        guard accepted.count < rejectedCap else { return }
        let w = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !w.isEmpty, !accepted.contains(w) else { return }
        accepted.insert(w)
        rejected.remove(w)
        appendFile(acceptedPath, w)
    }

    private let ioQueue = DispatchQueue(label: "os.io", qos: .utility)

    private func removeAccepted(_ typed: String) {
        learnedLock.lock()
        let removed = accepted.remove(typed.lowercased()) != nil
        let snapshot = accepted
        learnedLock.unlock()
        guard removed else { return }
        ioQueue.async {
            try? FileManager.default.createDirectory(atPath: SettingsStore.dir, withIntermediateDirectories: true)
            let content = snapshot.isEmpty ? "" : snapshot.sorted().joined(separator: "\n") + "\n"
            let _ = try? content.write(toFile: self.acceptedPath, atomically: true, encoding: .utf8)
        }
    }

    private func removeRejected(_ typed: String) {
        learnedLock.lock()
        let removed = rejected.remove(typed.lowercased()) != nil
        let snapshot = rejected
        learnedLock.unlock()
        guard removed else { return }
        ioQueue.async {
            try? FileManager.default.createDirectory(atPath: SettingsStore.dir, withIntermediateDirectories: true)
            let content = snapshot.isEmpty ? "" : snapshot.sorted().joined(separator: "\n") + "\n"
            let _ = try? content.write(toFile: self.learnedPath, atomically: true, encoding: .utf8)
        }
    }

    private func appendFile(_ path: String, _ line: String) {
        ioQueue.async {
            try? FileManager.default.createDirectory(atPath: SettingsStore.dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            let handle = FileHandle(forWritingAtPath: path)
            defer { handle?.closeFile() }
            handle?.seekToEndOfFile()
            if let d = (line + "\n").data(using: .utf8) { handle?.write(d) }
        }
    }

    // ------------------------------------------------------------------ вспомогательное

    public func caretPoint() -> NSPoint {
        NSEvent.mouseLocation
    }

    private func fireConverted(_ old: String, _ new: String) {
        let o = old, n = new
        DispatchQueue.main.async { [weak self] in
            self?.onConverted?(o, n)
        }
    }

    private func fireInfo(_ msg: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onInfo?(msg)
        }
    }

    private let logQueue = DispatchQueue(label: "os.log", qos: .utility)
    private var logBuf: [String] = []
    private let logLock = NSLock()

    private static let logDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    func logLine(_ line: String) {
        guard s.devLog else { return }
        logLock.lock()
        let entry = "\(Self.logDateFormatter.string(from: Date()))  \(line)"
        logBuf.append(entry)
        logLock.unlock()
        logQueue.async { [weak self] in
            guard let self = self else { return }
            self.logLock.lock()
            let chunk = self.logBuf
            self.logBuf.removeAll()
            self.logLock.unlock()
            guard !chunk.isEmpty else { return }
            try? FileManager.default.createDirectory(atPath: SettingsStore.dir, withIntermediateDirectories: true)
            let p = SettingsStore.dir + "/log.txt"
            if let attr = try? FileManager.default.attributesOfItem(atPath: p),
               let size = attr[.size] as? Int, size > 10 * 1024 * 1024 {
                let _ = try? "".write(toFile: p, atomically: true, encoding: .utf8)
            }
            if !FileManager.default.fileExists(atPath: p) {
                FileManager.default.createFile(atPath: p, contents: nil)
            }
            if let handle = FileHandle(forWritingAtPath: p) {
                defer { handle.closeFile() }
                handle.seekToEndOfFile()
                if let d = (chunk.joined(separator: "\n") + "\n").data(using: .utf8) { handle.write(d) }
            }
        }
    }
}
