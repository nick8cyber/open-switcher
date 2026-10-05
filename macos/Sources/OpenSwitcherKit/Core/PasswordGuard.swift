import Foundation
import ApplicationServices
import AppKit

/// Детект «в фокусе поле пароля» (AXSecureTextField). Конвертация в пароле
/// ломает ввод: буквы невидимы, флип раскладки посреди набора фатален —
/// поэтому в secure-поле авто-конвертация не ходит вовсе (лок/гейты ни при чём).
///
/// AX-запрос дорогой и допустим только с main (тред-безопасность AX как у TIS):
/// main-таймер 0.25 с обновляет кэш, поток тапа читает готовый флаг
/// (та же схема, что LayoutService.cache).
public enum PasswordGuard {
    private static let lock = NSLock()
    private static var checkedAt: TimeInterval = 0
    private static var secure = false
    private static let ttl: TimeInterval = 0.25

    /// Дёшево: из потока тапа — вернёт кэш последней main-проверки (свежесть ≤0.25 с;
    /// конвертация стреляет на конце слова — к этому моменту кэш успевает обновиться).
    public static var isSecureFocused: Bool {
        lock.lock(); defer { lock.unlock() }
        return secure
    }

    /// Единственная точка AX-опроса. Зывать только с main.
    public static func refreshOnMain() {
        lock.lock()
        if Engine.ms() - checkedAt < ttl { lock.unlock(); return }
        checkedAt = Engine.ms()
        lock.unlock()

        let result = checkSecureAx()
        lock.lock(); secure = result; lock.unlock()
    }

    /// Поле пароля? Проверено на живом NSSecureTextField: роль у него обычная
    /// (AXTextField), маркеры два — RoleDescription содержит "secure" и/или
    /// AXNumberOfCharacters не читается (у обычного поля читается всегда).
    /// Ложное «да» глушит конвертацию зря, поэтому сигнал составной.
    private static func checkSecureAx() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let el = focused else { return false }
        let axEl = el as! AXUIElement
        var roleDesc: CFTypeRef?
        if AXUIElementCopyAttributeValue(axEl, kAXRoleDescriptionAttribute as CFString,
                                         &roleDesc) == .success,
           let rd = roleDesc as? String, rd.lowercased().contains("secure") {
            return true
        }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axEl, kAXRoleAttribute as CFString,
                                            &role) == .success,
              (role as? String) == "AXTextField" else { return false }
        var nchars: CFTypeRef?
        return AXUIElementCopyAttributeValue(axEl, kAXNumberOfCharactersAttribute as CFString,
                                             &nchars) != .success
    }
}
