import AppKit
import SwiftUI

/// Онбординг-окно разрешений (замена старым NSAlert): одно окно ведёт юзера от
/// первого запуска до «работает» — за три клика. Оба разрешения запрашиваются
/// ПРОГРАММНО (macOS 12+ API): «Универсальный доступ» — через
/// AXIsProcessTrustedWithOptions(prompt: true), «Мониторинг ввода» — через
/// CGRequestListenEventAccess (система сама добавит приложение в список и
/// покажет тумблер). Живая проверка раз в секунду; всё зелёное — окно
/// закрывается само с попапом «Работаю!».
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

    /// Показать, только если хоть одно из трёх прав не в порядке
    /// (для автоматических мест).
    public static func showIfNeeded(engine: Engine) {
        let st = engine.permissionsState()
        let permsOk = Permissions.listenEventGranted()
            && Permissions.postEventGranted()
            && st.accessibility
        guard !(permsOk && st.tap) else { return }
        show(engine: engine)
    }

    public init(engine: Engine) {
        self.engine = engine
        // 470: обе карточки с кнопками «Разрешить» должны влезать без скролла
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
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

/// Контент онбординга: две карточки-разрешения с живыми бейджами и кнопкой
/// «Разрешить» (программный запрос через системный API) и большая кнопка-статус
/// внизу: всё выдано → зелёная, через 3 с окно закрывается само.
/// public: офскрин-рендер (UITest) собирает вью из другого модуля.
public struct OnboardingView: View {
    let engine: Engine
    var onFinish: () -> Void
    /// Превью-режим офскрин-рендера (UI_STALE=1): показать «всё готово»
    /// (зелёные бейджи и нижняя кнопка), не дожидаясь реальных прав.
    var previewReady: Bool = false
    /// Превью-режим офскрин-рендера (UI_DENIED=1): показать карточки без прав —
    /// красные бейджи и кнопки «Разрешить» (машина с уже выданными правами
    /// рендерит зелёное состояние и кнопки не видны).
    var previewDenied: Bool = false

    @ObservedObject private var theme = ThemeEnv.shared
    @State private var listenOk = false
    @State private var postOk = false
    @State private var axOk = false
    @State private var tapOk = false
    @State private var greenSince: Date?

    public init(engine: Engine, onFinish: @escaping () -> Void, previewReady: Bool = false,
                previewDenied: Bool = false) {
        self.engine = engine
        self.onFinish = onFinish
        self.previewReady = previewReady
        self.previewDenied = previewDenied
    }

    // Живая проверка: таймер на main раз в 1 с (проверки прав недостоверны
    // с фонового потока — потому только main).
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

            ScrollView {
                VStack(spacing: 12) {
                    axBlock(t)
                    listenBlock(t)
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

    // Блок A: «Универсальный доступ» — инжекция исправленного текста.
    // «Разрешить» дергает AX-запрос с prompt=true: система покажет диалог
    // добавления приложения в список.
    private func axBlock(_ t: ThemeColors) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Универсальный доступ")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(t.text)
                OnbBadge(ok: axOk)
                Spacer()
            }
            Text("Чтобы приложение могло исправлять текст — вставлять правильные буквы вместо набранных не в той раскладке.")
                .font(.system(size: 11.5))
                .foregroundColor(t.dim)
                .fixedSize(horizontal: false, vertical: true)
            if !axOk {
                HStack {
                    OnbButton(title: "Разрешить", accent: true) {
                        _ = accessibilityTrusted(prompt: true)
                    }
                    OnbButton(title: "Открыть настройки", accent: false) {
                        NSWorkspace.shared.open(PermissionPanels.accessibility)
                    }
                    Spacer()
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(t.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(axOk ? t.ok.opacity(0.35) : t.warn.opacity(0.5)))
    }

    // Блок B: «Мониторинг ввода» — чтение нажатых клавиш. «Разрешить» зовёт
    // CGRequestListenEventAccess: система САМА добавит приложение в список
    // Мониторинга и покажет тумблер (раньше юзер добавлял вручную через «+»).
    private func listenBlock(_ t: ThemeColors) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Мониторинг ввода")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(t.text)
                OnbBadge(ok: listenOk)
                Spacer()
            }
            Text("Чтобы приложение видело нажатия клавиш и понимало, что вы набрали не на той раскладке.")
                .font(.system(size: 11.5))
                .foregroundColor(t.dim)
                .fixedSize(horizontal: false, vertical: true)
            if !listenOk {
                HStack {
                    OnbButton(title: "Разрешить", accent: true) {
                        Permissions.requestListenEventAccess()
                    }
                    OnbButton(title: "Открыть настройки", accent: false) {
                        NSWorkspace.shared.open(PermissionPanels.inputMonitoring)
                    }
                    Spacer()
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(t.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(listenOk ? t.ok.opacity(0.35) : t.warn.opacity(0.5)))
    }

    // Низ: большая кнопка-статус — «Жду разрешения…» → зелёное «Всё готово».
    private func bottomButton(_ t: ThemeColors) -> some View {
        let ready = readyNow
        return Text(ready ? "Всё готово — напечатайте ghbdtn и пробел!" : "Жду разрешения…")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(ready ? .white : t.dim)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 12).fill(ready ? t.ok : t.chipBg))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(ready ? Color.clear : t.cardBorder))
    }

    /// Полный онбординг: «Мониторинг ввода» + инжекция (PostEvent) + AX.
    private var readyNow: Bool {
        previewReady || (listenOk && postOk && axOk)
    }

    /// Тик живой проверки (main, 1 с): статус всех прав и таймер авто-закрытия.
    private func checkTick() {
        if previewDenied {
            // превью офскрин-рендера: карточки в состоянии «нет прав»
            listenOk = false; postOk = false; axOk = false; tapOk = false
            return
        }
        let st = engine.permissionsState()
        listenOk = Permissions.listenEventGranted()
        postOk = Permissions.postEventGranted()
        axOk = accessibilityTrusted(prompt: false)
        tapOk = st.tap
        if readyNow {
            // всё готово: зелёный статус, через 3 с окно закрывается само
            if greenSince == nil { greenSince = Date() }
            if let g = greenSince, Date().timeIntervalSince(g) >= 3 {
                onFinish()
            }
        } else {
            greenSince = nil
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
