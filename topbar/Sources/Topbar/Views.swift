import Cocoa

func hex(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

enum Theme {
    static let bg = hex(0x282828)
    static let bg1 = hex(0x3C3836)
    static let bg2 = hex(0x504945)
    static let fg = hex(0xEBDBB2)
    static let fgDim = hex(0xA89984)
    static let gray = hex(0x928374)
    static let yellow = hex(0xFABD2F)
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
    static let truncate: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return p
    }()
}

final class Panel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

func makePanel(_ view: NSView) -> Panel {
    let p = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.level = .popUpMenu
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    p.backgroundColor = Theme.bg
    p.isOpaque = true
    p.hasShadow = false
    p.animationBehavior = .none
    p.hidesOnDeactivate = false
    p.acceptsMouseMovedEvents = true
    p.contentView = view
    return p
}

/// Borda de 1 px desenhada por cima de tudo, para nenhum destaque cobri-la.
func strokeBorder(_ b: NSRect) {
    Theme.bg2.setStroke()
    let border = NSBezierPath(rect: b.insetBy(dx: 0.5, dy: 0.5))
    border.lineWidth = 1
    border.stroke()
}

/// View que recebe movimento do mouse e clique mesmo sem foco.
class MouseView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    func point(_ e: NSEvent) -> NSPoint { convert(e.locationInWindow, from: nil) }
}

final class MenuView: MouseView {
    var hot = -1 { didSet { if hot != oldValue { needsDisplay = true } } }
    private var labels: [String] = []
    private var rects: [NSRect] = []
    let height: CGFloat = 26
    let cell: CGFloat = 12
    let margin: CGFloat = 6

    override var isFlipped: Bool { true }

    private let appAttrs: [NSAttributedString.Key: Any] = [.font: Theme.mono(13, .bold), .foregroundColor: Theme.yellow]
    private let itemAttrs: [NSAttributedString.Key: Any] = [.font: Theme.mono(13), .foregroundColor: Theme.fg]
    private let hotAttrs: [NSAttributedString.Key: Any] = [.font: Theme.mono(13), .foregroundColor: NSColor.black]

    func frame(items: [MenuItem], screen s: NSScreen) -> NSRect {
        let f = s.frame
        labels = items.map(\.title)
        hot = -1
        var x: CGFloat = 0
        rects = labels.enumerated().map { i, t in
            let w = (t as NSString).size(withAttributes: i == 0 ? appAttrs : itemAttrs).width.rounded(.up) + cell * 2
            defer { x += w }
            return NSRect(x: x, y: 0, width: w, height: height)
        }
        let width = min(x, f.width)
        var mid = f.midX
        if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea { mid = f.minX + (l.maxX + r.minX) / 2 }
        let ox = min(max(f.minX, (mid - width / 2).rounded()), f.maxX - width)
        return NSRect(x: ox, y: f.maxY - s.safeAreaInsets.top - margin - height, width: width, height: height)
    }

    func itemRect(_ i: Int) -> NSRect { i < rects.count ? rects[i] : .zero }

    private func index(_ e: NSEvent) -> Int? { rects.firstIndex { $0.contains(point(e)) } }

    // Mouse: clique abre ou fecha o menu; com um menu aberto, passar o mouse troca de menu.
    override func mouseMoved(with e: NSEvent) {
        guard let i = index(e), i != hot else { return }
        if Bar.shared.depth >= 0 { Bar.shared.openMenu(i, select: false) } else { hot = i }
    }

    override func mouseDown(with e: NSEvent) {
        guard let i = index(e) else { return }
        if Bar.shared.open == i { Bar.shared.closeDrops(from: 0) } else { Bar.shared.openMenu(i, select: false) }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.bg.setFill()
        bounds.fill()
        let ty = ((height - 16) / 2).rounded()
        let inside = bounds.insetBy(dx: 2, dy: 2)
        for (i, (t, r)) in zip(labels, rects).enumerated() {
            let on = i == hot
            if on {
                Theme.yellow.setFill()
                r.insetBy(dx: 1, dy: 0).intersection(inside).fill()
            }
            (t as NSString).draw(at: NSPoint(x: r.minX + cell, y: ty), withAttributes: on ? hotAttrs : (i == 0 ? appAttrs : itemAttrs))
        }
        strokeBorder(bounds)
    }
}

final class DropView: MouseView {
    var items: [MenuEntry] = []
    var hot = -1 { didSet { if hot != oldValue { needsDisplay = true } } }
    private var rows: [NSRect] = []
    let rowH: CGFloat = 24
    let sepH: CGFloat = 9
    let pad: CGFloat = 4
    let cell: CGFloat = 12

    override var isFlipped: Bool { true }

    private let font = Theme.mono(13)

    func fit() -> NSSize {
        hot = -1
        var tw: CGFloat = 120
        var sw: CGFloat = 0
        for it in items {
            tw = max(tw, (it.title as NSString).size(withAttributes: [.font: font]).width.rounded(.up))
            sw = max(sw, ((it.submenu ? "▸" : it.shortcut) as NSString).size(withAttributes: [.font: font]).width.rounded(.up))
        }
        let width = min(cell * 2 + tw + (sw > 0 ? 32 + sw : 0), 560)
        var y = pad
        rows = items.map { it in
            let h = it.separator ? sepH : rowH
            defer { y += h }
            return NSRect(x: pad, y: y, width: width - pad * 2, height: h)
        }
        return NSSize(width: width, height: y + pad)
    }

    func rowTop(_ i: Int) -> CGFloat { i < rows.count ? rows[i].minY : 0 }

    private var level: Int { Bar.shared.drops.firstIndex { $0.view === self } ?? -1 }

    private func index(_ e: NSEvent) -> Int? {
        guard let i = rows.firstIndex(where: { $0.contains(point(e)) }), !items[i].separator, items[i].enabled else { return nil }
        return i
    }

    // Mouse: passar destaca (e abre submenu), clicar escolhe.
    override func mouseMoved(with e: NSEvent) {
        guard let i = index(e), i != hot else { return }
        hot = i
        Bar.shared.hoverDrop(level, i, select: false)
    }

    override func mouseUp(with e: NSEvent) {
        guard let i = index(e) else { return }
        Bar.shared.pick(level, i)
    }

    func next(from i: Int, _ d: Int) -> Int {
        let n = items.count
        guard n > 0 else { return -1 }
        var j = i < 0 ? (d > 0 ? -1 : n) : i
        for _ in 0..<n {
            j = ((j + d) % n + n) % n
            if !items[j].separator && items[j].enabled { return j }
        }
        return i
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.bg.setFill()
        bounds.fill()
        defer { strokeBorder(bounds) }
        for (i, (it, r)) in zip(items, rows).enumerated() {
            if it.separator {
                Theme.bg2.setFill()
                NSRect(x: r.minX + cell, y: r.midY.rounded(), width: r.width - cell * 2, height: 1).fill()
                continue
            }
            let on = i == hot
            if on {
                Theme.yellow.setFill()
                r.fill()
            }
            let fg: NSColor = on ? .black : (it.enabled ? Theme.fg : Theme.gray)
            let dim: NSColor = on ? .black : Theme.fgDim
            let ty = r.minY + ((rowH - 16) / 2).rounded()
            let right = it.submenu ? "▸" : it.shortcut
            let rw = (right as NSString).size(withAttributes: [.font: font]).width
            (it.title as NSString).draw(
                with: NSRect(x: r.minX + cell, y: ty, width: r.width - cell * 2 - (rw > 0 ? rw + 16 : 0), height: 18),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [.font: font, .foregroundColor: fg])
            if !right.isEmpty {
                (right as NSString).draw(at: NSPoint(x: r.maxX - cell - rw, y: ty), withAttributes: [.font: font, .foregroundColor: dim])
            }
        }
    }
}

final class CoverView: NSView {
    static let radius: CGFloat = 18
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    // Faixa preta + "orelhas" côncavas nos cantos de baixo, para a tela abaixo parecer arredondada.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()
        let r = CoverView.radius
        let bar = bounds.height - r
        let path = NSBezierPath(rect: NSRect(x: 0, y: 0, width: bounds.width, height: bar))
        let left = NSBezierPath()
        left.move(to: NSPoint(x: 0, y: bar))
        left.line(to: NSPoint(x: r, y: bar))
        left.appendArc(withCenter: NSPoint(x: r, y: bar + r), radius: r, startAngle: 270, endAngle: 180, clockwise: true)
        left.close()
        let right = NSBezierPath()
        right.move(to: NSPoint(x: bounds.width, y: bar))
        right.line(to: NSPoint(x: bounds.width, y: bar + r))
        right.appendArc(withCenter: NSPoint(x: bounds.width - r, y: bar + r), radius: r, startAngle: 0, endAngle: 270, clockwise: true)
        right.close()
        path.append(left)
        path.append(right)
        NSColor.black.setFill()
        path.fill()
    }
}

// Tarja preta fixa no topo de cada tela (onde a barra de menu apareceria).
final class MenuBarCover {
    static let shared = MenuBarCover()
    private var panels: [Panel] = []

    func refresh() {
        let h = NSScreen.screens.first?.frame.maxY ?? 0
        let all = NSScreen.screens.map { s in
            (cg: CGRect(x: s.frame.minX, y: h - s.frame.maxY, width: s.frame.width, height: s.frame.height), s: s)
        }
        // Só telas sem outra tela encostada em cima (as que têm barra de menu visível).
        let tops = all.filter { a in !all.contains { $0.cg.contains(CGPoint(x: a.cg.midX, y: a.cg.minY - 1)) } }.map(\.s)
        while panels.count < tops.count {
            let p = makePanel(CoverView())
            p.level = .statusBar + 1
            p.backgroundColor = .clear
            p.isOpaque = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panels.append(p)
        }
        for (i, p) in panels.enumerated() {
            guard i < tops.count else { p.orderOut(nil); continue }
            let f = tops[i].frame
            let bar = max(tops[i].safeAreaInsets.top, NSStatusBar.system.thickness)
            let h = bar + CoverView.radius
            p.setFrame(NSRect(x: f.minX, y: f.maxY - h, width: f.width, height: h), display: true)
            p.orderFrontRegardless()
        }
    }
}

func mouseScreen() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
}
