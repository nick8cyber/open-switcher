import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore

/// Сердце программы (порт Engine.cs): CGEventTap, буфер слова, детект неверной
/// раскладки, исполнение исправлений (по Enter, по концу слова, хоткеями,
/// double-Shift), самообучение и откат автозамен.
public final class Engine {
    public var s: Settings

    private var tap: CFMachPort?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?   // runloop потока тапа (для сериализации с main)

    private let buf = WordBuffer()
    private var lastWord: [KeyRec] = []
    private var lastWordAt: TimeInterval = 0
    private var lastWordSepKey = 0        // разделитель сразу после последнего слова (0 = неизвестен/Enter)
    private var lastWordApp: pid_t = 0    // приложение, где набрано последнее слово (0 = неизвестно)
    private var noFlipUntil: TimeInterval = 0  // кулдаун 5 с после ручной правки (спека v3 §6.2)
    private var markCount = 0
    private var wdTicks = 0

    private var suppressUntil: TimeInterval = 0
    private var lastShiftDown: TimeInterval = 0
    private var anyKeySinceShift = true
    private var tapVk = 0                  // клавиша, чей «тап» отслеживается
    private var tapTarget = 0              // 0 = РУС, 1 = ENG
    private var tapDownAt: TimeInterval = 0
    private var tapAlone = false

    // Option-тап «как в Caramba» (принудительный переворот слова): арм — на
    // голом нажатии Option, действие — на отпускании в пределах 0.7 с
    private var optTapVk = 0               // 0x3A/0x3D, пока тап вооружён; 0 = не арм
    private var optTapDownAt: TimeInterval = 0
    // «чистая пара» обоих Shift (вкл/выкл автопереключения): любой keyDown гасит
    private var shiftPairClean = false
    private var autoLocked = false
    private var lastInputAt: TimeInterval = 0
    private let sessionPause: TimeInterval = 3.0
    private var lastResendSpaceAt: TimeInterval = 0
    private var lastSpacePassTick: TimeInterval = 0 // когда последний пробел ушёл в текст (для дедупа двойных)

    // держалка main-таймера свежести кэша раскладок (TIS — только на main)
    private var layoutRefreshTimer: Timer?

    // точка отката последней автозамены
    private var undoPending = false
    private var undoText = ""
    private var undoLen = 0
    private var undoSepText = ""
    private var undoLayout: LayoutService.LayoutData?
    private var undoApp: pid_t = 0
    private var undoAt: TimeInterval = 0
    private var keysSinceUndoPoint = 0
    private var undoTail: [KeyRec] = []
    private var undoTailBroken = false
    private var lastConvertInfo = "-"

    // ожидаемая раскладка (ложный лок автодетекта после ручной смены)
    private var expectedLayoutID: String?
    private var expectedApp: pid_t = 0
    private var expectGraceUntil: TimeInterval = 0

    // компенсация лага смены раскладки после тапа Shift
    private var gapActive = false
    private var gapLayout: LayoutService.LayoutData?
    private var gapBuf: [KeyRec] = []
    private var gapDeadline: TimeInterval = 0

    // обучение
    private var rejected = Set<String>()
    private var accepted = Set<String>()
    private let rejectedCap = 1000
    private let learnedLock = NSLock()

    // состояние переднего приложения
    private var fgApp: pid_t = 0
    private var fgProc = ""
    private var fgIsOwnApp = false
    private var procCache: [pid_t: String] = [:]

    // собственное окно настроек: автоисправление только в «песочнице»
    public var uiSettingsActive = false
    public var sandboxFocused = false

    // онбординг разрешений: авто-показ окна не чаще раза за запуск
    private var onboardingAutoShown = false
    private var readyInfoFired = false

    // --------------------------------------------------------- онбординг-окно

    /// Хук показа онбординг-окна: Core не зависит от UI, поэтому main.swift
    /// присваивает сюда вызов OnboardingWindowController.show (App.showOnboarding).
    public static var showOnboardingHook: (() -> Void)?

    /// Показ онбординга из любого потока: окно поднимается на main.
    static func showOnboarding() {
        DispatchQueue.main.async { showOnboardingHook?() }
    }

    public var onConverted: ((String, String) -> Void)?
    public var onInfo: ((String) -> Void)?
    public var onSettingsApplied: (() -> Void)?

    static let ms: () -> TimeInterval = { CACurrentMediaTime() }

    public init(_ settings: Settings) {
        s = settings
        rebuildExclusionList()
        // прогрев словарей ДО создания тапа: ленивое построение корпусов
        // (35k+20k слов, биграммы) занимает ~0.4-1 с — на потоке тапа это был бы
        // системный фриз клавиатуры на первом слове (замерено в раунде 5)
        _ = WordDict.ruBig
        _ = WordDict.enBig
        LanguageTables.ensureBigSets()
        _ = LanguageTables.possibleWord("тест", 0)
        _ = LanguageTables.possibleWord("test", 1)
        loadLearned()
        // TIS-кэш раскладок: прогрев ДО создания тапа (Engine.init — main) и
        // повторяющееся обновление на main каждые 0.25 с. Все TIS-вызовы
        // (TISCopyCurrentKeyboardInputSource/TISCreateInputSourceList/TISSelect)
        // на macOS 15 ассертят main-очередь — поток тапа читает только кэши.
        startLayoutRefreshTimer()
        // офскрин-рендерам UI тап не нужен (и алерт зависнет без рантайма)
        if ProcessInfo.processInfo.environment["OS_DISABLE_TAP"] != "1" {
            startTap()
        }
        watchForeground()
    }

    deinit {
        layoutRefreshTimer?.invalidate()
        stopTap()
    }

    /// main only: раз в 0.25 с обновляет кэш раскладок (TISCopyCurrentKeyboardInputSource
    /// + сравнение id; полная перестройка списка — по TTL 30 с). Дёшево: микросекунды.
    private func startLayoutRefreshTimer() {
        layoutRefreshTimer?.invalidate()
        LayoutService.refreshOnMain() // прогрев: кэш жив до первого тика
        let t = Timer(timeInterval: 0.25, repeats: true) { _ in LayoutService.refreshOnMain() }
        RunLoop.main.add(t, forMode: .common)
        layoutRefreshTimer = t
    }

    public func apply(_ settings: Settings) {
        s = settings
        rebuildExclusionList()
        onSettingsApplied?()
    }

    // ------------------------------------------------------------------ хук

    private func createTapPort() -> CFMachPort? {
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
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
            onboardingAutoShown = true // окно уже показано — watchdog его не дублирует
            // создание .defaultTap-тапа само требует «Универсальный доступ»:
            // онбординг-окно покажет нужный блок и живую проверку
            Self.showOnboarding()
            // watchdog на потоке тапа позже сам повторит createTapPort()
            ensureTapThread()
            return
        }
        tap = port
        ensureTapThread(initialPort: port)
        // тап создан сразу (разрешение с прошлого запуска): единоразово проверить
        // «Универсальный доступ» / подтвердить «Работаю!» — после подъёма UI
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.onboardingCheckOnMain() }
    }

    /// Поток с runloop тапа создаётся ОДИН раз; watchdog на нём же чинит/создаёт тап.
    private func ensureTapThread(initialPort: CFMachPort? = nil) {
        guard tapThread == nil else { return }
        let port = initialPort
        let thread = Thread { [weak self] in
            let rlCF = RunLoop.current.getCFRunLoop()
            self?.tapRunLoop = rlCF // до run(): публичные переключения встают в очередь этого runloop
            if let port = port ?? self?.tap {
                CFRunLoopAddSource(rlCF, CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0), .commonModes)
            }
            // Телеметрия прав раз в минуту: точное состояние по мнению системы
            var permTick = 0
            CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, 0, 60, 0, 0) { _ in
                let post = CGPreflightPostEventAccess()
                let listen = CGPreflightListenEventAccess()
                let ax = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary)
                let tapAlive = self?.tap != nil
                self?.logLine(String(format: "perms: post=%d listen=%d ax=%d tapAlive=%d", post ? 1 : 0, listen ? 1 : 0, ax ? 1 : 0, tapAlive ? 1 : 0))
                _ = permTick
            }.map { CFRunLoopAddTimer(rlCF, $0, .commonModes) }

            CFRunLoopAddTimer(rlCF, CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, 0, 10, 0, 0) { [weak self] _ in
                // watchdog: macOS молча отключает тап при таймауте колбэка;
                // если тап вовсе не создан (разрешение выдали позже) — пробуем снова
                guard let self = self else { return }
                if let t = self.tap {
                    if !CGEvent.tapIsEnabled(tap: t) {
                        CGEvent.tapEnable(tap: t, enable: true)
                        self.resetTapState()
                        self.logLine("tap REVIVED after death")
                    } else if self.wdTicks % 10 == 9 {
                        self.logLine("watchdog: heartbeat ok") // раз в 100 с, не спамим
                    }
                    self.wdTicks += 1
                    // тап жив: если «Универсальный доступ» подтянулся (или его нет
                    // с самого запуска) — один раз подсказка либо «Работаю!»
                    self.onboardingCheckAsync()
                } else if let port = self.createTapPort() {
                    self.tap = port
                    CFRunLoopAddSource(CFRunLoopGetCurrent(),
                                       CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0), .commonModes)
                    self.resetTapState()
                    self.logLine("tap CREATED after permission grant")
                    self.onboardingCheckAsync() // «Работаю!» или подсказка про «Универсальный доступ»
                }
            }, .commonModes)
            RunLoop.current.run()
        }
        thread.name = "OpenSwitcherTap"
        thread.start()
        tapThread = thread
    }

    private func stopTap() {
        if let t = tap { CFMachPortInvalidate(t) }
        tap = nil
    }

    /// Счётчик смен раскладки: отменяет устаревшие verifySwitch-ретраи
    /// (иначе отложенный ретрай откатывает более свежий выбор юзера).
    private var switchSerial = 0

    /// Отображаемое имя переднего приложения (для «добавить текущее» в исключениях).
    public var currentAppName: String { fgProc }

    /// Счётчики самообучения (для строки в настройках).
    public var learnedCounts: (rejected: Int, accepted: Int) {
        learnedLock.lock()
        defer { learnedLock.unlock() }
        return (rejected.count, accepted.count)
    }

    /// Открыть файл в текстовом редакторе по умолчанию.
    public static func openInEditor(_ path: String) {
        let exists = FileManager.default.fileExists(atPath: path)
        if !exists { FileManager.default.createFile(atPath: path, contents: nil) }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Внешняя смена раскладки (системное меню) — ретраи больше не актуальны.
    public func bumpSwitchSerial() {
        switchSerial += 1
    }

    /// TISSelectInputSource допустим только на main (macOS 15 ассертит очередь —
    /// краш в TSMGetInputSourceProperty с потока тапа): из тап-контекста уводим
    /// на main. Порядок инжекции не зависит от TISSelect — юникод-инжекция идёт
    /// сразу, сама смена раскладки применяется асинхронно (verifySwitch/gap это
    /// уже покрывают).
    private func switchLayoutOnMain(_ data: LayoutService.LayoutData) {
        DispatchQueue.main.async { LayoutService.switchTo(data) }
    }

    /// Проверка применения раскладки через 400 мс; TISSelectInputSource асинхронен —
    /// при лаге/игноре повторяем одиночно (fallback, v3 §10/§16). Ретрай жив только
    /// пока не произошло более новой смены (нашей или внешней). Main only.
    private func verifySwitch(target: LayoutService.LayoutData) {
        let serial = switchSerial
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self, self.switchSerial == serial else { return }
            if LayoutService.currentLayout()?.id == target.id { return }
            self.logLine("switch lag/ignored -> TISSelect retry")
            _ = LayoutService.switchTo(target)
        }
    }

    /// Сброс parity-состояния модификаторов/тапа (после потери событий).
    private func resetTapState() {
        pressedMods.removeAll()
        tapVk = 0
        tapAlone = false
        optTapVk = 0
        shiftPairClean = false
    }

    // ------------------------------------------------------- онбординг разрешений

    /// Единый статус обоих разрешений (меню → «Разрешения и диагностика»):
    /// tap — событийный тап создан; accessibility — AX trusted.
    public func permissionsState() -> (tap: Bool, accessibility: Bool) {
        (tap != nil, accessibilityTrusted(prompt: false))
    }

    /// Онбординг из фоновых мест (watchdog на потоке тапа, startTap):
    /// сама проверка дешёвая, но показ окна — только с main.
    private func onboardingCheckAsync() {
        DispatchQueue.main.async { [weak self] in self?.onboardingCheckOnMain() }
    }

    /// Только main: онбординг-окно вместо старых алертов — авто-показ не чаще
    /// раза за запуск (закрытое юзером окно не достаём; из меню онбординг
    /// открывается всегда). Состояния тапа и AX вычисляются НЕЗАВИСИМО: ранний
    /// return при отсутствии тапа (старая логика) навсегда прятал AX-подсказку —
    /// создание .defaultTap-тапа само требует «Универсальный доступ», и юзер
    /// застревал с одним сообщением про «Мониторинг ввода». Само окно покажет
    /// нужный блок: у него живая проверка раз в секунду.
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

    /// Попап «Работаю!» при закрытии онбординг-окна (одноразово: тот же
    /// readyInfoFired-гвард, что и у фоновой проверки, — двойного попапа нет).
    public func fireReadyInfoFromOnboarding() {
        guard !readyInfoFired else { return }
        readyInfoFired = true
        fireInfo("Работаю! Напечатайте ghbdtn и пробел")
    }

    /// Offscreen-рендеры и selftest (OS_DISABLE_TAP=1) — без онбординга, рендер не висит.
    private var onboardingAllowed: Bool {
        ProcessInfo.processInfo.environment["OS_DISABLE_TAP"] != "1"
    }

    private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            // события могли быть потеряны пока тап был мёртв — parity flagsChanged
            // инвертирован: сбрасываем, иначе отпускание читается как нажатие и
            // следующий Shift даст ложный тап
            resetTapState()
            return Unmanaged.passUnretained(event)
        }
        // собственная инжекция — пропускаем молча
        if event.getIntegerValueField(TextConverter.userField) == TextConverter.selfMagic {
            return Unmanaged.passUnretained(event)
        }
        if consumeSessionReset() { resetSession() }

        // ДИАГНОСТИКА (временно): полное эхо входящих клавиатурных событий
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
            if !onKeyDown(event) { return nil } // проглотить
        case .keyUp:
            if !onKeyUp(event) { return nil }
        case .flagsChanged:
            if !onFlagsChanged(event) { return nil }
        case .leftMouseDown, .rightMouseDown:
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

    // ------------------------------------------------------------------ переднее окно

    private var fgObserver: NSObjectProtocol?
    private var winObserver: NSObjectProtocol?

    private func watchForeground() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // блок-based наблюдатель: Engine — не NSObject, селекторный API рискован
            self.fgObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.foregroundChanged()
            }
            // смена ОКНА внутри одного приложения (Cmd+`) — тоже новая сессия ввода;
            // key-окно меняется только у активного приложения
            self.winObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.foregroundChanged(alwaysReset: true)
            }
            self.syncForegroundFromWorkspace()
        }
    }

    /// Флаг «сеанс надо сбросить»: main только ставит его, сам сброс выполняет
    /// ПОТОК ТАПА в начале следующего события — иначе гонки на lastWord/gapBuf/undo.
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

    /// Выполняется на потоке тапа: полный сброс сеанса ввода (аналог WinEventProcHandler).
    private func resetSession() {
        if buf.count > 0 { lastWord = buf.snapshot() }
        lastWordSepKey = 0
        lastWordApp = 0
        buf.clear()
        anyKeySinceShift = true
        tapAlone = false
        undoPending = false
        undoTailBroken = true
        gapActive = false; gapBuf.removeAll()
        autoLocked = false
        expectedLayoutID = nil // как _expectedValid=false в C#
        lastResendSpaceAt = 0  // окно эха не переносится в другое окно
    }

    /// Вызывается на main: обновляет fgApp/fgProc/fgIsOwnApp и запрашивает
    /// сброс сеанса при смене приложения/окна (аналог WinEventProcHandler).
    private func foregroundChanged(alwaysReset: Bool = false) {
        let prevApp = fgApp
        syncForegroundFromWorkspace()
        guard alwaysReset || (fgApp != 0 && prevApp != 0 && prevApp != fgApp) else { return }
        requestSessionReset()
    }

    /// Только main-поток: NSWorkspace не потокобезопасен, из тапа не вызывать.
    private func syncForegroundFromWorkspace() {
        let front = NSWorkspace.shared.frontmostApplication
        fgApp = front?.processIdentifier ?? 0
        let bundle = front?.bundleIdentifier ?? ""
        fgIsOwnApp = bundle == "com.openswitcher.app" || bundle.hasPrefix("com.openswitcher")
        if fgProc.isEmpty || procCache[fgApp] == nil {
            var name = (front?.localizedName ?? bundle).lowercased()
            if name.hasSuffix(".app") { name.removeLast(4) }
            fgProc = name
            if procCache.count > 200 { procCache.removeAll() } // защита от месячного роста
            if !name.isEmpty { procCache[fgApp] = name }
        } else {
            fgProc = procCache[fgApp] ?? ""
        }
    }

    /// Вызывается из тапа на каждое нажатие: ТОЛЬКО проверка лока раскладки.
    /// currentLayout() читается ОДИН раз (кэшируется в LayoutService с TTL 0.1 c).
    private func updateForeground() {
        guard let cur = LayoutService.currentLayout() else { return }
        // раскладка сменилась вне движка — юзер задал язык явно: лок автодетекта
        if let expected = expectedLayoutID, fgApp == expectedApp, cur.id != expected,
           s.lockAutoAfterManualSwitch, Engine.ms() >= expectGraceUntil {
            autoLocked = true
        }
        expectedLayoutID = cur.id
        expectedApp = fgApp
        TextConverter.targetPid = fgApp
    }

    private func expectLayout(_ data: LayoutService.LayoutData) {
        expectedLayoutID = data.id
        expectedApp = fgApp
        expectGraceUntil = Engine.ms() + 1.2
        switchSerial += 1 // отменяет висящие verifySwitch-ретраи
    }

    private var exclusionList: [String] = []

    private func rebuildExclusionList() {
        exclusionList = s.exclusions.lowercased()
            .split(whereSeparator: { ",;".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func isExcludedHere() -> Bool {
        // собственное окно настроек: исключаем всё, кроме «песочницы»
        if fgIsOwnApp {
            return !(uiSettingsActive && sandboxFocused)
        }
        if exclusionList.isEmpty || fgProc.isEmpty { return false }
        return exclusionList.contains(fgProc)
    }

    // ------------------------------------------------------------------ обработка клавиш

    /// Физическое состояние модификаторных клавиш. flagsChanged приходит и на
    /// нажатие, и на отпускание; бит maskShift общий для обоих Shift, а у Caps
    /// бит-состояние вообще не меняется на отпускании — различаем только чётностью.
    private var pressedMods: Set<Int> = []

    private func onFlagsChanged(_ event: CGEvent) -> Bool {
        let flags = currentFlags(event)
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let now = Engine.ms()
        let m = heldModsFromFlags(flags)
        if s.devLog, KeyCodeMap.isModifier(code) {
            logLine(String(format: "flags: code=0x%02X press=%d tapVk=%d alone=%d", code, pressedMods.contains(code) ? 0 : 1, tapVk, tapAlone ? 1 : 0))
        }

        // press/release по чётности: событие на уже «нажатой» клавише — её отпускание
        let wasPressed = pressedMods.contains(code)
        if wasPressed { pressedMods.remove(code) } else { pressedMods.insert(code) }
        let isPress = !wasPressed

        // ЛЮБОЙ другой модификатор-down гасит Option-тап (тап — только голый
        // Option: Shift/Ctrl/Cmd-чорды не страдают); само нажатие Option армит
        // ниже в своей ветке
        if isPress && code != 0x3A && code != 0x3D { optTapVk = 0 }

        let isShiftKey = code == KeyCodeMap.leftShift || code == KeyCodeMap.rightShift
        // Shift — тап-клавиша раскладки? (тогда двойной Shift отключён)
        let shiftIsTapKey = (s.hotRuMods == 0 && (s.hotRuVk == KeyCodeMap.leftShift || s.hotRuVk == KeyCodeMap.rightShift))
            || (s.hotEnMods == 0 && (s.hotEnVk == KeyCodeMap.leftShift || s.hotEnVk == KeyCodeMap.rightShift))
        let isCapsTapKey = code == KeyCodeMap.capsLock
            && ((s.hotRuMods == 0 && s.hotRuVk == code) || (s.hotEnMods == 0 && s.hotEnVk == code))

        if isShiftKey && isPress {
            let otherShift = code == KeyCodeMap.leftShift ? KeyCodeMap.rightShift : KeyCodeMap.leftShift
            // Оба Shift одновременно (как в Caramba) — вкл/выкл автопереключения:
            // чистая пара (ни одной клавиши между двумя Shift-down) гасит оба
            // Shift-тапа и дёргает глобальный тумблер паузы
            if s.shiftShiftToggle && pressedMods.contains(otherShift) && shiftPairClean {
                shiftPairClean = false
                lastShiftDown = 0
                anyKeySinceShift = true
                tapVk = 0
                tapAlone = false
                logLine("both-shifts: toggle auto")
                toggleAuto()
                return true // оба бита и так выставлены — флаги не глотаем
            }
            // двойной Shift — сменить раскладку; ОТКЛЮЧЁН, пока тап-переключение
            // висит на Shift'ах (v3 §10/§17.14: иначе второй тап «съедается»)
            if !anyKeySinceShift && (now - lastShiftDown) >= 0 && (now - lastShiftDown) < 0.4
                && s.doubleShiftSwitch && !shiftIsTapKey {
                lastShiftDown = 0
                anyKeySinceShift = true
                tapAlone = false
                switchToOtherLayout()
                return true // flagsChanged не глотаем — бит и так выставлен
            }
            lastShiftDown = now
            anyKeySinceShift = false
            if (s.hotRuMods == 0 && s.hotRuVk == code) || (s.hotEnMods == 0 && s.hotEnVk == code) {
                tapVk = code
                tapTarget = s.hotRuVk == code ? 0 : 1
                tapDownAt = now
                tapAlone = true
            }
            shiftPairClean = true // первый Shift чист: ждём второй (keyDown отменит)
            return true
        }
        if isShiftKey && !isPress {
            // отпускание Shift — завершение тапа (смена бита глотать бессмысленно)
            if s.devLog {
                logLine(String(format: "shift-up: code=0x%02X tapVk=%d alone=%d dt=%.3f", code, tapVk, tapAlone ? 1 : 0, now - tapDownAt))
            }
            _ = fireTapIfArmed(code: code, now: now, flags: flags)
            return true
        }

        if isCapsTapKey {
            if m.ctrl || m.alt || m.cmd { return true } // чужое сочетание — как есть
            if isPress {
                // арминг как в оригинале; нативное включение капса глотаем
                tapVk = code
                tapTarget = (s.hotRuMods == 0 && s.hotRuVk == code) ? 0 : 1
                tapDownAt = now
                tapAlone = true
                return false
            }
            // отпускание — завершение тапа; тоже глотаем
            _ = fireTapIfArmed(code: code, now: now, flags: flags)
            return false
        }

        // ---- Option-тап «как в Caramba»: короткий голый тап Option — принудительный
        // переворот слова. Гасится любым keyDown (onKeyDown), другим модификатором
        // (выше) и кликом мыши — реальные Option+клавиша / Cmd+Option+… не страдают.
        if code == 0x3A || code == 0x3D { // левый/правый Option
            if isPress {
                anyKeySinceShift = true
                if code != tapVk { tapAlone = false }
                buf.clear() // Option — не набор (паритет с прочими модификаторами)
                // армим только голый Option: зажатые Ctrl/Cmd/Shift — чужое сочетание
                let mOpt = heldModsFromFlags(flags)
                if s.optionFlip && !mOpt.ctrl && !mOpt.cmd && !flags.contains(.maskShift) {
                    optTapVk = code
                    optTapDownAt = now
                } else {
                    optTapVk = 0
                }
            } else {
                fireOptionTapIfArmed(code: code, now: now, flags: flags)
            }
            return true
        }

        if isPress {
            // прочие модификаторы — чужие для тапа: сброс «одиночности»
            anyKeySinceShift = true
            if code != tapVk { tapAlone = false }
            if code == 0x3B || code == 0x3E || code == 0x3A || code == 0x3D || code == 0x37 || code == 0x36 {
                buf.clear() // Ctrl/Alt/Cmd — не набор
            }
        }
        return true
    }

    /// Завершение тапа клавиши раскладки. true — пропустить событие.
    private func fireTapIfArmed(code: Int, now: TimeInterval, flags: CGEventFlags) -> Bool {
        guard tapVk != 0, code == tapVk else { return true }
        tapVk = 0
        // в оригинале KEYUP в suppress-окне не диспетчеризуется — тап не срабатывает
        if now < suppressUntil { return true }
        let m = heldModsFromFlags(flags)
        let alone = tapAlone && !m.ctrl && !m.alt && !m.cmd
            && (now - tapDownAt) >= 0 && (now - tapDownAt) < 0.7
        if !alone, s.devLog {
            logLine(String(format: "tap not fired: tapAlone=%d ctrl=%d alt=%d cmd=%d dt=%.3f suppress=%d", tapAlone ? 1 : 0, m.ctrl ? 1 : 0, m.alt ? 1 : 0, m.cmd ? 1 : 0, now - tapDownAt, now < suppressUntil ? 1 : 0))
        }
        if alone {
            logLine("tap fired: lang=\(tapTarget)")
            updateForeground()
            switchToLanguage(tapTarget)
        }
        return true
    }

    /// Отпускание Option — завершение Option-тапа «как в Caramba».
    private func fireOptionTapIfArmed(code: Int, now: TimeInterval, flags: CGEventFlags) {
        guard optTapVk != 0, code == optTapVk else { return }
        optTapVk = 0
        // в suppress-окне не диспетчеризуем — как Shift-тап (инжекция в полёте)
        if now < suppressUntil { return }
        let m = heldModsFromFlags(flags)
        // только голый: любой модификатор, ещё зажатый на отпускании, — чужое сочетание
        guard !m.ctrl && !m.alt && !m.cmd && !flags.contains(.maskShift) else { return }
        guard (now - optTapDownAt) >= 0 && (now - optTapDownAt) < 0.7 else { return }
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

    /// Возвращает true — пропустить клавишу дальше, false — проглотить.
    private func onKeyDown(_ event: CGEvent) -> Bool {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))

        // ЛЮБАЯ клавиша между нажатием и отпусканием гасит «чистые» жесты:
        // Option-тап и пару обоих Shift
        optTapVk = 0
        shiftPairClean = false

        // F8 (kVK_F8 = 0x64) — метка проблемы в журнале (спека v3 §15): юзер жмёт
        // при глюке, в лог падает снимок состояния. Не глотается — F8 продолжает работать.
        if code == 0x64 {
            markCount += 1
            updateForeground()
            // журнал выключен — вместо снимка подсказка юзеру (как в C#:
            // FireInfo «Журнал отключён…» + выход без записи); F8 не глотается
            if !s.devLog {
                fireInfo("Журнал отключён — включите «Режим разработчика»")
                return true
            }
            // рендер снимка (UCKeyTranslate) — только при включённом журнале
            let mBuf = buf.count > 0 ? (LayoutService.currentLayout().map { LayoutService.render($0, buf.snapshot()) } ?? "") : ""
            let mLast = lastWord.isEmpty ? "" : (LayoutService.currentLayout().map { LayoutService.render($0, lastWord) } ?? "")
            logLine("================ USER MARK #\(markCount) ================")
            logLine("mark: proc=\(fgProc) buf='\(mBuf)' lastWord='\(mLast)' (\(String(format: "%.1f", Engine.ms() - lastWordAt))s ago)" +
                " undo=\(undoPending ? "pending ('\(undoText)')" : "no") locked=\(autoLocked ? 1 : 0)" +
                " suppress=\(Engine.ms() < suppressUntil ? "yes" : "no")" +
                " lastConvert=\(lastConvertInfo)")
            fireInfo("Метка #\(markCount) записана в лог") // паритет C# Engine.cs:384
        }
        let flags = currentFlags(event)
        let shift = flags.contains(.maskShift)
        let caps = flags.contains(.maskAlphaShift)
        let m = heldMods(event)
        let now = Engine.ms()

        anyKeySinceShift = true
        // ЛЮБАЯ клавиша между нажатием и отпусканием тап-клавиши отменяет тап —
        // иначе Shift→буква→отпускание switching раскладку на каждой заглавной
        tapAlone = false

        // пауза автоперевода — глобальный тумблер
        if s.hotAutoToggleVk != 0 && matchHot(codeEvent: code, event, vkHot: s.hotAutoToggleVk, modsHot: s.hotAutoToggleMods) {
            toggleAuto()
            return false
        }

        // эхо-пробел: ДО счётчиков и suppress-гейта — точный порядок C# KeyboardProc
        // (проглоченное эхо не должно трогать keysSinceUndoPoint/lastInputAt)
        if code == KeyCodeMap.space {
            if lastResendSpaceAt != 0 && buf.count == 0 && (now - lastResendSpaceAt) < 0.6 {
                logLine("space-echo swallowed")
                lastResendSpaceAt = 0 // одноразово: следующий реальный пробел не глотаем (v3 §6.1)
                return false
            }
            lastResendSpaceAt = 0
        } else {
            lastResendSpaceAt = 0
        }

        // ---- guard отката: любые реальные нажатия, кроме исключений
        if !KeyCodeMap.isModifier(code) && !isUndoHotkey(code, event) && !isFixWordHotkey(code, event)
            && !(undoPending && code == KeyCodeMap.backspace) {
            keysSinceUndoPoint += 1
        }

        // лок живёт только внутри сеанса набора
        if !KeyCodeMap.isModifier(code) {
            if autoLocked && (now - lastInputAt) >= sessionPause {
                autoLocked = false
            }
            lastInputAt = now
        }

        if now < suppressUntil {
            // suppress-окно: конвертация запрещена, но буфер синхронизируем
            if KeyCodeMap.isLetterKey(code) {
                buf.push(KeyRec(code, shift, caps))
                if undoPending && !undoTailBroken {
                    if undoTail.count < 16 { undoTail.append(KeyRec(code, shift, caps)) }
                    else { undoTailBroken = true }
                }
            } else if code == KeyCodeMap.space {
                // граница слова обязана делить буфер, иначе слова слипаются
                // ('чтосправками') и конвертация теряется (v3 §6.4)
                if buf.count > 0 {
                    lastWord = buf.snapshot()
                    lastWordAt = now
                    lastWordSepKey = 0
                    lastWordApp = 0
                }
                buf.clear()
            }
            // Enter проходит насквозь и буфер НЕ делит (известное расхождение)
            return true
        }
        updateForeground() // как в C#: UpdateForeground внутри OnKeyDown, вне suppress

        // ---- ручные действия: работают всегда

        // Backspace сразу после автозамены — отмена как в Caramba
        if code == KeyCodeMap.backspace && undoPending && keysSinceUndoPoint == 0
            && !m.ctrl && !m.alt && !m.cmd && !s.paused {
            updateForeground()
            let age = now - undoAt
            if undoApp == fgApp && age >= 0 && age < 15 {
                undoPending = false
                logLine("backspace-cancel: \(undoText)")
                let bs2 = undoLen + undoSepText.count + undoTail.count
                let tailText = undoTail.isEmpty ? "" : (undoLayout.map { LayoutService.render($0, undoTail) } ?? "")
                let restore2 = undoText + undoSepText + tailText
                suppress(0.6)
                TextConverter.sendBackspaces(bs2)
                TextConverter.sendUnicode(restore2)
                if let ul = undoLayout {
                    switchLayoutOnMain(ul)
                    verifySwitch(target: ul)
                    expectLayout(ul)
                }
                if s.lockAutoAfterManualSwitch { autoLocked = true }
                let w = undoText.lowercased()
                rememberRejected(w) // персистентность как у hotkey-undo: слово в learned.txt переживёт рестарт
                removeAccepted(w)
                noFlipUntil = Engine.ms() + 5.0 // юзер правит сам — движок молчит 5 с (v3 §6.2)
                fireInfo("Отменено: \(restore2) · больше не исправлять")
                return false // глотаем Backspace
            }
        }

        // отмена последней автозамены
        if matchHot(codeEvent: code, event, vkHot: s.hotUndoVk, modsHot: s.hotUndoMods) {
            if undoPending {
                logLine("hotkey: undo")
                noFlipUntil = Engine.ms() + 5.0 // и при неудачном откате — тишина 5 с (C#:617)
                undoLastConversion()
            } else {
                logLine("hotkey: undo -> nothing pending, force flip")
                forceFlipLastWord()
            }
            return false
        }
        if matchHot(codeEvent: code, event, vkHot: s.hotFixWordVk, modsHot: s.hotFixWordMods) {
            logLine("hotkey: fix-last-word")
            doFixLastWord()
            return false
        }
        if matchHot(codeEvent: code, event, vkHot: s.hotFixSelVk, modsHot: s.hotFixSelMods) {
            logLine("hotkey: fix-selection")
            beginFixSelection(fromFixWord: false)
            return false
        }
        // Вставить без форматирования (как в Caramba): переназначаемый хоткей;
        // не задан (vk == 0) или PastePlain выключен — функция выкл
        if s.pastePlain && matchHot(codeEvent: code, event, vkHot: s.hotPasteVk, modsHot: s.hotPasteMods) {
            logLine("hotkey: paste-plain")
            pastePlainAction()
            return false
        }
        // сочетания-раскладки с модификаторами
        if s.hotRuMods != 0 && s.hotRuVk != 0 && matchHot(codeEvent: code, event, vkHot: s.hotRuVk, modsHot: s.hotRuMods) {
            switchToLanguage(0)
            return false
        }
        if s.hotEnMods != 0 && s.hotEnVk != 0 && matchHot(codeEvent: code, event, vkHot: s.hotEnVk, modsHot: s.hotEnMods) {
            switchToLanguage(1)
            return false
        }
        // тап-клавиши раскладок (не Shift): с зажатыми модификаторами пропускаем
        if (s.hotRuMods == 0 && s.hotRuVk != 0 && code == s.hotRuVk) ||
           (s.hotEnMods == 0 && s.hotEnVk != 0 && code == s.hotEnVk) {
            if m.ctrl || m.alt || m.cmd { return true }
            tapVk = code
            tapTarget = (s.hotRuMods == 0 && code == s.hotRuVk) ? 0 : 1
            tapDownAt = now
            tapAlone = true
            return false // глотаем нажатие, чтобы не делало своего
        }

        // ---- компенсация лага смены раскладки
        if gapActive {
            let curID = LayoutService.currentLayout()?.id
            if curID == gapLayout?.id || now >= gapDeadline {
                flushGap()
                gapActive = false
            } else {
                if KeyCodeMap.isLetterKey(code) {
                    gapBuf.append(KeyRec(code, shift, caps))
                    return false // доставим после применения раскладки
                }
                if code == KeyCodeMap.backspace {
                    if gapBuf.isEmpty { return true }
                    gapBuf.removeLast()
                    return false
                }
                flushGap()
                return true
            }
        }

        // ---- авто-логика; в исключённых приложениях глушим
        if isExcludedHere() { buf.clear(); return true }

        if KeyCodeMap.isLetterKey(code) {
            let rec = KeyRec(code, shift, caps)
            buf.push(rec)
            if undoPending && !undoTailBroken && !m.ctrl && !m.alt && !m.cmd {
                if undoTail.count < 16 { undoTail.append(rec) }
                else { undoTailBroken = true }
            }
            return true
        }

        if code == KeyCodeMap.backspace {
            if m.ctrl || m.alt || m.cmd {
                buf.clear()
                if undoPending { undoTailBroken = true }
                return true
            }
            buf.pop()
            if undoPending && !undoTailBroken {
                if !undoTail.isEmpty { undoTail.removeLast() }
                else { undoTailBroken = true }
            }
            return true
        }

        if code == KeyCodeMap.enter {
            let modified = m.ctrl || m.alt || m.cmd || shift
            var converted = false
            let word = buf.snapshot()
            if !word.isEmpty && !modified {
                lastWord = word
                lastWordAt = now
                lastWordApp = fgApp
                lastWordSepKey = 0 // после слова Enter — точный переворот с хвостом невозможен
            }
            // (сброс sep для пути без разделителя — в конце tryConvertWord)
            if !modified && s.fixOnEnter {
                converted = tryConvertWord(word, resendKey: KeyCodeMap.enter, resendShift: false, manual: false)
            }
            // одиночная буква по «словности» и на Enter ('f'+Enter -> «а»): иначе 'f'
            // в начале сообщения уходит в чат неперевёрнутым (v3 §7/§13)
            if !converted && !modified && !s.paused && word.count == 1,
               let curL = LayoutService.currentLayout() {
                let asTyped = LayoutService.render(curL, word)
                let typedLang = LanguageTables.langOf(asTyped)
                if asTyped.count == 1, typedLang >= 0,
                   !WordDict.hasSingleLetterWord(asTyped, typedLang),
                   let other = LayoutService.findLayoutByLang(1 - typedLang) {
                    let flipped = LayoutService.render(other, word)
                    if flipped.count == 1 && WordDict.hasSingleLetterWord(flipped, 1 - typedLang) {
                        converted = true
                        logLine("single-letter enter: '\(asTyped)' -> '\(flipped)'")
                        suppress(0.6)
                        TextConverter.targetPid = fgApp
                        TextConverter.sendBackspaces(1)
                        TextConverter.sendUnicode(flipped)
                        TextConverter.sendEnter() // Enter досылаем
                    }
                }
            }
            undoTailBroken = true
            buf.clear()
            return !converted
        }

        if code == KeyCodeMap.tab || code == KeyCodeMap.esc { buf.clear(); return true }

        if KeyCodeMap.isSeparatorKey(code) {
            let modified = m.ctrl || m.alt || m.cmd || shift
            var converted = false
            let bufWas = buf.count

            // дедуп двойных пробелов (настройка SpaceDedupMs): второй пробел подряд
            // при пустом буфере в пределах окна глотается — защита от рефлекса
            // двойного нажатия после конвертаций (порт C# Engine.cs:802-811)
            if code == KeyCodeMap.space && !modified && !s.paused && s.spaceDedupMs > 0 &&
                buf.count == 0 && lastSpacePassTick != 0 && (now - lastSpacePassTick) < Double(s.spaceDedupMs) {
                logLine("space: dedup swallowed")
                return false // проглотить (в текст не идёт)
            }

            // одиночная буква по «словности»: 'f' — не английское слово, «а» — русское
            // (союз) => 'f'->«а». Неприкасаемые (а/и/в/к/о/с/у/я, a/i) не переворачиваются.
            // Только по пробелу; хвостовой знак-двойник остаётся знаком («z,» -> «я,»).
            // Уважает кулдаун, лок, rejected и тумблер (v3 §7)
            if !modified && !s.paused && code == KeyCodeMap.space && s.autoConvertOnWordEnd &&
                !(s.lockAutoAfterManualSwitch && autoLocked) && now >= noFlipUntil &&
                (buf.count == 1 || (buf.count == 2 && KeyCodeMap.isPunctTwinKey(buf.snapshot()[1].code))) {
                let keys1 = buf.snapshot()
                let tailPunct = keys1.count == 2
                if let curL = LayoutService.currentLayout() {
                    let asTyped = LayoutService.render(curL, keys1)
                    let coreTyped = tailPunct ? String(asTyped.prefix(1)) : asTyped
                    let tailTxt = tailPunct ? String(asTyped.dropFirst()) : ""
                    let typedLang = LanguageTables.langOf(coreTyped)
                    if coreTyped.count == 1, tailTxt.count <= 1, typedLang >= 0,
                       !rejected.contains(coreTyped),
                       !WordDict.hasSingleLetterWord(coreTyped, typedLang),
                       let other = LayoutService.findLayoutByLang(1 - typedLang) {
                        let one = [keys1[0]]
                        let flipped = LayoutService.render(other, one)
                        if flipped.count == 1 && WordDict.hasSingleLetterWord(flipped, 1 - typedLang) {
                            let result = flipped + tailTxt
                            converted = true
                            logLine("single-letter: '\(asTyped)' -> '\(result)'")
                            suppress(0.6)
                            TextConverter.targetPid = fgApp
                            TextConverter.sendBackspaces(keys1.count)
                            TextConverter.sendUnicode(result)
                            // точка отката: Break вернёт набранное и разделитель
                            undoPending = true
                            undoText = asTyped
                            undoLen = result.count
                            undoSepText = TextConverter.renderKeyChar(keyCode: code, shift: shift)
                            undoLayout = LayoutService.getLayouts().first { $0.id == curL.id }
                            undoApp = fgApp
                            undoAt = Engine.ms()
                            keysSinceUndoPoint = 0
                            undoTail.removeAll()
                            undoTailBroken = false
                            TextConverter.sendUnicode(undoSepText) // досылаем разделитель как набрано
                            if undoSepText == " " { lastResendSpaceAt = Engine.ms() }
                            fireConverted(asTyped, result)
                        }
                    }
                }
            }

            if !converted && !modified && s.autoConvertOnWordEnd && buf.count > 0 {
                let word = buf.snapshot()
                converted = tryConvertWord(word, resendKey: code, resendShift: shift, manual: false)
            }
            if buf.count > 0 && !modified {
                lastWord = buf.snapshot()
                lastWordAt = now
                lastWordApp = fgApp
                lastWordSepKey = code // разделитель сразу после слова — нужен точному перевороту
            }
            if !modified && !converted && undoPending && !undoTailBroken && code != KeyCodeMap.tab {
                if undoTail.count < 16 { undoTail.append(KeyRec(code, shift, caps)) }
                else { undoTailBroken = true }
            }
            // трассировка пробелов: лишние/пропавшие пробелы ловятся здесь (v3 §15)
            if code == KeyCodeMap.space && !modified {
                if !converted { lastSpacePassTick = now } // считаем только юзерские пробелы: пересланные/конвертные — нет (C#:891)
                logLine("space: \(converted ? "flip+resend" : "pass") bufWas=\(bufWas) echoInWindow=\(lastResendSpaceAt != 0 && (now - lastResendSpaceAt) < 0.6 ? "y" : "n")")
            }
            buf.clear()
            return !converted
        }

        // F-клавиши, навигация, Ins/Del — сброс буфера (реальные macOS-коды)
        if KeyCodeMap.isNavigationKey(code) {
            buf.clear()
            if undoPending { undoTailBroken = true }
            return true
        }

        return true
    }

    private func onKeyUp(_ event: CGEvent) -> Bool {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        // тап-клавиши (не Shift) завершаются здесь
        if tapVk != 0 && code == tapVk && code != KeyCodeMap.leftShift && code != KeyCodeMap.rightShift {
            let _ = fireTapIfArmed(code: code, now: Engine.ms(), flags: event.flags)
            return false // keyUp проглоченной тап-клавиши тоже глотается (IsSwallowableTap)
        }
        return true
    }

    private func onMouseDown() {
        if buf.count > 0 { lastWord = buf.snapshot() }
        lastWordSepKey = 0
        lastWordApp = 0
        buf.clear()
        tapAlone = false
        optTapVk = 0          // Option+клик — реальное сочетание, не тап
        shiftPairClean = false // клик между Shift-down ломает «одновременность»
        keysSinceUndoPoint += 1
        if undoPending { undoTailBroken = true }
    }

    private func flushGap() {
        guard !gapBuf.isEmpty, let gl = gapLayout else { return }
        let str = LayoutService.render(gl, gapBuf)
        TextConverter.sendUnicode(str)
        logLine("gap: flushed \(gapBuf.count) keys as '\(str)'")
        gapBuf.removeAll()
    }

    // ------------------------------------------------------------------ действия

    /// Сериализация публичных действий на потоке тапа: меню/горячие пути зовут
    /// их с main, а тело мутирует gapBuf/gapActive/autoLocked, которые читает
    /// живой тап-поток. На потоке тапа — исполняем сразу; тапа нет (selftest)
    /// — исполняем как есть.
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

    public func switchToLanguage(_ lang: Int) {
        performOnTapThread { [weak self] in self?.switchToLanguageOnTap(lang) }
    }

    private func switchToLanguageOnTap(_ lang: Int) {
        updateForeground()
        guard let target = LayoutService.findLayoutByLang(lang) else {
            fireInfo(lang == 0 ? "Русская раскладка не найдена" : "Английская раскладка не найдена")
            return
        }
        switchLayoutOnMain(target)
        verifySwitch(target: target)
        expectLayout(target)
        if s.lockAutoAfterManualSwitch { autoLocked = true }
        gapActive = true; gapLayout = target; gapBuf.removeAll()
        gapDeadline = Engine.ms() + 0.8
        fireInfo(lang == 0 ? "РУС" : "ENG")
    }

    public func switchToOtherLayout() {
        performOnTapThread { [weak self] in self?.switchToOtherLayoutOnTap() }
    }

    private func switchToOtherLayoutOnTap() {
        updateForeground()
        let layouts = LayoutService.getLayouts()
        guard let curID = LayoutService.currentLayout()?.id,
              let other = layouts.first(where: { $0.id != curID }) else { return }
        let probe = [KeyRec(KeyCodeMap.ansiCode(ofLatin: "a"), false, false)]
        let name = LanguageTables.langOf(LayoutService.render(other, probe)) == 0 ? "РУС" : "ENG"
        switchLayoutOnMain(other)
        verifySwitch(target: other)
        expectLayout(other)
        if s.lockAutoAfterManualSwitch { autoLocked = true }
        gapActive = true; gapLayout = other; gapBuf.removeAll()
        gapDeadline = Engine.ms() + 0.8
        fireInfo("Раскладка: \(name)")
    }

    /// Попытка конвертации слова (порт TryConvertWord).
    private func tryConvertWord(_ word: [KeyRec], resendKey: Int, resendShift: Bool, manual: Bool) -> Bool {
        var why: String? = nil
        if s.paused { why = "paused" }
        else if word.count < 2 { why = "too-short (\(word.count))" }
        else if !manual && s.lockAutoAfterManualSwitch && autoLocked { why = "locked" }
        if let why = why { logLine("convert skip: \(why)"); return false }

        updateForeground()
        if isExcludedHere() { logLine("convert skip: excluded app"); return false }

        let layouts = LayoutService.getLayouts()
        if layouts.count < 2 { logLine("convert skip: one layout"); return false }
        let cands = LayoutService.renderAll(word, layouts)

        guard let curID = LayoutService.currentLayout()?.id,
              let cur = cands.first(where: { $0.layoutID == curID }) else {
            logLine("convert skip: cur unknown"); return false
        }
        if cur.lang < 0 { logLine("convert skip: cur unknown lang"); return false }

        let typedLow = cur.text.lowercased()
        learnedLock.lock()
        let isRejected = !manual && rejected.contains(typedLow)
        let acceptedWord = !manual && accepted.contains(typedLow)
        learnedLock.unlock()
        if isRejected {
            logLine("convert skip: learned-rejected '\(cur.text)'")
            return false
        }

        guard let best = cands.filter({ $0.layoutID != curID && $0.lang >= 0 }).max(by: { $0.score < $1.score }) else {
            logLine("convert skip: no candidate"); return false
        }

        // РУ->EN авто-переворот коротких (<5 букв) слов ОТКЛЮЧЁН: короткое
        // «русское» прочтение почти всегда правильный русский текст («ща», «фда»),
        // а его EN-прочтение ('of', 'alf') — мусор (порт C# Engine.cs:1138-1147).
        // EN->РУ (ядро программы) и ручной путь не трогаем.
        if !manual && !acceptedWord && cur.lang == 0 && best.lang == 1 && word.count < 5 {
            logLine("convert skip: ru->en short ('\(cur.text)' -> '\(best.text)')")
            return false
        }

        // Кулдаун после ручной правки — первым делом (v3 §6.2)
        if !manual && !acceptedWord && Engine.ms() < noFlipUntil {
            logLine("convert skip: cool-down after manual fix")
            return false
        }

        var bestText = best.text
        if !manual && !acceptedWord {
            // хвостовая клавиша-«двойник» (б/ю/ж/э в конце слова): пробуем трактовать её
            // как ЗНАК — «ghbdtn,» должно стать «привет,», а не «приветб». Если
            // прочтение со знаком валиднее (словарь/морфология) — целимся в него (v3 §5.10)
            if let lastKey = word.last, word.count > 1, KeyCodeMap.isPunctTwinKey(lastKey.code),
               bestText.count > 1, let pc = KeyCodeMap.punctCharOfKey(lastKey.code) {
                let alt = String(bestText.dropLast()) + String(pc)
                let altCore = LanguageTables.lettersOnly(alt)
                let baseCore = LanguageTables.lettersOnly(bestText)
                let altValid = WordDict.has(altCore, best.lang) ||
                    (altCore.count >= 3 && LanguageTables.possibleWord(altCore, best.lang))
                let baseValid = WordDict.has(baseCore, best.lang) ||
                    (baseCore.count >= 3 && LanguageTables.possibleWord(baseCore, best.lang))
                if altValid && !baseValid { bestText = alt }
            }
            // цель: [буквы][не более одного знака-хвоста] (v3 §5.11)
            let core = LanguageTables.lettersOnly(bestText)
            let tail = String(bestText.dropFirst(core.count))
            if core.isEmpty || tail.count > 1 {
                logLine("convert skip: target-not-letters ('\(bestText)')")
                return false
            }
            // цель: словарное слово ИЛИ «возможное» слово языка от 3 букв (v3 §5.11)
            if !WordDict.has(core, best.lang) &&
                (core.count < 3 || !LanguageTables.possibleWord(core, best.lang)) {
                logLine("convert skip: target-not-in-dict ('\(bestText)')")
                return false
            }
        }

        var pass = LanguageTables.shouldConvert(curText: cur.text, curLang: cur.lang, curScore: cur.score,
                                                bestText: bestText, bestLang: best.lang, bestScore: best.score,
                                                sensitivity: s.sensitivity)
        if !pass && acceptedWord && bestText == LanguageTables.lettersOnly(bestText) {
            pass = true // цель — только буквы (v3 §5.13)
        }

        if !pass && !acceptedWord && WordDict.has(LanguageTables.lettersOnly(bestText), best.lang) && !WordDict.has(cur.text, cur.lang) {
            pass = true
            logLine("convert: dict-over-score ('\(cur.text)' -> '\(bestText)')")
        }

        // цель не словарная (только «возможная» по биграммам): авто-переворот
        // требует ДВОЙНОГО запаса скора — иначе опечатка юзера конвертится
        // в ближайший мусор ('lfdfqw' -> «давайц» при пропущенной «те»).
        // Словарные цели — обычный порог, выученные — без порога
        // (порт C# 2fc5eaf «По бою 18:45»; прежний порт с single-margin
        // «both-not-in-dict» опечаточный мусор пропускал)
        if pass && !acceptedWord &&
            !WordDict.has(LanguageTables.lettersOnly(bestText), best.lang) {
            let need = 2 * LanguageTables.baseMargin / max(0.3, s.sensitivity)
            if best.score - cur.score < need {
                logLine("convert skip: non-dict margin ('\(cur.text)' -> '\(bestText)')")
                return false
            }
        }

        // последнее предохранительное: набранное — частое слово, цель — нет:
        // не трогаем (выученные пары не проверяем — юзер настоял) (C#:1213-1220)
        if pass && !acceptedWord && WordDict.has(cur.text, cur.lang) &&
            !WordDict.has(LanguageTables.lettersOnly(bestText), best.lang) {
            logLine("convert skip: cur-in-dict, target-not ('\(cur.text)' -> '\(bestText)')")
            return false
        }
        if !pass {
            logLine("convert skip: score ('\(cur.text)' -> '\(bestText)')")
            return false
        }

        lastWordSepKey = 0 // ручной/беспраздельный путь: точный force-flip разоружаем (C#:1236)
        logLine("convert OK: '\(cur.text)' -> '\(bestText)' (resend=\(resendKey))")
        lastConvertInfo = "'\(cur.text)' -> '\(bestText)'"
        lastWord = word

        suppress(0.6)
        TextConverter.sendBackspaces(word.count)
        TextConverter.sendUnicode(bestText)
        // разделитель рендерится по СТАРОЙ раскладке — до switchTo (renderKeyChar
        // читает живую currentLayout); та же строка идёт в точку отката
        let sepText = (resendKey != 0 && resendKey != KeyCodeMap.enter)
            ? TextConverter.renderKeyChar(keyCode: resendKey, shift: resendShift) : ""
        if resendKey != 0 {
            if resendKey == KeyCodeMap.enter { TextConverter.sendEnter() }
            else { TextConverter.sendUnicode(sepText) }
        }
        if resendKey == KeyCodeMap.space { lastResendSpaceAt = Engine.ms() }
        if let bl = layouts.first(where: { $0.id == best.layoutID }) {
            switchLayoutOnMain(bl)
            verifySwitch(target: bl)
            expectLayout(bl)
        }

        // паритет C# injOk (Engine.cs:1295): без «Универсального доступа» инжекция
        // (CGEventPostToPid) не применяется — откат не армим (Break стирал бы
        // РЕАЛЬНЫЕ символы юзера) и замена не заучивается
        let injOk = accessibilityTrusted(prompt: false)
        if !injOk { logLine("convert warn: accessibility off — undo/learning not armed") }
        undoPending = resendKey != KeyCodeMap.enter && injOk
        undoText = cur.text
        undoLen = bestText.count
        undoSepText = sepText
        undoLayout = layouts.first { $0.id == cur.layoutID }
        undoApp = fgApp
        undoAt = Engine.ms()
        keysSinceUndoPoint = 0
        undoTail.removeAll()
        undoTailBroken = false

        if injOk && cur.text.count >= 3 {
            // принятие честное: через 15 с, если юзер не откатил (v3 §12)
            let acceptedTyped = cur.text.lowercased()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self = self, !self.isRejected(acceptedTyped) else { return }
                self.rememberAccepted(acceptedTyped)
            }
        }

        fireConverted(cur.text, bestText) // попап показывает цель с хвостом-знаком
        return true
    }

    public func toggleAuto() {
        s.paused.toggle()
        if !s.paused { autoLocked = false }
        let paused = s.paused
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            SettingsStore.save(self.s)
            self.apply(self.s)
        }
        fireInfo(paused ? "Автоисправление выключено" : "Автоисправление включено")
    }

    /// Отмена последней автозамены (порт UndoLastConversion).
    public func undoLastConversion() {
        if !undoPending { logLine("undo skip: nothing pending"); fireInfo("Нечего отменять"); return }
        if undoTailBroken { logLine("undo skip: tail broken"); fireInfo("Слишком много набрано после"); return }
        updateForeground()
        if undoApp != fgApp { logLine("undo skip: other window"); fireInfo("Уже в другом окне"); return }
        let age = Engine.ms() - undoAt
        if age < 0 || age > 15 { logLine("undo skip: stale"); fireInfo("Слишком поздно"); return }

        let bs = undoLen + undoSepText.count + undoTail.count
        let tailText = undoTail.isEmpty ? "" : (undoLayout.map { LayoutService.render($0, undoTail) } ?? "")
        let restore = undoText + undoSepText + tailText
        suppress(0.6)
        TextConverter.sendBackspaces(bs)
        TextConverter.sendUnicode(restore)
        if let ul = undoLayout {
            switchLayoutOnMain(ul)
            verifySwitch(target: ul)
            expectLayout(ul)
        }
        if s.lockAutoAfterManualSwitch { autoLocked = true }
        let learned = undoText
        rememberRejected(learned)
        removeAccepted(learned)
        fireInfo("Отменено: \(restore) · больше не исправлять")
        undoPending = false
    }

    public func forgetAllWords() {
        learnedLock.lock()
        defer { learnedLock.unlock() }
        rejected.removeAll()
        accepted.removeAll()
        try? FileManager.default.createDirectory(atPath: SettingsStore.dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: SettingsStore.dir + "/learned.txt", contents: nil)
        FileManager.default.createFile(atPath: SettingsStore.dir + "/accepted.txt", contents: nil)
        fireInfo("Память слов очищена")
    }

    public func doFixLastWord() {
        updateForeground()
        if keysSinceUndoPoint == 0 && !lastWord.isEmpty {
            logLine("fix-last-word: exact path")
            let word = lastWord
            if !tryConvertWord(word, resendKey: 0, resendShift: false, manual: true) {
                fireInfo("Раскладка уже верная")
            }
            return
        }
        logLine("fix-last-word: select-left path (keysSince=\(keysSinceUndoPoint))")
        // выделяем слово слева от каретки (Option+Shift+Left) и конвертируем как выделение
        TextConverter.sendCombo(keyCode: 0x7B /* Left */, mods: HK.ALT | HK.SHIFT)
        beginFixSelection(fromFixWord: true)
    }

    /// Break при нечего-отменять: принудительный переворот (порт ForceFlipLastWord, v3 §9).
    public func forceFlipLastWord() {
        updateForeground()
        if buf.count >= 2 {
            logLine("force-flip: current buffer (\(buf.count) keys)")
            _ = forceConvertWord(buf.snapshot(), trailSepKey: 0)
            buf.clear() // флип живого буфера — буфер отработал
            return
        }
        // слово только что завершилось, известен разделитель после него, каретка
        // сразу за разделителем — точный переворот куском [слово+разд] (v3: ≤10 с, то же окно)
        if buf.count == 0 && !lastWord.isEmpty && lastWordSepKey != 0 &&
            lastWordApp == fgApp && (Engine.ms() - lastWordAt) < 10 {
            logLine("force-flip: exact path (last word, sep=0x\(String(lastWordSepKey, radix: 16)))")
            _ = forceConvertWord(lastWord, trailSepKey: lastWordSepKey)
            return
        }
        // честный отказ — паритет коду C# v3 (Engine.cs:1404-1406)
        logLine("force-flip skip: no fresh word at caret")
        fireInfo("Курсор не сразу после слова — выдели его и нажми Shift+Break")
    }

    /// Принудительный переворот слова. skipRejected — не блокировать переворот
    /// выученно-отменённых слов (Option-пинг-понг: юзер гоняет слово туда-сюда
    /// руками); skipLearn — не писать в самообучение (чистый ручной инструмент).
    private func forceConvertWord(_ word: [KeyRec], trailSepKey: Int,
                                  skipRejected: Bool = false, skipLearn: Bool = false) -> Bool {
        updateForeground()
        if isExcludedHere() { logLine("force-flip skip: excluded app"); return false }
        let layouts = LayoutService.getLayouts()
        if layouts.count < 2 { logLine("force-flip skip: one layout"); return false }
        let cands = LayoutService.renderAll(word, layouts)

        guard let curID = LayoutService.currentLayout()?.id,
              let cur = cands.first(where: { $0.layoutID == curID }), cur.lang >= 0 else {
            logLine("force-flip skip: cur unknown"); return false
        }
        // юзер уже отменял переворот этой буквы/слова (rejected) — не повторяем
        // его же ошибку (порт C# 2fc5eaf: 'lfdfqw'->«давайц» -> backspace ->
        // Break вернул тот же мусор -> пинг-понг переворотов)
        if !skipRejected && isRejected(cur.text.lowercased()) {
            logLine("force-flip skip: word in rejected ('\(cur.text)')")
            fireInfo("Этот переворот ты уже отменял")
            return false
        }
        guard let best = cands.filter({ $0.layoutID != curID && $0.lang >= 0 }).max(by: { $0.score < $1.score }),
              best.text != cur.text else {
            logLine("force-flip skip: no other reading"); return false
        }

        logLine("force-flip: '\(cur.text)' -> '\(best.text)'")
        lastConvertInfo = "force '\(cur.text)' -> '\(best.text)'"

        suppress(0.6)
        TextConverter.targetPid = fgApp
        // хвост-разделитель после слова уже в тексте приложения — стираем вместе
        // со словом и перепечатываем (иначе переворот съедает пробел/запятую) (v3 §9)
        let trailLen = trailSepKey != 0 ? 1 : 0
        TextConverter.sendBackspaces(word.count + trailLen)
        TextConverter.sendUnicode(best.text)
        if trailSepKey != 0 {
            TextConverter.sendUnicode(TextConverter.renderKeyChar(keyCode: trailSepKey, shift: false))
        }
        // раскладку переключаем только при перевороте СЛОВА: одиночная буква
        // ('А'->'F' в «F8») — правка одного символа, юзер продолжает в своём языке
        if word.count > 1, let bl = layouts.first(where: { $0.id == best.layoutID }) {
            switchLayoutOnMain(bl)
            verifySwitch(target: bl)
            expectLayout(bl)
        }

        undoPending = true
        undoText = cur.text
        undoLen = best.text.count
        undoSepText = ""
        undoLayout = layouts.first { $0.id == cur.layoutID }
        undoApp = fgApp
        undoAt = Engine.ms()
        keysSinceUndoPoint = 0
        undoTail.removeAll()
        undoTailBroken = false

        // одиночные буквы (нулевого сигнала), слова со знаками внутри и уже словарные
        // слова не заучиваем; 2-буквенные сленговые пары ('et'->'уе') — заучиваем (v3 §9);
        // Option-пинг-понг (skipLearn) самообучение не трогает вовсе
        if !skipLearn && cur.text.count >= 2 && cur.text == LanguageTables.lettersOnly(cur.text) &&
            !WordDict.has(cur.text, cur.lang) {
            let learned = cur.text.lowercased()
            rememberAccepted(learned)
            fireInfo("Заучено: \(cur.text) → \(best.text)")
        }
        return true
    }

    /// Option-тап (как в Caramba): принудительный «пинг-понг» переворотов.
    /// В отличие от Shift+Break НЕ блокируется rejected-защитой и НЕ пишет в
    /// самообучение (rejected/accepted) — чистый ручной инструмент. Точку
    /// отката ставим (Break работает), раскладка переключается (как force-flip).
    private func carambaFlip() {
        updateForeground()
        if buf.count >= 2 {
            logLine("caramba-flip: live buffer (\(buf.count) keys)")
            _ = forceConvertWord(buf.snapshot(), trailSepKey: 0, skipRejected: true, skipLearn: true)
            buf.clear() // флип живого буфера — буфер отработал
            return
        }
        // свежее последнее слово (≤10 с, разделитель известен, то же приложение) —
        // точный переворот куском [слово+разд]
        if buf.count == 0 && !lastWord.isEmpty && lastWordSepKey != 0 &&
            lastWordApp == fgApp && (Engine.ms() - lastWordAt) < 10 {
            logLine("caramba-flip: exact path (last word, sep=0x\(String(lastWordSepKey, radix: 16)))")
            _ = forceConvertWord(lastWord, trailSepKey: lastWordSepKey, skipRejected: true, skipLearn: true)
            return
        }
        // свежего слова нет (нет выделения юзера, слово >10 с или в другом
        // приложении) — ЧЕСТНЫЙ ОТКАЗ: иначе тап схватит кусок предложения
        // слева от каретки и «затрёт» его конвертацией (бой 2026-09-24 22:31)
        logLine("caramba-flip: no fresh word at caret -> refuse")
        fireInfo("Нет свежего слова у курсора — выдели текст и нажми Option ещё раз")
    }

    /// «Вставить без форматирования» (как в Caramba): содержимое буфера обмена
    /// заменяется чистым текстом и вставляется Cmd+V. На main: NSPasteboard
    /// не потокобезопасен. Собственная инжекция помечена магией и в тапе
    /// ре-перехватываться не будет.
    private func pastePlainAction() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
                self.logLine("paste-plain skip: no text in clipboard")
                self.fireInfo("В буфере обмена нет текста")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string) // только plain
            TextConverter.targetPid = self.fgApp
            self.suppress(0.3)
            TextConverter.sendCombo(keyCode: KeyCodeMap.ansiCode(ofLatin: "v"), mods: HK.CMD)
            self.logLine("paste-plain: sent Cmd+V (\(text.count) chars)")
        }
    }

    // ------------------------------------------------------------------ конвертация выделенного

    private var selTimer: Timer?
    private var selApp: pid_t = 0
    private var selTries = 0
    private var selPhase = 0
    private var selFromFixWord = false
    private var selRetried = false
    private var selBaseline: String?
    private var selBaseSeq = 0

    public func beginFixSelection(fromFixWord: Bool) {
        updateForeground()
        selApp = fgApp
        selFromFixWord = fromFixWord
        selRetried = false
        selBaseline = TextConverter.getClipboardTextOnce()
        selBaseSeq = TextConverter.clipboardChangeCount()
        selPhase = 0
        selTries = 0
        DispatchQueue.main.async { [weak self] in self?.restartSelTimer() }
        logLine("sel: started")
    }

    private func restartSelTimer() {
        selTimer?.invalidate()
        selTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            self?.selPollTick()
        }
    }

    private func selPollTick() {
        if selPhase == 0 {
            // ждём отпускания модификаторов хоткея
            let f = CGEventSource.flagsState(.hidSystemState)
            let held = f.contains(.maskShift) || f.contains(.maskControl) || f.contains(.maskAlternate) || f.contains(.maskCommand)
            selTries += 1
            if held && selTries < 10 { return }
            selPhase = 1
            selTries = 0
            TextConverter.targetPid = selApp // инжекция — в приложение выделения, не в переднее
            TextConverter.sendCombo(keyCode: KeyCodeMap.ansiCode(ofLatin: "c"), mods: HK.CMD)
            restartSelTimer()
            logLine("sel: cmd+c sent")
            return
        }

        let text = TextConverter.getClipboardTextOnce() ?? ""
        let seqChanged = TextConverter.clipboardChangeCount() != selBaseSeq
        selTries += 1
        let isNew = !text.isEmpty && (seqChanged || text != selBaseline)
        if !isNew && selTries < 20 { return } // ~1.2 с на Cmd+C
        selTimer?.invalidate()

        if text.isEmpty || !seqChanged {
            if selFromFixWord && !selRetried {
                selRetried = true
                selPhase = 0
                selTries = 0
                // ретрай: расширяем выделение до 2 слов влево
                TextConverter.targetPid = selApp
                TextConverter.sendCombo(keyCode: 0x7B, mods: HK.ALT | HK.SHIFT)
                TextConverter.sendCombo(keyCode: 0x7B, mods: HK.ALT | HK.SHIFT)
                restartSelTimer()
                logLine("sel: retry with 2 words left")
                return
            }
            logLine("sel: no new clipboard (text \(text.isEmpty ? "empty" : "present")\(seqChanged ? "" : ", seq unchanged"))")
            fireInfo("Не удалось скопировать выделение в этом приложении")
            return
        }
        logLine("sel: got \(text.count) chars")

        let lang = LanguageTables.langOf(LanguageTables.lettersOnly(text))
        if lang < 0 {
            logLine("sel: lang unknown")
            fireInfo("Не удалось определить язык")
            return
        }
        let converted = CharMaps.mapText(text, toRu: lang == 1)
        TextConverter.setClipboardText(converted)
        TextConverter.targetPid = selApp
        TextConverter.sendCombo(keyCode: KeyCodeMap.ansiCode(ofLatin: "v"), mods: HK.CMD)
        logLine("sel: pasted converted (lang=\(lang))")
        lastConvertInfo = "sel '\(text)' -> '\(converted)'"

        if selFromFixWord && text.count >= s.minWordLen && text.count <= 24
            && text == LanguageTables.lettersOnly(text) && !WordDict.has(text, lang) {
            rememberAccepted(text.lowercased())
        }

        if let target = LayoutService.findLayoutByLang(lang == 1 ? 0 : 1) {
            LayoutService.switchTo(target)
            verifySwitch(target: target)
            expectLayout(target)
        }
        if s.lockAutoAfterManualSwitch { autoLocked = true }

        if s.restoreClipboard { scheduleClipboardRestore(text) }

        if converted != text { fireConverted(text, converted) }
        else { fireInfo("Раскладка уже верная") }
    }

    private func scheduleClipboardRestore(_ original: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.suppress(0.3)
            TextConverter.setClipboardText(original)
        }
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

    private func removeAccepted(_ typed: String) {
        learnedLock.lock()
        let removed = accepted.remove(typed) != nil
        let snapshot = accepted
        learnedLock.unlock()
        guard removed else { return }
        // синхронная запись файла на потоке тапа (до 10 мс на тормозящем диске) недопустима
        DispatchQueue.global(qos: .utility).async {
            let _ = try? snapshot.joined(separator: "\n").appending("\n").write(toFile: self.acceptedPath, atomically: true, encoding: .utf8)
        }
    }

    private func appendFile(_ path: String, _ line: String) {
        DispatchQueue.global(qos: .utility).async {
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

    private func suppress(_ sec: TimeInterval) {
        let until = Engine.ms() + sec
        if until > suppressUntil { suppressUntil = until }
    }

    /// Точка экрана для всплывашки: на macOS каретку чужого окна не спросить —
    /// показываем у курсора (мышь почти всегда у поля ввода).
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

    // журнал решений
    private let logQueue = DispatchQueue(label: "os.log", qos: .utility)
    private var logBuf: [String] = []
    private let logLock = NSLock()

    private static let logDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    func logLine(_ line: String) {
        // журнал ведётся только в режиме разработчика (настройка DevLog):
        // для открытой версии — никаких записей о нажатиях пользователя
        // (паритет C#: Log() при !S.DevLog не буферизует и не пишет ничего)
        guard s.devLog else { return }
        // DateFormatter не потокобезопасен: форматируем под общим локом
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
               let size = attr[.size] as? Int, size > 2 * 1024 * 1024 {
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
