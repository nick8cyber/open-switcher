import Foundation
import ApplicationServices
import AppKit
import Carbon.HIToolbox

/// Детект «в фокусе поле пароля» (SecureEventInput + AXSecureTextField) и
/// безопасное чтение текста/каретки через Accessibility API.
///
/// Системный `IsSecureEventInputEnabled()` потокобезопасен и мгновенен (ноль лага
/// таймера при фокусе парольного поля), а AX-опрос на main каждые 0.25 с дополняет
/// его для веб-форм в браузерах/Electron, где SecureEventInput может не включаться.
public enum PasswordGuard {
    private static let lock = NSLock()
    private static var checkedAt: TimeInterval = 0
    private static var lastActivityAt: TimeInterval = 0
    private static var secure = false
    private static let ttl: TimeInterval = 0.60

    public static func notifyActivity() {
        let now = Engine.ms()
        lock.lock()
        lastActivityAt = now
        lock.unlock()
    }

    /// Мгновенная проверка с любого потока: системный Secure Input ИЛИ AX-кэш.
    public static var isSecureFocused: Bool {
        if IsSecureEventInputEnabled() { return true }
        lock.lock()
        defer { lock.unlock() }
        return secure
    }

    /// Текст сфокусированного элемента (вызывать только с main).
    public static func focusedText() -> String? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let el = focusedElementOnMain() else { return nil }
        return readTextElementAndValue(el)?.text
    }

    /// Текст фокусного элемента + точная позиция каретки (в UTF-16-единицах).
    /// Вызывать только с main.
    /// Возвращает `hasSelection = true`, если выделен непустой диапазон (тогда
    /// забой-стирание по памяти недопустимо). Если каретка не читается — `caret = nil`.
    public static func focusedTextAndCaret() -> (text: String, caret: Int?, hasSelection: Bool)? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let axEl = focusedElementOnMain(),
              let (targetEl, text) = readTextElementAndValue(axEl),
              !text.isEmpty else { return nil }

        var caret: Int? = nil
        var hasSel = false
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(targetEl, kAXSelectedTextRangeAttribute as CFString,
                                         &rangeRef) == .success,
           let ref = rangeRef, CFGetTypeID(ref) == AXValueGetTypeID() {
            var r = CFRange()
            if AXValueGetValue(ref as! AXValue, .cfRange, &r), r.location >= 0 {
                hasSel = r.length > 0
                caret = r.location + r.length
            }
        }
        return (text, caret, hasSel)
    }

    /// Выделенный текст фокусного элемента (AXSelectedText). nil — атрибут недоступен.
    /// Вызывать только с main.
    public static func selectedText() -> String? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let axEl = focusedElementOnMain() else { return nil }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(axEl, kAXSelectedTextAttribute as CFString,
                                         &value) == .success,
           let s = value as? String {
            return s
        }
        if let (childEl, _) = readTextElementAndValue(axEl), childEl !== axEl {
            var cval: CFTypeRef?
            if AXUIElementCopyAttributeValue(childEl, kAXSelectedTextAttribute as CFString,
                                             &cval) == .success,
               let cs = cval as? String {
                return cs
            }
        }
        return nil
    }

    private static func focusedElementOnMain() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.05) // не вешать main на занятом Electron
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let el = focused else { return nil }
        let axEl = el as! AXUIElement
        AXUIElementSetMessagingTimeout(axEl, 0.05)
        return axEl
    }

    /// Находит реальный текстовый AXUIElement и его строковое значение (с фолбэком
    /// на первый текстовый потомок, чтобы и текст, и SelectedTextRange читались
    /// у ОДНОГО и того же элемента).
    private static func readTextElementAndValue(_ axEl: AXUIElement) -> (element: AXUIElement, text: String)? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(axEl, kAXValueAttribute as CFString,
                                         &value) == .success,
           let v = value as? String {
            return (axEl, v)
        }
        var kids: CFTypeRef?
        if AXUIElementCopyAttributeValue(axEl, kAXChildrenAttribute as CFString,
                                         &kids) == .success,
           let arr = kids as? [AXUIElement] {
            for child in arr.prefix(8) {
                AXUIElementSetMessagingTimeout(child, 0.04)
                var role: CFTypeRef?
                var cv: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role) == .success,
                   let rs = role as? String, rs == "AXTextArea" || rs == "AXTextField",
                   AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &cv) == .success,
                   let cs = cv as? String {
                    return (child, cs)
                }
            }
        }
        return nil
    }

    /// Периодическое обновление AX-флага поля пароля (вызывать только с main).
    /// В простое (нет ввода > 3 с) не тратит ~90 AX IPC вызовов/сек (P1-9).
    public static func refreshOnMain() {
        dispatchPrecondition(condition: .onQueue(.main))
        let now = Engine.ms()
        lock.lock()
        let active = (now - lastActivityAt) < 3.0
        if !active || now - checkedAt < ttl { lock.unlock(); return }
        checkedAt = now
        lock.unlock()

        let result = checkSecureAx()
        lock.lock()
        secure = result
        lock.unlock()
    }

    /// Принудительный немедленный пересчёт на main (при смене фокуса/приложения).
    public static func forceRefreshOnMain() {
        dispatchPrecondition(condition: .onQueue(.main))
        let now = Engine.ms()
        let result = checkSecureAx()
        lock.lock()
        checkedAt = now
        lastActivityAt = now
        secure = result
        lock.unlock()
    }

    /// Проверка поля пароля, независимая от языка интерфейса macOS и движка браузера:
    /// 1) системный `IsSecureEventInputEnabled()`
    /// 2) стандартный `AXSubrole == "AXSecureTextField"` (AppKit, Safari, Chromium, Electron, Firefox)
    /// 3) `AXRoleDescription` ("secure" / "защищ")
    /// 4) нативный `AXTextField` со скрытым `AXNumberOfCharacters`.
    private static func checkSecureAx() -> Bool {
        if IsSecureEventInputEnabled() { return true }
        guard let axEl = focusedElementOnMain() else { return false }
        if isElementSecure(axEl) { return true }

        var kids: CFTypeRef?
        if AXUIElementCopyAttributeValue(axEl, kAXChildrenAttribute as CFString,
                                         &kids) == .success,
           let arr = kids as? [AXUIElement] {
            for child in arr.prefix(4) {
                AXUIElementSetMessagingTimeout(child, 0.03)
                if isElementSecure(child) { return true }
            }
        }
        return false
    }

    private static func isElementSecure(_ axEl: AXUIElement) -> Bool {
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(axEl, kAXSubroleAttribute as CFString,
                                         &subrole) == .success,
           let sr = subrole as? String,
           sr == (kAXSecureTextFieldSubrole as String) || sr.lowercased().contains("secure") {
            return true
        }
        var roleDesc: CFTypeRef?
        if AXUIElementCopyAttributeValue(axEl, kAXRoleDescriptionAttribute as CFString,
                                         &roleDesc) == .success,
           let rd = (roleDesc as? String)?.lowercased(),
           rd.contains("secure") || rd.contains("защищ") || rd.contains("парол") {
            return true
        }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axEl, kAXRoleAttribute as CFString,
                                            &role) == .success,
              let r = role as? String else { return false }
        return r == "AXSecureTextField"
    }
}
