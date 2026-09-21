import Foundation
import ApplicationServices
import AppKit

/// Проверка разрешения «Универсальный доступ» (Accessibility): без него тап
/// читает клавиши, но инжекция исправлений (CGEventPostToPid) не применяется —
/// «читает, но не исправляет».
///
/// prompt=true — macOS сам покажет системный диалог добавления приложения;
/// на части версий macOS в этом диалоге не видно списка приложений, поэтому
/// онбординг использует собственный алерт + открытие нужной панели Системных
/// настроек (как для «Мониторинга ввода»), а фоновые проверки зовут эту
/// функцию с prompt=false — никаких системных диалогов без спроса.
public func accessibilityTrusted(prompt: Bool) -> Bool {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(opts)
}

/// Панели «Конфиденциальность и безопасность» Системных настроек.
public enum PermissionPanels {
    public static let inputMonitoring =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_InputMonitoring")!
    public static let accessibility =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
}
