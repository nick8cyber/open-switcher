import AppKit

/// Иконка и меню в строке меню (порт TrayService.cs): тот же градиентный
/// скруглённый квадрат со стрелками-переключателем.
public final class StatusItemService: NSObject {
    private let engine: Engine
    private var item: NSStatusItem?
    private var menu: NSMenu?

    public var settingsWindow: SettingsWindowController?

    public init(engine: Engine) {
        self.engine = engine
    }

    public func initItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.makeIcon()
        updateTooltip()
        let menu = NSMenu()
        // строка статуса (недоступна для клика)
        let miStatus = NSMenuItem(title: "Работает", action: nil, keyEquivalent: "")
        miStatus.representedObject = "status"
        menu.addItem(miStatus)
        menu.addItem(.separator())
        let miSettings = NSMenuItem(title: "Настройки", action: #selector(showSettings), keyEquivalent: "")
        miSettings.target = self
        let miRu = NSMenuItem(title: "→ РУС", action: #selector(switchRu), keyEquivalent: "")
        miRu.target = self
        let miEn = NSMenuItem(title: "→ ENG", action: #selector(switchEn), keyEquivalent: "")
        miEn.target = self
        let miPause = NSMenuItem(title: "Пауза", action: #selector(togglePause), keyEquivalent: "")
        miPause.target = self
        miPause.representedObject = "pause"
        let miLog = NSMenuItem(title: "Открыть журнал", action: #selector(openLog), keyEquivalent: "")
        miLog.target = self
        let miExit = NSMenuItem(title: "Выход", action: #selector(exitApp), keyEquivalent: "")
        miExit.target = self
        menu.addItem(miSettings)
        menu.addItem(miRu)
        menu.addItem(miEn)
        menu.addItem(miPause)
        menu.addItem(miLog)
        menu.addItem(.separator())
        menu.addItem(miExit)
        menu.delegate = self
        self.menu = menu

        // как в оригинале: левый клик — настройки, правый — меню
        item.button?.target = self
        item.button?.action = #selector(statusButtonClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        self.item = item

        engine.onSettingsApplied = { [weak self] in self?.updateTooltip() }
        engine.onConverted = { [weak self] old, new in
            guard let self = self, self.engine.s.showPopup else { return }
            ConvertPopup.show(near: self.engine.caretPoint(), old: old, new: new)
        }
        engine.onInfo = { [weak self] msg in
            guard let self = self, self.engine.s.showPopup else { return }
            ConvertPopup.show(near: self.engine.caretPoint(), old: msg, new: "")
        }
    }

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        guard let ev = NSApp.currentEvent else { showSettings(); return }
        if ev.type == .rightMouseUp || ev.type == .rightMouseDown {
            // стандартный трюк: временно назначаем меню и «кликаем» кнопку
            item?.menu = menu
            sender.performClick(nil)
            item?.menu = nil
        } else {
            showSettings()
        }
    }

    public func updateTooltip() {
        item?.button?.toolTip = "OpenSwitcher — " + (engine.s.paused ? "пауза" : "Ru ⇄ En")
        // окно настроек следит за этим уведомлением — синк карточки статуса
        NotificationCenter.default.post(name: Notification.Name("os.paused"), object: nil)
    }

    @objc private func switchRu() {
        engine.switchToLanguage(0)
    }

    @objc private func switchEn() {
        engine.switchToLanguage(1)
    }

    @objc private func openLog() {
        Engine.openInEditor(SettingsStore.dir + "/log.txt")
    }

    @objc private func togglePause() {
        engine.toggleAuto()
    }

    @objc private func exitApp() {
        NSApp.terminate(nil)
    }

    @objc public func showSettings() {
        if let w = settingsWindow {
            w.show()
            return
        }
        let w = SettingsWindowController(engine: engine)
        w.onClose = { [weak self] in self?.settingsWindow = nil }
        settingsWindow = w
        w.show()
    }

    /// Иконка: градиент accent → #7C5CFF, белые стрелки-переключатель (порт MakeIcon).
    static func makeIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            let rect = CGRect(x: 0.5, y: 0.5, width: 17, height: 17)
            let path = CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil)
            let colors = [UiTheme.shared.accent.cgColor, UiTheme.hex("#7C5CFF").cgColor]
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors as CFArray, locations: [0, 1]) {
                ctx.saveGState()
                ctx.addPath(path)
                ctx.clip()
                // 70°-градиент: диагональ
                ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: rect.height),
                                       end: CGPoint(x: rect.width, y: 0), options: [])
                ctx.restoreGState()
            }
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.6)
            ctx.setLineCap(.round)
            // верхняя стрелка →
            ctx.move(to: CGPoint(x: 4.5, y: 11))
            ctx.addLine(to: CGPoint(x: 12.5, y: 11))
            ctx.addLine(to: CGPoint(x: 10, y: 13.5))
            ctx.move(to: CGPoint(x: 12.5, y: 11))
            ctx.addLine(to: CGPoint(x: 10, y: 8.5))
            // нижняя стрелка ←
            ctx.move(to: CGPoint(x: 13.5, y: 7))
            ctx.addLine(to: CGPoint(x: 5.5, y: 7))
            ctx.addLine(to: CGPoint(x: 8, y: 4.5))
            ctx.move(to: CGPoint(x: 5.5, y: 7))
            ctx.addLine(to: CGPoint(x: 8, y: 9.5))
            ctx.strokePath()
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

extension StatusItemService: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        for mi in menu.items {
            if mi.representedObject as? String == "pause" {
                mi.title = engine.s.paused ? "Продолжить" : "Пауза"
            } else if mi.representedObject as? String == "status" {
                mi.title = engine.s.paused ? "На паузе" : "Работает"
            }
        }
    }
}
