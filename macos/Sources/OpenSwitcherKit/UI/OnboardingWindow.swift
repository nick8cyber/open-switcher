import AppKit
import SwiftUI

/// Онбординг-окно разрешений (замена старым NSAlert): одно окно ведёт юзера от
/// первого запуска до «работает». Живая проверка раз в секунду, блок-инструкция
/// по «Универсальному доступу» (для .defaultTap его хватает — «Мониторинг ввода»
/// НЕ требуется) и разбор кейса «протухшей записи TCC»: тумблер в списке включён,
/// а AXIsProcessTrusted=false держится >20 с (запись от старой ad-hoc подписи) —
/// лечится выключить-включить тумблер или сбросом tccutil.
public final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let engine: Engine
    private var finished = false

    /// Единственный инстанс на запуск: повторные show() поднимают то же окно.
    private static var current: OnboardingWindowController?

    /// Показать онбординг (если уже открыт — просто поднять наверх).
    public static func show(engine: Engine) {
        if let w = current {
            w.present()
            return
        }
        let w = OnboardingWindowController(engine: engine)
        current = w
        w.present()
    }

    /// Показать, только если разрешения не в порядке (для автоматических мест).
    public static func showIfNeeded(engine: Engine) {
        let st = engine.permissionsState()
        guard !st.tap || !st.accessibility else { return }
        show(engine: engine)
    }

    public init(engine: Engine) {
        self.engine = engine
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "OpenSwitcher — настройка"
        window.level = .floating
        // закрытие не должно деаллокировать окно под живым контроллером
        window.isReleasedWhenClosed = false
        window.backgroundColor = UiTheme.shared.bg
        window.center()
        super.init(window: window)
        window.delegate = self
        let vc = NSHostingController(rootView: OnboardingView(engine: engine, onFinish: { [weak self] in
            self?.finish()
        }))
        contentViewController = vc
    }

    public required init?(coder: NSCoder) { fatalError() }

    private func present() {
        window?.makeKeyAndOrderFront(nil)
        // accessory-приложение: без activate окно появляется без фокуса
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Успех: попап «Работаю!» через Engine (одноразово, как и фоновая проверка)
    /// и авто-закрытие окна.
    private func finish() {
        guard !finished else { return }
        finished = true
        engine.fireReadyInfoFromOnboarding()
        window?.close()
    }

    public func windowWillClose(_ notification: Notification) {
        if Self.current === self { Self.current = nil }
    }
}

// ---------------------------------------------------------------- SwiftUI

/// Контент онбординга: заголовок, блок «Универсальный доступ» со живым бейджем,
/// вложенный кейс «протухла запись» (после 20 с безуспешного ожидания),
/// пояснение про «Мониторинг ввода» и большая кнопка-статус внизу.
/// public: офскрин-рендер (UITest) собирает вью из другого модуля.
public struct OnboardingView: View {
    let engine: Engine
    var onFinish: () -> Void
    /// Превью-режим офскрин-рендера (UI_STALE=1): сразу показать блок сброса прав.
    var previewStale: Bool = false

    @ObservedObject private var theme = ThemeEnv.shared
    @State private var tapOk = false
    @State private var axOk = accessibilityTrusted(prompt: false)
    @State private var axFalseSince: Date?
    @State private var staleHint = false
    @State private var greenSince: Date?
    @State private var resetting = false

    public init(engine: Engine, onFinish: @escaping () -> Void, previewStale: Bool = false) {
        self.engine = engine
        self.onFinish = onFinish
        _staleHint = State(initialValue: previewStale)
    }

    // Живая проверка: таймер на main раз в 1 с.
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public var body: some View {
        let t = theme.t
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Два разрешения — и всё работает")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(t.text)
                Text("Как в Punto Switcher: приложение исправляет раскладку — для этого нужны два разрешения")
                    .font(.system(size: 11))
                    .foregroundColor(t.dim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            // скролл — на случай появления блока «протухла запись»
            ScrollView {
                VStack(spacing: 12) {
                    axBlock(t)
                    if staleHint { staleBlock(t) }
                    monitorNote(t)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            bottomButton(t)
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 16)
        }
        .background(t.bg)
        .onAppear { checkTick() }
        .onReceive(ticker) { _ in checkTick() }
    }

    // Блок 1: «Универсальный доступ» — бейдж статуса, инструкция, кнопка панели.
    private func axBlock(_ t: ThemeColors) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Универсальный доступ")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(t.text)
                OnbBadge(ok: axOk)
                Spacer()
            }
            Text("Откройте Системные настройки → Конфиденциальность и безопасность → Универсальный доступ и включите тумблер OpenSwitcher в списке. Перезапуск не нужен: приложение подхватит разрешение само.")
                .font(.system(size: 11.5))
                .foregroundColor(t.dim)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                OnbButton(title: "Открыть настройки", accent: true) {
                    NSWorkspace.shared.open(PermissionPanels.accessibility)
                }
                Spacer()
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(t.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(t.cardBorder))
    }

    // Вложенный кейс: право «застряло» — запись TCC от старой ad-hoc подписи.
    private func staleBlock(_ t: ThemeColors) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(t.warn)
                Text("Право не применилось")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(t.text)
            }
            Text("OpenSwitcher уже в списке, но право не применилось (запись от старой сборки). Выключите тумблер и включите заново — или нажмите:")
                .font(.system(size: 11.5))
                .foregroundColor(t.dim)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                OnbButton(title: resetting ? "Сбрасываю…" : "Сбросить права",
                          accent: false, disabled: resetting) {
                    resetAccessibilityRights()
                }
                Spacer()
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(t.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(t.warn.opacity(0.5)))
    }

    // Блок 2: снимаем вопрос «почему нет в списке Мониторинга ввода».
    private func monitorNote(_ t: ThemeColors) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundColor(t.dim)
            Text("Мониторинг ввода — не требуется: наш перехват клавиш работает через Универсальный доступ.")
                .font(.system(size: 11))
                .foregroundColor(t.dim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(t.chipBg))
    }

    // Низ: большая кнопка-статус — «Жду разрешения…» → зелёное «Всё готово».
    private func bottomButton(_ t: ThemeColors) -> some View {
        let ready = axOk && tapOk
        return Text(ready ? "Всё готово — напечатайте ghbdtn и пробел!" : "Жду разрешения…")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(ready ? .white : t.dim)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 12).fill(ready ? t.ok : t.chipBg))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(ready ? Color.clear : t.cardBorder))
            .animation(.easeInOut(duration: 0.2), value: ready)
    }

    /// Тик живой проверки (main, 1 с): статус обоих разрешений, таймеры
    /// «протухшей записи» и авто-закрытия.
    private func checkTick() {
        let st = engine.permissionsState()
        let ax = accessibilityTrusted(prompt: false)
        tapOk = st.tap
        axOk = ax
        let now = Date()
        if ax && st.tap {
            // всё готово: зелёный статус, через 3 с окно закрывается само
            axFalseSince = nil
            if greenSince == nil { greenSince = now }
            if let g = greenSince, now.timeIntervalSince(g) >= 3 {
                onFinish()
            }
        } else {
            greenSince = nil
            if ax {
                axFalseSince = nil
            } else {
                if axFalseSince == nil { axFalseSince = now }
                // «протухшая запись»: тумблер включён (напрямую не видно), но
                // AXIsProcessTrusted=false держится >20 с при открытом онбординге
                if !staleHint, let f = axFalseSince, now.timeIntervalSince(f) > 20 {
                    staleHint = true
                }
            }
        }
    }

    /// «Сбросить права»: tccutil reset Accessibility com.openswitcher.app
    /// (без sudo). После сброса OpenSwitcher исчезает из списка — юзер включает
    /// тумблер заново, запись создаётся от текущей подписи.
    private func resetAccessibilityRights() {
        guard !resetting else { return }
        resetting = true
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", "Accessibility", "com.openswitcher.app"]
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.async {
                resetting = false
                staleHint = false
                axFalseSince = Date() // таймер кейса стартует заново
            }
        }
    }
}

/// Бейдж статуса: зелёный/красный — «✓ Включено» / «✗ Выключено».
struct OnbBadge: View {
    let ok: Bool
    @ObservedObject private var theme = ThemeEnv.shared

    var body: some View {
        let t = theme.t
        HStack(spacing: 5) {
            Circle()
                .fill(ok ? t.ok : t.danger)
                .frame(width: 7, height: 7)
            Text(ok ? "Включено" : "Выключено")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(ok ? t.ok : t.danger)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill((ok ? t.ok : t.danger).opacity(0.12)))
    }
}

/// Кнопка онбординга (как AccentButton в настройках, но с disabled-состоянием).
struct OnbButton: View {
    let title: String
    var accent: Bool
    var disabled: Bool = false
    let action: () -> Void
    @ObservedObject private var theme = ThemeEnv.shared
    @State private var hover = false

    var body: some View {
        let t = theme.t
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                Group {
                    if accent {
                        LinearGradient(colors: [hover ? t.accentHover : t.buttonAccent, t.accentPressed],
                                       startPoint: .top, endPoint: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(hover ? t.rowHover : t.chipBg)
                    }
                }
            )
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(accent ? Color.clear : t.cardBorder))
            .foregroundColor(accent ? .white : t.text)
            .opacity(disabled ? 0.5 : 1)
            .onTapGesture { if !disabled { action() } }
            .onHover { hover = $0 }
    }
}
