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
    private var lastWordSepShift = false  // ... набран с Shift ('?', '!', RU ',')
    private var lastWordApp: pid_t = 0    // приложение, где набрано последнее слово (0 = неизвестно)
    // ретро-флип одиночной буквы (§7, порт C#): 'f␣ns' -> «а ты». Одиночная буква + ровно один
    // пробел прямо перед текущим словом; слово конвертируется из ТОЙ ЖЕ раскладки — буква с ним
    private var prevSingle: [KeyRec]? = nil   // nil — кандидата нет
    private var prevSingleLayoutID: String? = nil
    private var prevSingleApp: pid_t = 0
    private var boundaryClean = true          // перед кареткой чистая граница слова (пробел/Enter/начало ввода)
    private var wordStartClean = false        // слово в буфере началось после чистой границы ('b2b' — нет)
    private var noFlipUntil: TimeInterval = 0  // кулдаун 5 с после ручной правки (спека v3 §6.2)
    private var markCount = 0
    private var wdTicks = 0

    private var suppressUntil: TimeInterval = 0
    private var lastShiftDown: TimeInterval = 0
    private var anyKeySinceShift = true
    private var tapVk = 0                  // клавиша, чей «тап» отслеживается
    private var lastTapDoneAt: TimeInterval = 0 // когда сработал последний успешный тап (для дребезг-фильтра, C# 942c5ba)
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
    /// Когда был поставлен лок ручного переключения (для «переключил раскладку
    /// ДО ввода» — лок переживает смену поля/окна в коротком окне, пароль-кейс)
    private var autoLockedAt: TimeInterval = 0

    /// Поставить лок ручного переключения (все ручные смены раскладки)
    private func lockAutoSwitch() {
        if s.lockAutoAfterManualSwitch {
            autoLocked = true
            autoLockedAt = Engine.ms()
        }
    }
    private var lastInputAt: TimeInterval = 0
    private var lastResendSpaceAt: TimeInterval = 0
    private var lastSpaceTextTick: TimeInterval = 0 // когда последний пробел ОКАЗАЛСЯ В ТЕКСТЕ (досыл ИЛИ нажатие) — для дедупа двойных (C# 3baec1e)

    // держалка main-таймера свежести кэша раскладок (TIS — только на main)
    private var layoutRefreshTimer: Timer?

    // точка отката последней автозамены
    private var undoPending = false
    private var undoText = ""
    private var undoLen = 0
    private var undoPrefix = ""      // ретро-флип: исходная буква+пробел перед словом ('f␣'), вернуть при откате
    private var undoPrefixLen = 0    // ... и длина напечатанного вместо неё («а␣» = 2)
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
    private var gapGen = 0               // поколение gap-окна: таймер досыла от прошлого тапа не трогает новое
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
        PasswordGuard.refreshOnMain()
        let t = Timer(timeInterval: 0.25, repeats: true) { _ in
            LayoutService.refreshOnMain()
            PasswordGuard.refreshOnMain() // флаг «в фокусе поле пароля» для гейта конвертации
        }
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
            // Телеметрия прав раз в минуту: точное состояние по мнению системы.
            // Системные проверки прав достоверны только на main (с потока тапа —
            // задокументированные false negatives), поэтому проверки и лог — там.
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
    /// уже покрывают). ВСЕ смены раскладки движка идут через эту точку —
    /// источник пишется в лог: «переворот без записи в лог» невозможен.
    private func switchLayoutOnMain(_ data: LayoutService.LayoutData, source: String) {
        let from = LayoutService.currentLayout()?.id.prefix(8) ?? "?"
        let to = data.id.prefix(8)
        logLine("layout switch: \(from) -> \(to) (\(source))")
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
            self.logLine("layout switch: ? -> \(target.id.prefix(8)) (verify-retry)")
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
        prevSingle = nil; boundaryClean = true // новое окно — начало ввода
        anyKeySinceShift = true
        tapAlone = false
        undoPending = false
        undoTailBroken = true
        gapActive = false; gapBuf.removeAll()
        // Лок ручного переключения переживает смену поля/окна, если переключение
        // было только что (<10 с): юзер сменил раскладку ДО ввода — под следующий
        // ввод (поле пароля в другом приложении), и снос лока на клике ломал пароль.
        // Остальные случаи — лок от старого поля умирает вместе с сеансом.
        if !(autoLocked && Engine.ms() - autoLockedAt < 10) { autoLocked = false }
        expectedLayoutID = nil // как _expectedValid=false в C#
        lastResendSpaceAt = 0
        lastSpaceTextTick = 0 // окно дедупа не переносится в другое окно  // окно эха не переносится в другое окно
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
            lockAutoSwitch()
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
                // дребезг/авторепит: тап быстрее 200 мс после предыдущего не армится
                // (двойное переключение «туда-обратно» рвёт слово посреди набора — C# 942c5ba)
                if lastTapDoneAt != 0 && (now - lastTapDoneAt) < 0.2 {
                    logLine("tap debounce: too soon after previous tap")
                } else {
                    tapVk = code
                    tapTarget = s.hotRuVk == code ? 0 : 1
                    tapDownAt = now
                    tapAlone = true
                }
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
                prevSingle = nil; boundaryClean = false // дальше — сочетание: текст у каретки неизвестен
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
                // дальше — сочетание (Cmd+V/Cmd+Z...): текст перед кареткой неизвестен (порт C#)
                prevSingle = nil; boundaryClean = false
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
        // Тап короче tapMinMs — задев: раскладку не переключаем. НАСТРОЙКА
        // tapMinMs, ДЕФОЛТ 0 = ВЫКЛ: жёсткий порог 0.12 с ел РЕАЛЬНЫЕ
        // рефлекторные тапы юзера на вин (бой 07.10 — переключения перестали
        // работать, откат 5f390d9). Включать только осознанно после калибровки
        // по логу ('tap not fired ... dt=')
        let dt = now - tapDownAt
        let minHold = Double(s.tapMinMs) / 1000.0
        let alone = tapAlone && !m.ctrl && !m.alt && !m.cmd
            && (minHold <= 0 || dt >= minHold) && dt < 0.7
        if !alone, s.devLog {
            logLine(String(format: "tap not fired: tapAlone=%d ctrl=%d alt=%d cmd=%d dt=%.3f suppress=%d", tapAlone ? 1 : 0, m.ctrl ? 1 : 0, m.alt ? 1 : 0, m.cmd ? 1 : 0, now - tapDownAt, now < suppressUntil ? 1 : 0))
        }
        if alone {
            logLine("tap fired: lang=\(tapTarget)")
            lastTapDoneAt = now
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
            var mRetro = "-"
            if let ps = prevSingle, let pl = LayoutService.getLayouts().first(where: { $0.id == prevSingleLayoutID }) {
                mRetro = "'" + LayoutService.render(pl, ps) + "'"
            }
            logLine("================ USER MARK #\(markCount) ================")
            logLine("mark: proc=\(fgProc) buf='\(mBuf)' lastWord='\(mLast)' (\(String(format: "%.1f", Engine.ms() - lastWordAt))s ago)" +
                " undo=\(undoPending ? "pending ('\(undoText)'\(undoTailBroken ? ", tail broken" : ""))" : "no") locked=\(autoLocked ? 1 : 0)" +
                " retroCand=\(mRetro)" +
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
            // не пробел (F8-метка текст не трогает) — перед кареткой больше не наш пробел: дедуп
            // глотает только пробел СРАЗУ после пробела ('слово, дальше' — пробел после запятой
            // законный; раньше условие «пустой буфер» его ело), порт C# _spaceAtCaretTick
            if code != 0x64 { lastSpaceTextTick = 0 }
        }

        // ---- guard отката: любые реальные нажатия, кроме исключений
        if !KeyCodeMap.isModifier(code) && !isUndoHotkey(code, event) && !isFixWordHotkey(code, event)
            && !(undoPending && code == KeyCodeMap.backspace) {
            keysSinceUndoPoint += 1
        }

        // Лок ручного переключения (решение владельца 2026-09-29): держится, пока
        // активно то же поле ввода и в нём идёт печать, — паузы в наборе его НЕ
        // снимают. Ушёл из поля (смена приложения или окна) → resetSession()
        // снимает лок вместе с остальным сеансом ввода.
        if !KeyCodeMap.isModifier(code) {
            lastInputAt = now
        }

        if now < suppressUntil {
            // suppress-окно: конвертация запрещена, но буфер синхронизируем
            if KeyCodeMap.isLetterKey(code) {
                // Cmd/Ctrl+буква — команда, не текст: буфер под ноль (как в основной ветке)
                if m.cmd || m.ctrl {
                    buf.clear(); lastWordSepKey = 0
                    prevSingle = nil; boundaryClean = false
                } else {
                    if buf.count == 0 { wordStartClean = boundaryClean }
                    buf.push(KeyRec(code, shift, caps))
                    if undoPending && !undoTailBroken {
                        if undoTail.count < 16 { undoTail.append(KeyRec(code, shift, caps)) }
                        else { undoTailBroken = true }
                    }
                }
            } else if KeyCodeMap.isSeparatorKey(code) {
                // разделитель (пробел, цифры, знаки): граница слова обязана делить буфер,
                // иначе слова слипаются ('чтосправками') и конвертация теряется (v3 §6.4)
                if buf.count > 0 {
                    lastWord = buf.snapshot()
                    lastWordAt = now
                    lastWordApp = 0
                }
                lastWordSepKey = 0 // и при пустом буфере: 'привет␣' + пробел — после слова уже два символа
                // знак дошёл до приложения — он часть хвоста отката (порт C#), иначе Break
                // после быстрого 'ghbdtn␣vbh␣' стирал на символ меньше и оставлял 'п'.
                // Ctrl/Alt/Cmd-сочетания текста не вставляют — не хвост
                if !(m.ctrl || m.alt || m.cmd) && undoPending && !undoTailBroken {
                    if undoTail.count < 16 { undoTail.append(KeyRec(code, shift, caps)) }
                    else { undoTailBroken = true }
                }
                if code == KeyCodeMap.space && !(m.ctrl || m.alt || m.cmd) { lastSpaceTextTick = now } // пробел ушёл в текст
                // в suppress слово не конвертируется — кандидата ретро-флипа не армим
                prevSingle = nil
                boundaryClean = code == KeyCodeMap.space && !shift && !(m.ctrl || m.alt || m.cmd)
                buf.clear()
            } else if code == KeyCodeMap.backspace {
                // забой: тот же учёт, что в основной ветке — иначе откат после быстрого
                // забоя стирал на символ больше (порт C#)
                if m.ctrl || m.alt || m.cmd {
                    buf.clear()
                    lastWordSepKey = 0
                    prevSingle = nil; boundaryClean = false
                    if undoPending { undoTailBroken = true }
                } else {
                    if buf.count == 0 { lastWordSepKey = 0; prevSingle = nil; boundaryClean = false }
                    buf.pop()
                    if undoPending && !undoTailBroken {
                        if !undoTail.isEmpty { undoTail.removeLast() }
                        else { undoTailBroken = true } // стёрли сам заменённый текст/досланный разделитель
                    }
                }
            } else if code == KeyCodeMap.enter {
                // буфер не делим (известное расхождение), но откат после Enter запрещён
                lastWordSepKey = 0
                prevSingle = nil; boundaryClean = true
                if undoPending { undoTailBroken = true }
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
                let bs2 = undoPrefixLen + undoLen + undoTail.count // undoLen уже с досланным знаком
                let tailText = undoTail.isEmpty ? "" : (undoLayout.map { LayoutService.render($0, undoTail) } ?? "")
                let restore2 = undoPrefix + undoText + undoSepText + tailText
                suppress(0.6)
                screenProbe()
                TextConverter.sendBackspaces(bs2)
                TextConverter.sendUnicode(restore2)
                prevSingle = nil
                boundaryClean = undoSepText == " "
                if restore2.hasSuffix(" ") { lastSpaceTextTick = Engine.ms() }
                if let ul = undoLayout {
                    switchLayoutOnMain(ul, source: "backspace-cancel")
                    verifySwitch(target: ul)
                    expectLayout(ul)
                }
                if s.lockAutoAfterManualSwitch { lockAutoSwitch() }
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
            prevSingle = nil // ручная правка текста — ретро-кандидат недостоверен
            if let undoBlock = undoBlockReason() {
                // откатить нечего ИЛИ откат уже невозможен (протух/хвост сломан/другое окно) —
                // Break = переворот последнего слова (порт C#: бой 28.09 16:53 — протухшая
                // точка отката 'pdjyjr' перехватывала Break, 'СУЩ' в буфере не перевернуть)
                logLine("hotkey: undo -> \(undoBlock), force flip")
                if !forceFlipLastWord() {
                    fireInfo(undoPending ? Engine.undoBlockMessage(undoBlock)
                                         : "Курсор не сразу после слова — выдели его и нажми Shift+Break")
                }
            } else {
                logLine("hotkey: undo")
                noFlipUntil = Engine.ms() + 5.0 // откат = «не так» — движок молчит 5 с (C#:617)
                undoLastConversion()
            }
            return false
        }
        if matchHot(codeEvent: code, event, vkHot: s.hotFixWordVk, modsHot: s.hotFixWordMods) {
            logLine("hotkey: fix-last-word")
            prevSingle = nil
            doFixLastWord()
            return false
        }
        if matchHot(codeEvent: code, event, vkHot: s.hotFixSelVk, modsHot: s.hotFixSelMods) {
            logLine("hotkey: fix-selection")
            prevSingle = nil; boundaryClean = false
            beginFixSelection(fromFixWord: false)
            return false
        }
        // Вставить без форматирования (как в Caramba): переназначаемый хоткей;
        // не задан (vk == 0) или PastePlain выключен — функция выкл
        if s.pastePlain && matchHot(codeEvent: code, event, vkHot: s.hotPasteVk, modsHot: s.hotPasteMods) {
            logLine("hotkey: paste-plain")
            prevSingle = nil; boundaryClean = false
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
                    // Cmd/Ctrl+буква в лаге смены раскладки — команда: в отложенные
                    // буквы не пишем (та же фантомная «ф»), отдаём как есть
                    if m.cmd || m.ctrl {
                        flushGap()
                        gapActive = false
                        return true
                    }
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
            // Cmd/Ctrl+буква — сочетание-команда, а не текст (Cmd+A/C/V/Z, Ctrl+A):
            // после него текст у каретки ненадёжен — как Tab/Esc, буфер под ноль.
            // Пушить букву нельзя: фантомная «ф» от Cmd+A собирала «фты» -> 'ans'
            // и переворачивала раскладку пинг-понгом (бой 23:31)
            if m.cmd || m.ctrl {
                buf.clear(); lastWordSepKey = 0
                prevSingle = nil; boundaryClean = false
                return true
            }
            let rec = KeyRec(code, shift, caps)
            if buf.count == 0 { wordStartClean = boundaryClean } // что стоит перед словом (ретро-флип)
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
                lastWordSepKey = 0
                prevSingle = nil; boundaryClean = false
                if undoPending { undoTailBroken = true }
                return true
            }
            // забой при пустом буфере стирает разделитель/само слово — каретка уже
            // не за [слово+разд], точный force-flip стёр бы лишний символ; ретро-кандидат
            // ('f␣' — стёрли пробел) и чистота границы тоже больше не известны
            if buf.count == 0 { lastWordSepKey = 0; prevSingle = nil; boundaryClean = false }
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
            }
            // после Enter (любого, и при пустом буфере: 'слово␣' + Enter) точный
            // переворот невозможен — строка ушла/перенеслась, Break печатал бы в пустое поле
            lastWordSepKey = 0
            // (сброс sep для пути без разделителя — в конце tryConvertWord)
            if !modified && s.fixOnEnter {
                converted = tryConvertWord(word, resendKey: KeyCodeMap.enter, resendShift: false, manual: false) // ретро-флип 'f␣ns'+Enter — внутри
            }
            prevSingle = nil; boundaryClean = true // новая строка / сообщение ушло
            // одиночные буквы на Enter не конвертируются (как и на пробеле):
            // у одной буквы нет сигнала намерения
            undoTailBroken = true
            buf.clear()
            return !converted
        }

        if code == KeyCodeMap.tab || code == KeyCodeMap.esc {
            buf.clear(); lastWordSepKey = 0
            prevSingle = nil; boundaryClean = false // что перед кареткой — неизвестно
            return true
        }

        if KeyCodeMap.isSeparatorKey(code) {
            let modified = m.ctrl || m.alt || m.cmd || shift
            var converted = false
            let bufWas = buf.count
            // эхо-состояние ДО конвертации: она сама ставит тик досыла —
            // флаг, снятый после, всегда 'y' (артефакт, морочил диагностику)
            let echoBefore = lastResendSpaceAt != 0 && (now - lastResendSpaceAt) < 0.6

            // дедуп двойных пробелов (настройка SpaceDedupMs): второй пробел подряд
            // при пустом буфере в пределах окна глотается — защита от рефлекса
            // двойного нажатия после конвертаций (порт C# Engine.cs:802-811)
            // (now — в СЕКУНДАХ, окно — в мс: раньше сравнение без /1000 давало окно в 2000 с,
            // и пробел после запятой/цифры съедался почти всегда). Shift+пробел — тоже пробел
            if code == KeyCodeMap.space && !(m.ctrl || m.alt || m.cmd) && !s.paused && s.spaceDedupMs > 0 &&
                buf.count == 0 && lastSpaceTextTick != 0 && (now - lastSpaceTextTick) < Double(s.spaceDedupMs) / 1000.0 {
                logLine("space: dedup swallowed")
                return false // проглотить (в текст не идёт)
            }

            // ОДИНОЧНЫЕ БУКВЫ НЕ КОНВЕРТИРУЮТСЯ АВТОМАТИЧЕСКИ (порт фикса win b1b11cf):
            // у одной буквы нет сигнала намерения — wordness-флип то не срабатывал
            // когда нужен ('f' в начале фразы), то портил латинские токены
            // ('b2b' -> 'b2и': цифра рвёт слово, вторая 'b' становилась «одиночной»).
            // Осознанный переворот — Break (force-flip).
            // Исключение — ретро-флип: буква переворачивается ВМЕСТЕ со следующим
            // сконвертированным словом ('f␣ns' -> «а ты»), см. tryConvertWord.

            // Ctrl/Alt/Cmd — шорткат, не вмешиваемся; Shift — НЕ шорткат: '?', '!', '"', RU ','
            // — текст и конец слова (порт C#, бой 29.09 19:24:37: слово+'?' не конвертилось)
            let cmdMods = m.ctrl || m.alt || m.cmd
            if !converted && !cmdMods && s.autoConvertOnWordEnd && buf.count > 0 {
                let word = buf.snapshot()
                converted = tryConvertWord(word, resendKey: code, resendShift: shift, manual: false)
            }
            if buf.count > 0 && !cmdMods {
                lastWord = buf.snapshot()
                lastWordAt = now
                lastWordApp = fgApp
                lastWordSepKey = code // разделитель сразу после слова — нужен точному перевороту
                lastWordSepShift = shift // '?' = Shift+/ — перепечатать тем же знаком
            } else {
                // второй разделитель подряд ('слово.␣', 'слово␣␣') или сочетание-команда —
                // после слова уже не ровно один известный символ (порт C#)
                lastWordSepKey = 0
            }
            // Shift — НЕ шорткат: '!', '?', ',' (RU Shift+/), Shift+пробел доходят до текста
            // и обязаны быть в хвосте ('привет мир!' + Break стирал на символ меньше), порт C#
            if !(m.ctrl || m.alt || m.cmd) && !converted && undoPending && !undoTailBroken && code != KeyCodeMap.tab {
                if undoTail.count < 16 { undoTail.append(KeyRec(code, shift, caps)) }
                else { undoTailBroken = true }
            }
            // трассировка пробелов: лишние/пропавшие пробелы ловятся здесь (v3 §15)
            // пробел ушёл в текст (досыл замены ставит тик сам) — следующий пробел подряд дедуп проглотит
            if code == KeyCodeMap.space && !(m.ctrl || m.alt || m.cmd) && !converted { lastSpaceTextTick = now }
            if code == KeyCodeMap.space && !modified {
                // текст слова в лог: полный транскрипт — любое «порезанное» слово
                // видно в логе даже при отказе конвертации
                let wordText = buf.count > 0 ? (LayoutService.currentLayout().map { LayoutService.render($0, buf.snapshot()) } ?? "?") : "-"
                logLine("space: \(converted ? "flip+resend" : "pass") bufWas=\(bufWas) word='\(wordText)' echoInWindow=\(echoBefore ? "y" : "n")")
            }
            // ретро-флип: одиночная буква после чистой границы + голый пробел — кандидат
            // для СЛЕДУЮЩЕГО слова ('f␣' ждёт 'ns'). 'b2b␣' — нет: 'b' начата после цифры
            let plainSpace = code == KeyCodeMap.space && !modified
            if plainSpace && !converted && buf.count == 1 && wordStartClean {
                prevSingle = buf.snapshot()
                prevSingleLayoutID = LayoutService.currentLayout()?.id
                prevSingleApp = fgApp
            } else {
                prevSingle = nil
            }
            boundaryClean = plainSpace
            buf.clear()
            return !converted
        }

        // F-клавиши, навигация, Ins/Del — сброс буфера (реальные macOS-коды)
        if KeyCodeMap.isNavigationKey(code) {
            buf.clear()
            lastWordSepKey = 0 // каретка сдвинута — уже не за [слово+разд]
            prevSingle = nil; boundaryClean = false
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
        prevSingle = nil      // каретка переехала: 'f␣' уже не перед словом
        lastSpaceTextTick = 0 // и что перед ней — неизвестно (дедуп пробела снят)
        boundaryClean = true  // клик в поле — как начало ввода
        keysSinceUndoPoint += 1
        if undoPending { undoTailBroken = true }
    }

    private func flushGap() {
        guard !gapBuf.isEmpty, let gl = gapLayout else { return }
        let str = LayoutService.render(gl, gapBuf)
        TextConverter.sendUnicode(str)
        logLine("gap: flushed \(gapBuf.count) keys as '\(str)'")
        // досланные буквы — часть текущего слова и хвоста отката (порт C#): без этого
        // следующая конвертация/откат стирали на столько символов меньше
        for rec in gapBuf {
            if buf.count == 0 { wordStartClean = boundaryClean }
            buf.push(rec)
            if undoPending && !undoTailBroken {
                if undoTail.count < 16 { undoTail.append(rec) } else { undoTailBroken = true }
            }
        }
        lastSpaceTextTick = 0
        gapBuf.removeAll()
    }

    /// Досыл gap-буфера по дедлайну, не дожидаясь следующей клавиши (порт C# ArmGapFlushTimer):
    /// проглоченная в просвете буква иначе висела невидимой до следующего нажатия.
    private func armGapFlushTimer() {
        gapGen += 1
        let gen = gapGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in
            self?.performOnTapThread { [weak self] in
                guard let self = self, gen == self.gapGen, self.gapActive else { return } // новый тап / окно сменилось
                self.flushGap()
                self.gapActive = false
            }
        }
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

    /// Замер экрана вокруг инжекции: текст фокусного поля до и через 0.4 с после —
    /// единственная правда об «отрезало лишнее» (самоотчёт движка не считается).
    private func screenProbe() {
        DispatchQueue.main.async { [weak self] in
            let before = PasswordGuard.focusedText().map { String($0.suffix(80)) } ?? "?"
            self?.logLine("screen-before: '\(before)'")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                let after = PasswordGuard.focusedText().map { String($0.suffix(80)) } ?? "?"
                self?.logLine("screen-after: '\(after)'")
            }
        }
    }

    public func switchToLanguage(_ lang: Int) {
        performOnTapThread { [weak self] in self?.switchToLanguageOnTap(lang) }
    }

    private func switchToLanguageOnTap(_ lang: Int) {
        updateForeground()
        prevSingle = nil // юзер выбрал язык явно — букву до переключения не трогаем
        guard let target = LayoutService.findLayoutByLang(lang) else {
            fireInfo(lang == 0 ? "Русская раскладка не найдена" : "Английская раскладка не найдена")
            return
        }
        switchLayoutOnMain(target, source: "switch-to-lang")
        verifySwitch(target: target)
        expectLayout(target)
        lockAutoSwitch()
        gapActive = true; gapLayout = target; gapBuf.removeAll()
        gapDeadline = Engine.ms() + 0.8
        armGapFlushTimer()
        fireInfo(lang == 0 ? "РУС" : "ENG")
    }

    public func switchToOtherLayout() {
        performOnTapThread { [weak self] in self?.switchToOtherLayoutOnTap() }
    }

    private func switchToOtherLayoutOnTap() {
        updateForeground()
        prevSingle = nil
        let layouts = LayoutService.getLayouts()
        guard let curID = LayoutService.currentLayout()?.id,
              let other = layouts.first(where: { $0.id != curID }) else { return }
        let probe = [KeyRec(KeyCodeMap.ansiCode(ofLatin: "a"), false, false)]
        let name = LanguageTables.langOf(LayoutService.render(other, probe)) == 0 ? "РУС" : "ENG"
        switchLayoutOnMain(other, source: "switch-other")
        verifySwitch(target: other)
        expectLayout(other)
        lockAutoSwitch()
        gapActive = true; gapLayout = other; gapBuf.removeAll()
        gapDeadline = Engine.ms() + 0.8
        armGapFlushTimer()
        fireInfo("Раскладка: \(name)")
    }

    /// Попытка конвертации слова (порт TryConvertWord).
    private func tryConvertWord(_ word: [KeyRec], resendKey: Int, resendShift: Bool, manual: Bool) -> Bool {
        var why: String? = nil
        if s.paused { why = "paused" }
        else if word.count < 2 {
            // сама буква в логе: без неё не отличить законное «в» от брошенного 'f' перед 'ns'->'ты'
            let letter = word.count == 1 ? (LayoutService.currentLayout().map { " '\(LayoutService.render($0, word))'" } ?? "") : ""
            why = "too-short (\(word.count)\(letter))"
        }
        else if !manual && s.lockAutoAfterManualSwitch && autoLocked { why = "locked" }
        // Поле пароля (AXSecureTextField): конвертации там нет ВОВСЕ — буквы
        // невидимы, любой флип раскладки посреди ввода ломает пароль целиком
        else if !manual && PasswordGuard.isSecureFocused { why = "password field" }
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

        // РУ->EN авто-переворот коротких (<5 букв): до 3 букв — всегда нет
        // («ща», «рф» — правильный русский, EN-прочтение 'of'/'ha' — мусор).
        // 3-4 буквы — отказ только если набранное ПРАВИЛЬНОЕ русское («еще», «она»);
        // мусор вроде 'кфп' конвертится в словарную EN-цель ('rag', 'git') — гейт
        // целиком блокировал класс коротких EN-слов (бой 03:19:46). Цель без словаря
        // отсечётся главным правилом ниже. Порт C# (гейт расслаблен, 28.09).
        if !manual && !acceptedWord && cur.lang == 0 && best.lang == 1 && word.count < 5 &&
            (word.count < 3 || WordDict.has(cur.text, 0)) {
            logLine("convert skip: ru->en short ('\(cur.text)' -> '\(best.text)')")
            return false
        }

        // РУ->EN: набранное — правильное русское (словарь ИЛИ морфология 55k-корпуса)
        // => EN-прочтение не рассматривается вовсе. Порт C# 81ae150, расширенный со
        // словаря на possibleWord: «ебаная», «говно», «твого» вне словаря, но это
        // явно русский текст — скачировать их против EN-мусора — мина (бой 00:39)
        if !manual && !acceptedWord && cur.lang == 0 && best.lang == 1 &&
            (WordDict.has(cur.text, 0) || LanguageTables.possibleWord(cur.text, 0)) {
            logLine("convert skip: ru->en real ('\(cur.text)' -> '\(best.text)')")
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
                // словарное слово+знак сильнее несловарного «возможного» с лишней буквой
                // ('nt,z.' -> «тебя.», а не «тебяю»; порт C#, бой 02.10 19:08:53)
                let altDict = WordDict.has(altCore, best.lang), baseDict = WordDict.has(baseCore, best.lang)
                if altValid && (!baseValid || (altDict && !baseDict)) { bestText = alt }
            }
            let core = LanguageTables.lettersOnly(bestText)
            // цель: словарное слово ИЛИ «возможное» слово языка от 3 букв (v3 §5.11)
            if !WordDict.has(core, best.lang) &&
                (core.count < 3 || !LanguageTables.possibleWord(core, best.lang)) {
                logLine("convert skip: target-not-in-dict ('\(bestText)')")
                return false
            }
        }

        // форма цели (v3 §5.11): только буквы ИЛИ буквы + ОДИН знак в конце. Знак ВНУТРИ
        // ('et,e' из русского слова с «б») — мусор всегда, и для выученных пар: старая
        // проверка вычитала длину букв и пропускала знак в середине (порт C#, бой 02.10)
        if !manual && !Engine.targetShapeOk(bestText) {
            logLine("convert skip: target-not-letters ('\(bestText)')")
            return false
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

        // ретро-флип одиночной буквы перед словом ('f␣ns' -> «а ты», порт C#): только авто-замена
        // по разделителю/Enter, буква набрана в той же раскладке и приложении, ровно один пробел
        var retroFrom: String? = nil, retroTo = ""
        if !manual && resendKey != 0, let ps = prevSingle, prevSingleApp == fgApp,
           prevSingleLayoutID == cur.layoutID,
           let curL = layouts.first(where: { $0.id == cur.layoutID }),
           let bestL = layouts.first(where: { $0.id == best.layoutID }) {
            let pCur = LayoutService.render(curL, ps)
            let pBest = LayoutService.render(bestL, ps)
            if Engine.retroFlipLetterOk(pCur, cur.lang, pBest, best.lang) { retroFrom = pCur; retroTo = pBest }
            else { logLine("retro-flip skip: '\(pCur)' -> '\(pBest)' (not a one-letter word pair)") }
        }
        prevSingle = nil
        let retroPrefix = retroFrom.map { $0 + " " } ?? ""   // 'f␣' — как набрано
        let retroText = retroFrom != nil ? retroTo + " " : "" // «а␣» — чем заменяем
        let retroLog = retroFrom != nil ? " (+retro '" + (retroFrom ?? "") + "' -> '" + retroTo + "')" : ""

        lastWordSepKey = 0 // ручной/беспраздельный путь: точный force-flip разоружаем (C#:1236)
        // bs= в лог: сколько символов реально стирается перед инжекцией —
        // «отрезало лишнее сзади» ловится сверкой этого числа с текстом
        logLine("convert OK: '\(cur.text)' -> '\(bestText)'\(retroLog) (resend=\(resendKey) bs=\(word.count + retroPrefix.count))")
        lastConvertInfo = "'\(retroPrefix)\(cur.text)' -> '\(retroText)\(bestText)'"
        lastWord = word

        suppress(0.6)
        screenProbe()
        TextConverter.sendBackspaces(word.count + retroPrefix.count)
        TextConverter.sendUnicode(retroText + bestText)
        // набранный знак рендерится по СТАРОЙ раскладке — до switchTo (renderKeyChar
        // читает живую currentLayout) и идёт в точку отката; ДОСЫЛАЕМ его символом
        // раскладки цели (порт C#): слово набрано не в той раскладке — и знак пальцы жали
        // под целевую ('проверь' в EN + Shift+7 = '&', хотел '?'; '/' -> '.'; '@' <-> '"')
        let sepText = (resendKey != 0 && resendKey != KeyCodeMap.enter)
            ? TextConverter.renderKeyChar(keyCode: resendKey, shift: resendShift) : ""
        let sentSep = Engine.sepInLayout(resendKey, resendShift, layouts.first(where: { $0.id == best.layoutID }), sepText)
        if sentSep != sepText { logLine("convert sep: '\(sepText)' -> '\(sentSep)'") }
        if resendKey != 0 {
            if resendKey == KeyCodeMap.enter { TextConverter.sendEnter() }
            else { TextConverter.sendUnicode(sentSep) }
        }
        if resendKey == KeyCodeMap.space {
            lastResendSpaceAt = Engine.ms()
            lastSpaceTextTick = Engine.ms() // окно дедупа двойных пробелов учитывает и досыл
        }
        // РАСКЛАДКУ НА ЭНТЕРЕ НЕ МЕНЯЕМ (юзер запретил; порт C# 06.10):
        // слово перед отправкой поправили — и хватит, раскладка остаётся как была
        if resendKey != KeyCodeMap.enter, let bl = layouts.first(where: { $0.id == best.layoutID }) {
            switchLayoutOnMain(bl, source: "convert")
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
        // undoLen — ВСЁ, что напечатали вместо исходного: цель + досланный знак (он может
        // отличаться от набранного: '?' вместо '&'); стирание отката считается только по нему
        undoLen = bestText.count + sentSep.count
        // откат ретро-флипа возвращает и букву: переворот 'f' держался только на слове
        undoPrefix = retroPrefix
        undoPrefixLen = retroText.count
        undoSepText = sepText
        undoLayout = layouts.first { $0.id == cur.layoutID }
        undoApp = fgApp
        undoAt = Engine.ms()
        keysSinceUndoPoint = 0
        undoTail.removeAll()
        undoTailBroken = false

        // RU->EN заучиваем ТОЛЬКО в словарную EN-цель (порт C#): ошибочная замена русского
        // слова, поправленная руками, иначе через 15 с становилась «выученной» навсегда
        let learnable = cur.lang != 0 || best.lang != 1 ||
            WordDict.has(LanguageTables.lettersOnly(bestText), 1)
        if injOk && cur.text.count >= 3 && learnable {
            // принятие честное: через 15 с, если юзер не откатил (v3 §12)
            let acceptedTyped = cur.text.lowercased()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self = self, !self.isRejected(acceptedTyped) else { return }
                self.rememberAccepted(acceptedTyped)
            }
        }

        // попап показывает цель с хвостом-знаком (и ретро-буквой)
        fireConverted(retroPrefix + cur.text, retroText + bestText)
        return true
    }

    /// Цель авто-замены по форме (порт C# TargetShapeOk): только буквы, либо буквы + ровно
    /// один знак В КОНЦЕ.
    public static func targetShapeOk(_ t: String) -> Bool {
        let core = LanguageTables.lettersOnly(t)
        if core.isEmpty { return false }
        return t == core || (t.count == core.count + 1 && t.hasPrefix(core))
    }

    /// Знак-разделитель в раскладке цели (порт C# SepInLayout): тот же физический знак, каким
    /// его задумали пальцы. Сбой/не один символ — оставить набранный typed.
    static func sepInLayout(_ code: Int, _ shift: Bool, _ layout: LayoutService.LayoutData?, _ typed: String) -> String {
        guard !typed.isEmpty, let l = layout, let t = LayoutService.renderKey(l, KeyRec(code, shift, false)),
              t.count == 1 else { return typed }
        return t
    }

    /// Ретро-флип одиночной буквы (§7, порт C# RetroFlipLetterOk): переворачивается, только
    /// если набранное — НЕ однобуквенное слово своего языка ('f'), а прочтение в языке цели —
    /// однобуквенное слово (а/и/в/к/о/с/у/я, a/i). «а», «в», 'a', 'i' как набраны — неприкосновенны.
    public static func retroFlipLetterOk(_ typed: String, _ typedLang: Int, _ target: String, _ targetLang: Int) -> Bool {
        return typed.count == 1 && target.count == 1 &&
            typedLang >= 0 && targetLang >= 0 && typedLang != targetLang &&
            LanguageTables.langOf(typed) == typedLang && LanguageTables.langOf(target) == targetLang &&
            !WordDict.hasSingleLetterWord(typed, typedLang) &&
            WordDict.hasSingleLetterWord(target, targetLang)
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

    /// Можно ли откатить последнюю замену прямо сейчас: nil — да, иначе причина
    /// (порт C# UndoBlockReason; фокус-поля на macOS не отслеживается).
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

    /// Отмена последней автозамены (порт UndoLastConversion).
    public func undoLastConversion() {
        if let block = undoBlockReason() {
            logLine("undo skip: \(block)"); fireInfo(Engine.undoBlockMessage(block)); return
        }

        // префикс — буква ретро-флипа ('а␣' -> 'f␣'): её переворот держался только на слове
        let bs = undoPrefixLen + undoLen + undoTail.count // undoLen уже с досланным знаком (раньше force-flip считал его дважды и съедал символ перед словом)
        let tailText = undoTail.isEmpty ? "" : (undoLayout.map { LayoutService.render($0, undoTail) } ?? "")
        let restore = undoPrefix + undoText + undoSepText + tailText
        suppress(0.6)
        screenProbe()
        TextConverter.sendBackspaces(bs)
        TextConverter.sendUnicode(restore)
        prevSingle = nil
        if restore.hasSuffix(" ") { lastSpaceTextTick = Engine.ms() } // 'слово␣' — перед кареткой пробел
        if let ul = undoLayout {
            switchLayoutOnMain(ul, source: "undo-hotkey")
            verifySwitch(target: ul)
            expectLayout(ul)
        }
        lockAutoSwitch()
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
    /// false — свежего слова у каретки нет (плашку отказа показывает вызывающий).
    @discardableResult
    public func forceFlipLastWord() -> Bool {
        updateForeground()
        if buf.count >= 2 {
            logLine("force-flip: current buffer (\(buf.count) keys)")
            _ = forceConvertWord(buf.snapshot(), trailSepKey: 0, skipRejected: true)
            buf.clear() // флип живого буфера — буфер отработал
            return true
        }
        // слово только что завершилось, известен разделитель после него, каретка
        // сразу за разделителем — точный переворот куском [слово+разд] (v3: ≤10 с, то же окно)
        if buf.count == 0 && !lastWord.isEmpty && lastWordSepKey != 0 &&
            lastWordApp == fgApp && (Engine.ms() - lastWordAt) < 10 {
            logLine("force-flip: exact path (last word, sep=0x\(String(lastWordSepKey, radix: 16)))")
            _ = forceConvertWord(lastWord, trailSepKey: lastWordSepKey, trailSepShift: lastWordSepShift, skipRejected: true)
            return true
        }
        // честный отказ — паритет коду C# v3
        logLine("force-flip skip: no fresh word at caret")
        return false
    }

    /// Принудительный переворот слова. skipRejected — не блокировать переворот
    /// выученно-отменённых слов (Option-пинг-понг: юзер гоняет слово туда-сюда
    /// руками); skipLearn — не писать в самообучение (чистый ручной инструмент).
    private func forceConvertWord(_ word: [KeyRec], trailSepKey: Int, trailSepShift: Bool = false,
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
        // осознанный Break (главный путь) сильнее прошлых отказов: слово возвращаем
        // в строй (иначе один случайный откат блокировал слово НАВСЕГДА — и авто,
        // и ручной переворот; бой 27.09 23:20: 'free' не получить никаким путём).
        // Option-пинг-понг (skipLearn) тоже пробивает, но rejected не трогает
        let wasRejected = isRejected(cur.text.lowercased())
        guard let best = cands.filter({ $0.layoutID != curID && $0.lang >= 0 }).max(by: { $0.score < $1.score }),
              best.text != cur.text else {
            logLine("force-flip skip: no other reading"); return false
        }

        logLine("force-flip: '\(cur.text)' -> '\(best.text)'")
        lastConvertInfo = "force '\(cur.text)' -> '\(best.text)'"
        if wasRejected && !skipLearn {
            removeRejected(cur.text.lowercased())
            logLine("force-flip: unrejected '\(cur.text.lowercased())'")
        }

        suppress(0.6)
        TextConverter.targetPid = fgApp
        // хвост-разделитель после слова уже в тексте приложения — стираем вместе
        // со словом и перепечатываем (иначе переворот съедает пробел/запятую) (v3 §9)
        let trailLen = trailSepKey != 0 ? 1 : 0
        // знак после слова — в раскладке цели, как при авто-замене ('ghbdtn/' -> 'привет.');
        // откат вернёт набранный (undoSepText ниже)
        let trailTyped = trailSepKey != 0 ? TextConverter.renderKeyChar(keyCode: trailSepKey, shift: trailSepShift) : ""
        let trailSent = Engine.sepInLayout(trailSepKey, trailSepShift, layouts.first(where: { $0.id == best.layoutID }), trailTyped)
        screenProbe()
        TextConverter.sendBackspaces(word.count + trailLen)
        TextConverter.sendUnicode(best.text)
        if !trailSent.isEmpty {
            TextConverter.sendUnicode(trailSent)
        }
        if trailSepKey == KeyCodeMap.space { lastSpaceTextTick = Engine.ms() } // перепечатанный пробел — перед кареткой
        // раскладку переключаем только при перевороте СЛОВА: одиночная буква
        // ('А'->'F' в «F8») — правка одного символа, юзер продолжает в своём языке
        if word.count > 1, let bl = layouts.first(where: { $0.id == best.layoutID }) {
            switchLayoutOnMain(bl, source: "force-flip")
            verifySwitch(target: bl)
            expectLayout(bl)
        }

        undoPending = true
        undoText = cur.text
        // точка отката включает хвост-разделитель (порт C# 8e8af36): Break после
        // force-флипа 'ии␣' вернёт 'ии␣' целиком — раньше пробел съедался и
        // 'bb ␣ жрет' склеивалось в 'bиижрет'
        undoLen = best.text.count + trailSent.count // всё напечатанное: слово + перепечатанный знак
        undoPrefix = ""; undoPrefixLen = 0 // force-flip ретро-букву не трогает
        prevSingle = nil
        undoSepText = trailTyped // вернуть знак как набран
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
            _ = forceConvertWord(lastWord, trailSepKey: lastWordSepKey, trailSepShift: lastWordSepShift, skipRejected: true, skipLearn: true)
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
            logLine("layout switch: ? -> \(target.id.prefix(8)) (fix-selection)")
            LayoutService.switchTo(target)
            verifySwitch(target: target)
            expectLayout(target)
        }
        lockAutoSwitch()

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

    /// Снять отказ: слово снова в строю (юзер force-flip'нул его осознанно).
    /// Перезапись learned.txt обязательна — иначе после рестарта отказ возвращался.
    private func removeRejected(_ typed: String) {
        learnedLock.lock()
        let removed = rejected.remove(typed) != nil
        let snapshot = rejected
        learnedLock.unlock()
        guard removed else { return }
        DispatchQueue.global(qos: .utility).async {
            let _ = try? snapshot.joined(separator: "\n").appending("\n").write(toFile: self.learnedPath, atomically: true, encoding: .utf8)
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
