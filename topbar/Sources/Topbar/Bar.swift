import Cocoa

final class Bar {
    static let shared = Bar()
    let menuView = MenuView()
    lazy var menuPanel = makePanel(menuView)
    var drops: [(panel: Panel, view: DropView)] = []
    var items: [MenuItem] = []
    var visible = false
    var open = -1
    weak var screen: NSScreen?
    let me = ProcessInfo.processInfo.processIdentifier

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [unowned self] _ in
            if visible { hide() }
        }
        // Clique fora da topbar fecha.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [unowned self] _ in
            if visible { hide() }
        }
    }

    func toggle() {
        visible ? hide() : show()
    }

    func show() {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != me, let s = mouseScreen() else { return }
        items = menus(pid: app.processIdentifier)
        screen = s
        menuPanel.setFrame(menuView.frame(items: items, screen: s), display: false)
        menuView.hot = items.isEmpty ? -1 : 0
        menuView.display()
        menuPanel.orderFrontRegardless()
        visible = true
        open = -1
    }

    func hide() {
        closeDrops(from: 0)
        menuPanel.orderOut(nil)
        menuView.hot = -1
        visible = false
    }

    func drop(_ level: Int) -> (panel: Panel, view: DropView) {
        while drops.count <= level {
            let v = DropView()
            let p = makePanel(v)
            drops.append((p, v))
        }
        return drops[level]
    }

    var depth: Int {
        drops.lastIndex(where: { $0.panel.isVisible }) ?? -1
    }

    func showDrop(_ level: Int, _ list: [MenuEntry], x: CGFloat, top: CGFloat, flipX: CGFloat? = nil, select: Bool) {
        closeDrops(from: level)
        guard !list.isEmpty, let s = screen ?? mouseScreen() else { return }
        let d = drop(level)
        d.view.items = list
        let sz = d.view.fit()
        if select { d.view.hot = d.view.next(from: -1, 1) }
        let f = s.frame
        var ox = x
        if ox + sz.width > f.maxX { ox = flipX.map { $0 - sz.width } ?? (f.maxX - sz.width) }
        ox = max(f.minX, ox)
        let oy = max(f.minY, top - sz.height)
        d.panel.setFrame(NSRect(x: ox, y: oy, width: sz.width, height: sz.height), display: false)
        d.view.display()
        d.panel.orderFrontRegardless()
    }

    func closeDrops(from level: Int) {
        for i in level..<max(level, drops.count) {
            drops[i].panel.orderOut(nil)
            drops[i].view.items = []
        }
        if level == 0 { open = -1 }
    }

    func openMenu(_ i: Int, select: Bool) {
        guard i >= 0, i < items.count else { return }
        menuView.hot = i
        menuView.displayIfNeeded()
        let r = menuView.itemRect(i)
        showDrop(0, entries(of: items[i].el), x: menuPanel.frame.minX + r.minX, top: menuPanel.frame.minY + 1, select: select)
        open = i
    }

    func hoverDrop(_ level: Int, _ i: Int, select: Bool) {
        guard level < drops.count else { return }
        let d = drops[level]
        guard i >= 0, i < d.view.items.count, d.view.items[i].submenu else { closeDrops(from: level + 1); return }
        let f = d.panel.frame
        showDrop(level + 1, entries(of: d.view.items[i].el), x: f.maxX - 1, top: f.maxY - d.view.rowTop(i) + d.view.pad,
                 flipX: f.minX + 1, select: select)
    }

    func pick(_ level: Int, _ i: Int) {
        guard level >= 0, level < drops.count, i >= 0, i < drops[level].view.items.count else { return }
        let it = drops[level].view.items[i]
        if it.submenu { hoverDrop(level, i, select: true); return }
        hide()
        DispatchQueue.main.async { AXUIElementPerformAction(it.el, kAXPressAction as CFString) }
    }

    func step(_ d: Int) {
        let n = items.count
        guard n > 0 else { return }
        let reopen = depth >= 0
        let h = ((max(menuView.hot, 0) + d) % n + n) % n
        menuView.hot = h
        if reopen { openMenu(h, select: true) }
    }

    func key(_ k: Int64) -> Bool {
        guard visible else { return false }
        let lv = depth
        switch k {
        case 53:
            if lv > 0 { closeDrops(from: lv) } else if lv == 0 { closeDrops(from: 0) } else { hide() }
        case 123:
            if lv > 0 { closeDrops(from: lv) } else { step(-1) }
        case 124:
            if lv >= 0, let h = Optional(drops[lv].view.hot), h >= 0, drops[lv].view.items[h].submenu {
                hoverDrop(lv, h, select: true)
            } else {
                step(1)
            }
        case 125, 126:
            if lv < 0 { openMenu(menuView.hot, select: true); return true }
            let v = drops[lv].view
            v.hot = v.next(from: v.hot, k == 125 ? 1 : -1)
            closeDrops(from: lv + 1)
        case 36, 76, 49:
            if lv < 0 { openMenu(menuView.hot, select: true) } else { pick(lv, drops[lv].view.hot) }
        default:
            return false
        }
        return true
    }
}
