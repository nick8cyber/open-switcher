import Foundation
import ApplicationServices
import AppKit

/// Проверка разрешения «Универсальный доступ» (Accessibility): без него тап
/// читает клавиши, но инжекция исправлений (CGEventPostToPid) не применяется —
/// «читает, но не исправляет».
///
/// prompt=true — macOS сам покажет системный диалог добавления приложения;
/// на части версий macOS в этом диалоге не видно списка приложений, поэтому
/// онбординг-окно открывает нужную панель Системных настроек само, а фоновые
/// проверки зовут эту функцию с prompt=false — никаких системных диалогов
/// без спроса.
public func accessibilityTrusted(prompt: Bool) -> Bool {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(opts)
}

/// Обёртки нового API macOS 12+ для разрешения «Мониторинг ввода»
/// (ListenEvent): без него тап не получает клавиши. В отличие от «Универсального
/// доступа» приложение НЕ попадает в список Мониторинга само — только если
/// вызвать CGRequestListenEventAccess: система сама добавит приложение в список
/// и покажет тумблер юзеру.
///
/// Функции чистые (CoreGraphics/ApplicationServices), но вызывать только с main:
/// системные проверки/запросы прав контекстно-зависимы и недостоверны с фона.
public enum Permissions {
    /// Preflight «Мониторинг ввода»: право уже выдано?
    public static func listenEventGranted() -> Bool { CGPreflightListenEventAccess() }
    /// Запрос «Мониторинга ввода»: система добавит приложение в список сама.
    public static func requestListenEventAccess() { CGRequestListenEventAccess() }
    /// Preflight права на инжекцию событий (PostEvent).
    public static func postEventGranted() -> Bool { CGPreflightPostEventAccess() }
}

/// Панели «Конфиденциальность и безопасность» Системных настроек.
public enum PermissionPanels {
    public static let inputMonitoring =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_InputMonitoring")!
    public static let accessibility =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
}
