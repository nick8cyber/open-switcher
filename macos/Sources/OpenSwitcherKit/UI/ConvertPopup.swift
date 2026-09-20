import AppKit

/// Небольшая неберущая-фокус подсказка возле каретки: «ghbdtn → привет»
/// (порт ConvertPopup.cs). NSPanel + nonactivating, 1400 мс + фейд 300 мс.
public final class ConvertPopup: NSPanel {
    private let oldText: String
    private let newText: String
    private let isInfo: Bool
    private var age: Double = 0
    private let step: TimeInterval = 0.04
    private var timer: Timer?

    /// Единственный видимый попап: новый заменяет предыдущий (без накопления окон).
    private static var current: ConvertPopup?

    static func show(near point: NSPoint, old: String, new: String) {
        current?.closeQuietly()
        let p = ConvertPopup(old: old, new: new)
        current = p
        p.present(near: point)
    }

    init(old: String, new: String) {
        self.oldText = old
        self.newText = new
        self.isInfo = new.isEmpty
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        let view = PopupView(old: old, new: new, isInfo: isInfo)
        view.wantsLayer = true
        view.layer?.shadowRadius = 14
        view.layer?.shadowOffset = NSSize(width: 0, height: 4)
        view.layer?.shadowOpacity = 0.25
        contentView = view
    }

    /// Мгновенно убрать (когда пришёл следующий попап).
    func closeQuietly() {
        timer?.invalidate()
        timer = nil
        close()
    }

    func present(near point: NSPoint) {
        guard let content = contentView else { return }
        let size = ((content as? PopupView).map { $0.measureSize() } ?? content.fittingSize)
        setContentSize(size)
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = point.x + 10
        var y = point.y - size.height - 6
        if x + size.width > visible.maxX - 8 { x = visible.maxX - 8 - size.width }
        if x < visible.minX + 8 { x = visible.minX + 8 }
        if y < visible.minY + 8 { y = point.y + 10 }
        if y + size.height > visible.maxY - 8 { y = visible.maxY - 8 - size.height }
        setFrameOrigin(NSPoint(x: x, y: y))
        alphaValue = 1
        orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: step, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.age += self.step
            if self.age < 1.4 { return }
            let fade = (self.age - 1.4) / 0.3
            if fade >= 1 {
                self.timer?.invalidate()
                self.close()  // окно уходит из NSApp.windows, а не только с экрана
                if ConvertPopup.current === self { ConvertPopup.current = nil }
                return
            }
            self.alphaValue = 1 - fade
        }
    }

    private final class PopupView: NSView {
        let old: String, new: String, isInfo: Bool

        init(old: String, new: String, isInfo: Bool) {
            self.old = old; self.new = new; self.isInfo = isInfo
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        static func trunc(_ s: String) -> String {
            s.count > 26 ? String(s.prefix(25)) + "…" : s
        }

        func measureSize() -> NSSize {
            let fOld = NSFont.systemFont(ofSize: 13)
            let fNew = NSFont.boldSystemFont(ofSize: 13)
            let pad: CGFloat = 14
            var w: CGFloat
            if isInfo {
                w = (old as NSString).size(withAttributes: [.font: fOld]).width + pad * 2
            } else {
                let o = Self.trunc(old), n = Self.trunc(new)
                w = (o as NSString).size(withAttributes: [.font: fOld]).width
                    + ("  →  " as NSString).size(withAttributes: [.font: fOld]).width
                    + (n as NSString).size(withAttributes: [.font: fNew]).width + pad * 2
            }
            let h: CGFloat = (NSFont.boldSystemFont(ofSize: 13)).boundingRectForFont.height + 18
            return NSSize(width: max(w, 120), height: max(h, 34))
        }

        override func draw(_ dirtyRect: NSRect) {
            let t = UiTheme.shared
            let r = NSRect(x: 0.5, y: 0.5, width: bounds.width - 1, height: bounds.height - 1)
            let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
            t.card.setFill()
            path.fill()
            t.cardBorder.setStroke()
            path.lineWidth = 1
            path.stroke()

            let fOld = NSFont.systemFont(ofSize: 13)
            let fNew = NSFont.boldSystemFont(ofSize: 13)
            let pad: CGFloat = 14
            let cy = bounds.midY
            if isInfo {
                let attr: [NSAttributedString.Key: Any] = [.font: fOld, .foregroundColor: t.dim]
                let size = (old as NSString).size(withAttributes: attr)
                (old as NSString).draw(at: NSPoint(x: pad, y: cy - size.height / 2), withAttributes: attr)
                return
            }
            let o = Self.trunc(old), n = Self.trunc(new)
            let aOld: [NSAttributedString.Key: Any] = [.font: fOld, .foregroundColor: t.dim]
            let aArrow: [NSAttributedString.Key: Any] = [.font: fOld, .foregroundColor: t.dim]
            let aNew: [NSAttributedString.Key: Any] = [.font: fNew, .foregroundColor: t.accent]
            var x = pad
            let so = (o as NSString).size(withAttributes: aOld)
            (o as NSString).draw(at: NSPoint(x: x, y: cy - so.height / 2), withAttributes: aOld)
            x += so.width
            let sa = ("  →  " as NSString).size(withAttributes: aArrow)
            ("  →  " as NSString).draw(at: NSPoint(x: x, y: cy - sa.height / 2), withAttributes: aArrow)
            x += sa.width
            let sn = (n as NSString).size(withAttributes: aNew)
            (n as NSString).draw(at: NSPoint(x: x, y: cy - sn.height / 2), withAttributes: aNew)
        }
    }
}
