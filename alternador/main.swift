import Cocoa
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("GetProcessForPID")
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

typealias SetFrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
typealias PostRecordFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
typealias HotKeyFn = @convention(c) (Int32, Bool) -> CGError

let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)

func loadSym<T>(_ names: [String], _ type: T.Type) -> T? {
    for n in names {
        if let p = dlsym(defaultHandle, n) ?? dlsym(skyLight, n) { return unsafeBitCast(p, to: type) }
    }
    return nil
}

let setFront = loadSym(["_SLPSSetFrontProcessWithOptions"], SetFrontFn.self)
let postRecord = loadSym(["SLPSPostEventRecordTo"], PostRecordFn.self)
let setHotKey = loadSym(["CGSSetSymbolicHotKeyEnabled", "SLSSetSymbolicHotKeyEnabled"], HotKeyFn.self)

typealias DockNotifyFn = @convention(c) (CFString, Int32) -> Void
let dockNotify = loadSym(["CoreDockSendNotification"], DockNotifyFn.self)

// "Mostrar Mesa" do macOS: afasta todas as janelas.
func showDesktop() {
    dockNotify?("com.apple.showdesktop.awake" as CFString, 0)
}

func nativeSwitcher(_ enabled: Bool) {
    _ = setHotKey?(1, enabled)
    _ = setHotKey?(2, enabled)
    // Ctrl+← / Ctrl+→ nativos (mudar de mesa): desligados; o alternador liga só para andar até outro space.
    _ = setHotKey?(79, enabled)
    _ = setHotKey?(81, enabled)
}

struct Win {
    let el: AXUIElement
    let id: CGWindowID
    let pid: pid_t
    var title: String
    let appName: String
    var icon: NSImage?
    var minimized: Bool
    let appHidden: Bool
    // Abas do Safari: cada aba vira um item próprio no Cmd+Tab (mesma janela, `tab` diferente).
    var tab: AXUIElement? = nil
    var tabCount = 1
    var safari = false
    var fullscreen = false
    var otherSpace = false  // está em outro space do macOS (ex.: vídeo em tela cheia)
    var pageTitle = ""      // tela cheia de vídeo: título da página de onde ela veio
    var pair: String? = nil // tela cheia e a janela/aba de origem têm o mesmo valor
    var disabled = false    // aba de origem de uma tela cheia: aparece, mas não é escolhida
}

// Tela cheia de vídeo no Safari: janela sem título; o título da página está na área web.
func webAreaTitle(_ el: AXUIElement, depth: Int = 0) -> String? {
    if axAttr(el, kAXRoleAttribute) as? String == "AXWebArea" {
        return (axAttr(el, kAXDescriptionAttribute) as? String) ?? (axAttr(el, kAXTitleAttribute) as? String)
    }
    guard depth < 4 else { return nil }
    for c in (axAttr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        if let t = webAreaTitle(c, depth: depth + 1) { return t }
    }
    return nil
}

let safariID = "com.apple.Safari"

// "(3) WhatsApp" → "WhatsApp": contadores no título mudam sem a aba mudar.
func normTitle(_ s: String) -> String {
    guard s.hasPrefix("("), let r = s.range(of: ") ") else { return s }
    let n = s[s.index(after: s.startIndex)..<r.lowerBound]
    return !n.isEmpty && n.allSatisfy(\.isNumber) ? String(s[r.upperBound...]) : s
}

// Chave de uso recente: janela, ou janela + aba no Safari (o título da janela é o da aba ativa).
func itemKey(_ id: CGWindowID, _ title: String, safari: Bool) -> String {
    safari ? "\(id)|\(normTitle(title))" : "\(id)"
}

func axAttr(_ el: AXUIElement, _ n: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, n as CFString, &v) == .success ? v : nil
}

// Botões da barra de abas do Safari (vazio se a barra estiver oculta, com uma aba só).
func safariTabs(_ el: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    if axAttr(el, kAXSubroleAttribute) as? String == "AXTabButton" { return [el] }
    let role = axAttr(el, kAXRoleAttribute) as? String ?? ""
    if depth > 5 || role == "AXTabGroup" || role == "AXWebArea" || role == "AXScrollArea" { return [] }
    return ((axAttr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []).flatMap { safariTabs($0, depth: depth + 1) }
}

func closeTab(_ t: AXUIElement) -> Bool {
    var names: CFArray?
    AXUIElementCopyActionNames(t, &names)
    guard let a = (names as? [String])?.first(where: { $0.contains("_closeButtonClicked") }) else { return false }
    return AXUIElementPerformAction(t, a as CFString) == .success
}

func pressMenu(_ pid: pid_t, _ identifier: String) -> Bool {
    let ax = AXUIElementCreateApplication(pid)
    guard let bar = axAttr(ax, kAXMenuBarAttribute) else { return false }
    for top in (axAttr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        for menu in (axAttr(top, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            for item in (axAttr(menu, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            where axAttr(item, "AXIdentifier") as? String == identifier {
                return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
            }
        }
    }
    return false
}

// Favicons das abas: o endereço de cada aba vem do Safari (AppleScript), o ícone do próprio site.
final class Favicons {
    static let shared = Favicons()
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SuiteAlternador/favicons", isDirectory: true)
    var hostOf: [String: String] = [:]  // título normalizado → host
    var images: [String: NSImage] = [:]
    var missing: Set<String> = []
    var loading: Set<String> = []
    var refreshing = false
    let queue = DispatchQueue(label: "favicons")
    var onChange: (() -> Void)?

    var upgraded: Set<String> = []  // ícones antigos de baixa resolução já baixados de novo

    func icon(_ title: String) -> NSImage? {
        guard let h = hostOf[normTitle(title)] else { return nil }
        if let i = images[h] { return i }
        if missing.contains(h) { return nil }
        let file = dir.appendingPathComponent("\(h).png")
        if let img = NSImage(contentsOf: file) {
            images[h] = Self.tile(img)
            let px = img.representations.map(\.pixelsWide).max() ?? 0
            if px < 64, upgraded.insert(h).inserted { download(h) }
            return images[h]
        }
        download(h)
        return nil
    }

    static func tile(_ favicon: NSImage) -> NSImage {
        NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            let r = rect.insetBy(dx: 10, dy: 10)
            NSGraphicsContext.current?.imageInterpolation = .high
            NSColor.white.setFill()
            NSBezierPath(roundedRect: r, xRadius: 24, yRadius: 24).fill()
            favicon.draw(in: r.insetBy(dx: 18, dy: 18), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }

    func refresh() {
        guard !refreshing, !NSRunningApplication.runningApplications(withBundleIdentifier: safariID).isEmpty else { return }
        refreshing = true
        queue.async { [self] in
            let src = "tell application \"Safari\" to return {name of every tab of every window, URL of every tab of every window}"
            var err: NSDictionary?
            let d = NSAppleScript(source: src)?.executeAndReturnError(&err)
            func flat(_ d: NSAppleEventDescriptor?) -> [String] {
                guard let d else { return [] }
                if d.descriptorType == typeAEList {
                    return d.numberOfItems == 0 ? [] : (1...d.numberOfItems).flatMap { flat(d.atIndex($0)) }
                }
                return [d.stringValue ?? ""]
            }
            let names = flat(d?.atIndex(1)), urls = flat(d?.atIndex(2))
            var map: [String: String] = [:]
            for (n, u) in zip(names, urls) {
                if let h = URL(string: u)?.host, !n.isEmpty { map[normTitle(n)] = h }
            }
            DispatchQueue.main.async { [self] in
                refreshing = false
                guard !map.isEmpty else { return }
                let changed = map.contains { hostOf[$0.key] != $0.value }
                hostOf.merge(map) { $1 }
                if changed { onChange?() }
            }
        }
    }

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static func fetch(_ url: URL) -> (Data, URL)? {
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        var out: (Data, URL)?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let data, let r = resp as? HTTPURLResponse, r.statusCode == 200 { out = (data, r.url ?? url) }
            sem.signal()
        }.resume()
        sem.wait()
        return out
    }

    // Maior resolução do arquivo (um .ico traz várias; o NSImage usaria a menor ao salvar).
    static func largestRep(_ data: Data) -> NSBitmapImageRep? {
        guard let img = NSImage(data: data), img.isValid else { return nil }
        if let best = img.representations.compactMap({ $0 as? NSBitmapImageRep }).max(by: { $0.pixelsWide < $1.pixelsWide }) {
            return best
        }
        // SVG/PDF: desenha em 256 px.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    // Ícones que a página declara (<link rel="icon" sizes=...>), do maior para o menor,
    // e depois os endereços padrão.
    static func candidates(_ host: String) -> [URL] {
        var found: [(URL, Int)] = []
        if let (data, base) = fetch(URL(string: "https://\(host)/")!),
           let html = String(data: data.prefix(1_500_000), encoding: .utf8) ?? String(data: data.prefix(1_500_000), encoding: .isoLatin1) {
            let tag = try! NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive)
            let attr = try! NSRegularExpression(pattern: "([\\w-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")
            let ns = html as NSString
            for m in tag.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let t = ns.substring(with: m.range)
                var a: [String: String] = [:]
                for am in attr.matches(in: t, range: NSRange(location: 0, length: (t as NSString).length)) {
                    let k = (t as NSString).substring(with: am.range(at: 1)).lowercased()
                    let v = (2...4).compactMap { am.range(at: $0).location != NSNotFound ? (t as NSString).substring(with: am.range(at: $0)) : nil }.first ?? ""
                    a[k] = v
                }
                let rel = a["rel"]?.lowercased() ?? ""
                guard rel.contains("icon"), !rel.contains("mask"),
                      let href = a["href"]?.replacingOccurrences(of: "&amp;", with: "&"),
                      let url = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
                var size = rel.contains("apple-touch") ? 180 : 32
                if let s = a["sizes"], let n = Int(s.lowercased().split(separator: "x").first ?? "") { size = n }
                if url.pathExtension.lowercased() == "svg" { size = 100 }
                found.append((url, size))
            }
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
            + ["/apple-touch-icon.png", "/favicon.ico"].compactMap { URL(string: "https://\(host)\($0)") }
    }

    func download(_ host: String) {
        guard loading.insert(host).inserted else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            var best: NSBitmapImageRep?
            for url in Self.candidates(host) {
                guard let (data, _) = Self.fetch(url), let rep = Self.largestRep(data) else { continue }
                if rep.pixelsWide > (best?.pixelsWide ?? 0) { best = rep }
                if rep.pixelsWide >= 96 { break }
            }
            let png = best?.representation(using: .png, properties: [:])
            DispatchQueue.main.async { [self] in
                loading.remove(host)
                guard let best, let png else { if images[host] == nil { missing.insert(host) }; return }
                let file = dir.appendingPathComponent("\(host).png")
                let old = NSImage(contentsOf: file)?.representations.map(\.pixelsWide).max() ?? 0
                guard best.pixelsWide >= old else { return }
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? png.write(to: file)
                let img = NSImage(size: NSSize(width: best.pixelsWide, height: best.pixelsHigh))
                img.addRepresentation(best)
                images[host] = Self.tile(img)
                onChange?()
            }
        }
    }
}

func windows(pid: pid_t, appName: String, icon: NSImage?, hidden: Bool) -> [Win] {
    let ax = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(ax, 0.1)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &v) == .success,
          let list = v as? [AXUIElement] else { return [] }
    return list.compactMap { makeWin($0, pid: pid, appName: appName, icon: icon, hidden: hidden) }
}

func makeWin(_ w: AXUIElement, pid: pid_t, appName: String, icon: NSImage?, hidden: Bool) -> Win? {
    let attrs = [kAXSubroleAttribute, kAXTitleAttribute, kAXMinimizedAttribute, kAXCloseButtonAttribute, "AXFullScreen"] as CFArray
    var vals: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(w, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &vals) == .success,
          let a = vals as? [Any], a.count == 5 else { return nil }
    // Regra única: janela normal ou diálogo, com botão de fechar.
    let sub = a[0] as? String
    guard sub == kAXStandardWindowSubrole || sub == kAXDialogSubrole,
          CFGetTypeID(a[3] as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
    var id: CGWindowID = 0
    guard _AXUIElementGetWindow(w, &id) == .success, id != 0 else { return nil }
    var win = Win(el: w, id: id, pid: pid, title: a[1] as? String ?? "", appName: appName, icon: icon,
                  minimized: (a[2] as? Bool) ?? false, appHidden: hidden)
    win.fullscreen = (a[4] as? Bool) ?? false
    if win.fullscreen && win.title.isEmpty { win.pageTitle = webAreaTitle(w) ?? "" }
    return win
}

// MARK: spaces do macOS (o fullscreen de um app ou vídeo cria um space só dele)
// O Accessibility só lista janelas do space atual do macOS. Janelas de outros spaces são achadas
// pelo número da janela e alcançadas com o atalho do macOS de mudar de space.
typealias ConnFn = @convention(c) () -> Int32
typealias DisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
typealias WindowSpacesFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
typealias ActiveSpaceFn = @convention(c) (Int32) -> UInt64
typealias RemoteTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

let slsConn = loadSym(["SLSMainConnectionID", "CGSMainConnectionID"], ConnFn.self)?() ?? 0
let displaySpaces = loadSym(["SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces"], DisplaySpacesFn.self)
let windowSpaces = loadSym(["SLSCopySpacesForWindows", "CGSCopySpacesForWindows"], WindowSpacesFn.self)
let activeSpaceFn = loadSym(["SLSGetActiveSpace", "CGSGetActiveSpace"], ActiveSpaceFn.self)
let remoteToken = loadSym(["_AXUIElementCreateWithRemoteToken"], RemoteTokenFn.self)

func activeSpace() -> UInt64 { activeSpaceFn?(slsConn) ?? 0 }

func spaceOfWindow(_ id: CGWindowID) -> UInt64? {
    guard let f = windowSpaces, let a = f(slsConn, 0x7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber]
    else { return nil }
    return a.first?.uint64Value
}

// Spaces de cada monitor, na ordem em que o Ctrl+←/→ do macOS anda por eles.
func spacesByDisplay() -> [[UInt64]] {
    guard let f = displaySpaces, let ds = f(slsConn)?.takeRetainedValue() as? [[String: Any]] else { return [] }
    return ds.map { d in ((d["Spaces"] as? [[String: Any]]) ?? []).compactMap { ($0["id64"] as? NSNumber)?.uint64Value } }
}

// Acha o elemento de Accessibility de janelas que o app não lista (estão em outro space).
func remoteWindowElements(pid: pid_t, want: Set<CGWindowID>) -> [CGWindowID: AXUIElement] {
    guard let f = remoteToken, !want.isEmpty else { return [:] }
    var found: [CGWindowID: AXUIElement] = [:]
    var data = Data(count: 20)
    data.withUnsafeMutableBytes { b in
        b.storeBytes(of: pid, toByteOffset: 0, as: Int32.self)
        b.storeBytes(of: Int32(0x636f636f), toByteOffset: 8, as: Int32.self)
    }
    for eid in UInt64(0)..<100_000 {
        data.withUnsafeMutableBytes { $0.storeBytes(of: eid, toByteOffset: 12, as: UInt64.self) }
        guard let el = f(data as CFData)?.takeRetainedValue() else { continue }
        var id: CGWindowID = 0
        if _AXUIElementGetWindow(el, &id) == .success, want.contains(id) {
            found[id] = el
            if found.count == want.count { break }
        }
    }
    return found
}

let hopMarker: Int64 = 0x414C_5448  // marca os Ctrl+setas que o próprio alternador manda

// Anda até o space do macOS onde a janela está. Devolve false se ela já estiver no atual.
func hopToSpace(of id: CGWindowID) -> Bool {
    guard let target = spaceOfWindow(id) else { return false }
    let cur = activeSpace()
    guard target != cur, let list = spacesByDisplay().first(where: { $0.contains(target) }) else { return false }
    // Se o space atual for de outro monitor, conta a partir do space visível daquele monitor.
    guard let ti = list.firstIndex(of: target) else { return false }
    let from = list.firstIndex(of: cur) ?? currentIndex(in: list)
    guard let from, from != ti else { return false }
    let right = ti > from
    let hk: Int32 = right ? 81 : 79
    _ = setHotKey?(hk, true)
    let src = CGEventSource(stateID: .hidSystemState)
    for _ in 0..<abs(ti - from) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: right ? 124 : 123, keyDown: down) else { continue }
            e.flags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
            e.setIntegerValueField(.eventSourceUserData, value: hopMarker)
            e.post(tap: .cghidEventTap)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 + 0.3 * Double(abs(ti - from))) {
        if eventTap != nil { _ = setHotKey?(hk, false) }
    }
    return true
}

func currentIndex(in list: [UInt64]) -> Int? {
    guard let f = displaySpaces, let ds = f(slsConn)?.takeRetainedValue() as? [[String: Any]] else { return nil }
    for d in ds {
        if let c = ((d["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value, let i = list.firstIndex(of: c) { return i }
    }
    return nil
}

func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ wid: CGWindowID) {
    guard let post = postRecord else { return }
    var id = wid
    for kind: UInt8 in [1, 2] {
        var bytes = [UInt8](repeating: 0, count: 0xF8)
        bytes[0x04] = 0xF8
        bytes[0x08] = kind
        bytes[0x3A] = 0x10
        for i in 0x20..<0x30 { bytes[i] = 0xFF }
        withUnsafeBytes(of: &id) { for (i, b) in $0.enumerated() { bytes[0x3C + i] = b } }
        bytes.withUnsafeMutableBufferPointer { _ = post(&psn, $0.baseAddress!) }
    }
}

func focus(_ w: Win) {
    if let tab = w.tab { AXUIElementPerformAction(tab, kAXPressAction as CFString) }
    let app = NSRunningApplication(processIdentifier: w.pid)
    if app?.isHidden == true { app?.unhide() }
    if w.minimized { AXUIElementSetAttributeValue(w.el, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
    var psn = ProcessSerialNumber()
    if let f = setFront, GetProcessForPID(w.pid, &psn) == noErr {
        _ = f(&psn, w.id, 0x200)
        makeKeyWindow(&psn, w.id)
    } else {
        app?.activate(options: [])
    }
    AXUIElementSetAttributeValue(w.el, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(w.el, kAXRaiseAction as CFString)
}

func close(_ w: Win) {
    var b: CFTypeRef?
    if AXUIElementCopyAttributeValue(w.el, kAXCloseButtonAttribute as CFString, &b) == .success, let b {
        AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString)
    }
}

func setMinimized(_ w: Win, _ on: Bool) {
    AXUIElementSetAttributeValue(w.el, kAXMinimizedAttribute as CFString, on ? kCFBooleanTrue : kCFBooleanFalse)
}

final class Panel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

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
}

// Chip de space (topo do Cmd+Tab).
func drawChip(_ r: NSRect, _ label: String, current: Bool, occupied: Bool, hot: Bool, dashed: Bool, font: NSFont) {
    let box = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
    box.lineWidth = 1
    if current {
        Theme.yellow.setFill(); box.fill()
        if hot {
            let inner = NSBezierPath(rect: r.insetBy(dx: 2.5, dy: 2.5))
            inner.lineWidth = 1
            Theme.bg.setStroke(); inner.stroke()
        }
    } else if hot {
        Theme.bg1.setFill(); box.fill()
        Theme.yellow.setStroke(); box.stroke()
    } else if dashed {
        box.setLineDash([3, 3], count: 2, phase: 0)
        Theme.bg2.setStroke(); box.stroke()
    } else {
        Theme.bg1.setFill(); box.fill()
    }
    let color: NSColor = current ? Theme.bg : hot ? Theme.yellow : occupied ? Theme.fg : Theme.gray
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
    let h = (label as NSString).size(withAttributes: attrs).height
    (label as NSString).draw(in: NSRect(x: r.minX, y: r.minY + (r.height - h) / 2, width: r.width, height: h), withAttributes: attrs)
}

final class SwitcherView: NSView {
    var items: [Win] = []
    var sel = 0
    var first = 0
    var maxTiles = 6
    var spaceCount = 1
    var current = 1
    var occupied: Set<Int> = []
    // ⌘⌥Tab: a seleção fica nos chips de space; as janelas continuam embaixo.
    var spaceMode = false
    var spaceSel = 1
    let tileW: CGFloat = 170
    let tileH: CGFloat = 130
    let gap: CGFloat = 6
    let pad: CGFloat = 12
    let chipW: CGFloat = 34
    let chipH: CGFloat = 24
    let chipGap: CGFloat = 6
    override var isFlipped: Bool { true }

    var tilesTop: CGFloat { pad + chipH + 21 }
    var tilesWidth: CGFloat {
        let n = CGFloat(max(1, min(items.count, maxTiles)))
        return n * tileW + (n - 1) * gap
    }
    var chipsWidth: CGFloat { CGFloat(spaceCount + 1) * (chipW + chipGap) - chipGap }
    var contentSize: NSSize {
        let w = max(items.isEmpty ? 280 : tilesWidth, chipsWidth) + 2 * pad
        return NSSize(width: w, height: tilesTop + (items.isEmpty ? 44 : tileH) + pad)
    }

    // Chips 0..<spaceCount são os spaces; o último é o "+".
    func chipRect(_ c: Int) -> NSRect {
        NSRect(x: pad + CGFloat(c) * (chipW + chipGap), y: pad, width: chipW, height: chipH)
    }
    func tileRect(_ i: Int) -> NSRect {
        NSRect(x: pad + CGFloat(i - first) * (tileW + gap), y: tilesTop, width: tileW, height: tileH)
    }
    func scrollToSel() {
        if sel < first { first = sel } else if sel >= first + maxTiles { first = sel - maxTiles + 1 }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.bg.setFill()
        bounds.fill()
        Theme.bg2.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        // Topo: spaces + botão de criar.
        for c in 0...spaceCount {
            let isPlus = c == spaceCount
            drawChip(chipRect(c), isPlus ? "+" : "\(c + 1)", current: c == current - 1, occupied: occupied.contains(c + 1),
                     hot: spaceMode && !isPlus && c + 1 == spaceSel, dashed: isPlus, font: Theme.mono(12, .bold))
        }
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        right.lineBreakMode = .byTruncatingHead
        let hintX = pad + chipsWidth + 12
        let hint = spaceMode ? "+/-: space · tab: janelas" : items.isEmpty ? "" : "1-9: mover · +/-: space · ⌥tab: spaces"
        (hint as NSString).draw(in: NSRect(x: hintX, y: pad + 5, width: bounds.width - pad - hintX, height: 16),
                                withAttributes: [.font: Theme.mono(11), .foregroundColor: Theme.gray, .paragraphStyle: right])
        Theme.bg1.setFill()
        NSRect(x: pad, y: pad + chipH + 10, width: bounds.width - 2 * pad, height: 1).fill()

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        para.alignment = .center

        let selIdx = spaceMode ? -1 : sel
        if items.isEmpty {
            ("sem janelas neste space" as NSString).draw(
                in: NSRect(x: pad, y: tilesTop + 14, width: bounds.width - 2 * pad, height: 16),
                withAttributes: [.font: Theme.mono(13), .foregroundColor: Theme.gray, .paragraphStyle: para])
            return
        }

        let end = min(items.count, first + maxTiles)
        guard first < end else { return }
        // Tela cheia + janela de origem: uma faixa por trás das duas e um elo entre elas.
        for i in first..<(end - 1) {
            guard let p = items[i].pair, items[i + 1].pair == p else { continue }
            let a = tileRect(i), b = tileRect(i + 1)
            Theme.bg1.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: a.union(b).insetBy(dx: -3, dy: -3), xRadius: 6, yRadius: 6).fill()
            let y = a.minY + 46
            let link = NSRect(x: a.maxX - 10, y: y - 7, width: b.minX - a.maxX + 20, height: 14)
            Theme.bg2.setFill()
            NSBezierPath(roundedRect: link, xRadius: 7, yRadius: 7).fill()
            Theme.yellow.withAlphaComponent(0.8).setStroke()
            for x in [link.minX + 6, link.maxX - 6] {
                let ring = NSBezierPath(ovalIn: NSRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            let bar = NSBezierPath()
            bar.move(to: NSPoint(x: link.minX + 9, y: y))
            bar.line(to: NSPoint(x: link.maxX - 9, y: y))
            bar.lineWidth = 1.5
            bar.stroke()
        }
        for i in first..<end {
            let w = items[i]
            let tile = tileRect(i)
            let selected = i == selIdx
            let isFS = w.fullscreen
            if selected {
                Theme.bg1.setFill()
                tile.fill()
            }
            if selected || isFS {
                (selected ? Theme.yellow : Theme.gray).setStroke()
                let r = NSBezierPath(rect: tile.insetBy(dx: 0.5, dy: 0.5))
                r.lineWidth = 1
                if isFS { r.setLineDash([4, 3], count: 2, phase: 0) }
                r.stroke()
            }
            let fade: CGFloat = w.disabled ? 0.35 : 1
            let iconRect = NSRect(x: tile.midX - 32, y: tile.minY + 14, width: 64, height: 64)
            w.icon?.draw(in: iconRect, from: .zero,
                         operation: .sourceOver, fraction: (w.minimized ? 0.4 : 1) * fade, respectFlipped: true, hints: nil)
            if isFS { drawFullscreenBadge(NSRect(x: iconRect.maxX - 18, y: iconRect.maxY - 18, width: 24, height: 24)) }
            let nameColor: NSColor = selected ? Theme.yellow : (w.minimized ? Theme.gray : Theme.fg)
            let name = isFS ? "Tela Cheia" : w.appName
            (name as NSString).draw(
                in: NSRect(x: tile.minX + 8, y: tile.minY + 86, width: tileW - 16, height: 16),
                withAttributes: [.font: Theme.mono(12, .bold), .foregroundColor: nameColor.withAlphaComponent(fade), .paragraphStyle: para])
            let base = w.disabled ? "em tela cheia" : !w.pageTitle.isEmpty ? w.pageTitle : w.title.isEmpty ? (isFS ? w.appName : "(sem título)") : w.title
            let title = base + (w.minimized ? " (min)" : "")
            (title as NSString).draw(
                in: NSRect(x: tile.minX + 8, y: tile.minY + 104, width: tileW - 16, height: 16),
                withAttributes: [.font: Theme.mono(11), .foregroundColor: (w.minimized ? Theme.gray : Theme.fgDim).withAlphaComponent(fade),
                                 .paragraphStyle: para])
        }
    }
}

// Selo amarelo com as setas de tela cheia, no canto do ícone.
func drawFullscreenBadge(_ r: NSRect) {
    Theme.bg.setFill()
    NSBezierPath(roundedRect: r.insetBy(dx: -2, dy: -2), xRadius: 7, yRadius: 7).fill()
    Theme.yellow.setFill()
    NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
    let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
    guard let sym = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { return }
    let tinted = NSImage(size: sym.size, flipped: false) { rect in
        sym.draw(in: rect)
        Theme.bg.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    let s = sym.size
    tinted.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

// Spaces virtuais: as janelas de outros spaces vão para o canto inferior direito da tela
// (o macOS sempre deixa 1px visível), e o app inteiro é ocultado quando nenhuma janela dele
// está no space atual — aí não sobra nada na tela. Ao voltar, tudo é restaurado.
func axValue(_ el: AXUIElement, _ attr: String) -> AXValue? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v,
          CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    return (v as! AXValue)
}

func axPos(_ el: AXUIElement) -> CGPoint? {
    var p = CGPoint.zero
    guard let v = axValue(el, kAXPositionAttribute), AXValueGetValue(v, .cgPoint, &p) else { return nil }
    return p
}

func axSize(_ el: AXUIElement) -> CGSize? {
    var s = CGSize.zero
    guard let v = axValue(el, kAXSizeAttribute), AXValueGetValue(v, .cgSize, &s) else { return nil }
    return s
}

func axSetPos(_ el: AXUIElement, _ p: CGPoint) {
    var p = p
    if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v) }
}

func axSetSize(_ el: AXUIElement, _ s: CGSize) {
    var s = s
    if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v) }
}

func axGone(_ el: AXUIElement) -> Bool {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v) == .invalidUIElement
}

func hidePoint() -> CGPoint {
    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    guard let s = NSScreen.screens.max(by: { $0.frame.maxX < $1.frame.maxX }) else { return CGPoint(x: 10000, y: 10000) }
    return CGPoint(x: s.frame.maxX - 1, y: primaryH - s.frame.minY - 1)
}

struct Stashed {
    let el: AXUIElement
    let pid: pid_t
    let pos: CGPoint
    let size: CGSize
}

func mouseScreenFrame() -> NSRect? {
    let mouse = NSEvent.mouseLocation
    return (NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main)?.visibleFrame
}

func makePanel(_ view: NSView) -> Panel {
    let p = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.level = .popUpMenu
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    p.backgroundColor = .clear
    p.isOpaque = false
    p.hasShadow = false
    p.animationBehavior = .none
    p.hidesOnDeactivate = false
    p.contentView = view
    return p
}

final class Switcher {
    static let shared = Switcher()
    let view = SwitcherView()
    let panel: Panel
    var committingSpace = false
    var spaceMRU: [Int] = [1]  // último space usado primeiro
    // Logo depois de trocar de space, a ordem fica congelada por 2 s:
    // o próximo Cmd+Shift+Tab segue adiante em vez de voltar.
    var frozen: [Int] = []
    var frozenIdx = 0
    var frozenUntil: TimeInterval = 0
    let freezeTime: TimeInterval = 2
    var spaceIdx = 0              // posição em `frozen` escolhida no modo spaces
    var spaceOrderReady = false   // ordem dos spaces já montada nesta abertura do painel
    var visible = false
    var lastUsed: [CGWindowID: UInt64] = [:]
    var tick: UInt64 = 0
    let myPid = ProcessInfo.processInfo.processIdentifier
    // Apps que ficaram ocultos sem Cmd+H (ex.: Discord, que ao fechar a janela oculta o app).
    // Para esses, janelas ocultas contam como fechadas.
    var hiddenAsClosed: Set<pid_t> = []
    var lastCmdH: TimeInterval = 0
    // Mesa aberta pelo ⌘Tab+D: outro D, ainda com o Cmd, traz as janelas de volta.
    var desktopShown = false

    var spaceCount = 1
    var current = 1
    var spaceOf: [CGWindowID: Int] = [:]  // janela sem entrada pertence ao space atual
    var stashed: [CGWindowID: Stashed] = [:]
    var hiddenByUs: Set<pid_t> = []
    var switching = false

    init() {
        panel = makePanel(view)

        recoverStranded()

        Favicons.shared.onChange = { [unowned self] in
            guard visible else { return }
            for i in view.items.indices where view.items[i].safari {
                if let img = Favicons.shared.icon(view.items[i].title) { view.items[i].icon = img }
            }
            view.display()
        }
        Favicons.shared.refresh()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [unowned self] _ in
            noteFront()
            checkFullscreenEnded()
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [unowned self] _ in
            if !visible { _ = otherSpaceWins(excluding: []) }
        }

        let nc = NSWorkspace.shared.notificationCenter
        func pid(_ n: Notification) -> pid_t? {
            (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [unowned self] n in
            guard let p = pid(n), p != myPid else { return }
            // Espera o foco assentar; se a janela focada estiver em outro space, vai até ele.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [unowned self] in
                followFocus(p)
                if !switching { enforce(full: false) }
            }
        }
        nc.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main) { [unowned self] n in
            guard let p = pid(n), !hiddenByUs.contains(p) else { return }
            if ProcessInfo.processInfo.systemUptime - lastCmdH > 1.5 { hiddenAsClosed.insert(p) }
        }
        for name in [NSWorkspace.didUnhideApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [unowned self] n in
                if let p = pid(n) { hiddenAsClosed.remove(p); hiddenByUs.remove(p) }
            }
        }
    }

    func addSpace() {
        spaceCount += 1
        bumpMRU(spaceCount)
    }

    // Fecha o último space; as janelas dele vão para o anterior.
    func removeLastSpace() {
        guard spaceCount > 1 else { return }
        let last = spaceCount, prev = last - 1
        let all = fetchAll().wins
        for w in all where spaceOf[w.id] == nil { spaceOf[w.id] = current }
        for (id, s) in spaceOf where s == last { spaceOf[id] = prev }
        if current == last {
            // Estava no space que fechou: passa para o anterior e mostra as janelas dele.
            current = prev
            for (id, s) in spaceOf where s == prev { unstash(id) }
        } else if current == prev {
            for (id, s) in spaceOf where s == prev { unstash(id) }
        }
        spaceMRU = spaceMRU.filter { $0 != last }
        if spaceMRU.isEmpty { spaceMRU = [current] }
        frozen = frozen.filter { $0 != last }
        spaceCount -= 1
        _ = syncAppVisibility(fetchAll().wins)
        if current == prev {
            let selID = view.items.indices.contains(view.sel) ? view.items[view.sel].id : nil
            let here = fetch()
            view.items = expandTabs(here, extra: otherSpaceWins(excluding: Set(here.map(\.id))), markFront: false)
            view.sel = view.items.firstIndex { $0.id == selID } ?? min(view.sel, max(0, view.items.count - 1))
        }
        layout()
    }

    // Space que acabou de receber uma janela vira o próximo do Cmd+Shift+Tab (logo depois do atual).
    func bumpMRU(_ s: Int) {
        spaceMRU.removeAll { $0 == s }
        spaceMRU.insert(s, at: min(1, spaceMRU.count))
    }

    func occupiedSpaces() -> Set<Int> {
        var s = Set(spaceOf.values.filter { $0 != current })
        if !view.items.isEmpty { s.insert(current) }
        return s
    }

    func stash(_ w: Win) {
        guard stashed[w.id] == nil, !w.minimized,
              let pos = axPos(w.el), let size = axSize(w.el) else { return }
        stashed[w.id] = Stashed(el: w.el, pid: w.pid, pos: pos, size: size)
        axSetPos(w.el, hidePoint())
    }

    func unstash(_ id: CGWindowID) {
        guard let s = stashed.removeValue(forKey: id) else { return }
        axSetPos(s.el, s.pos)
        axSetSize(s.el, s.size)
    }

    // Oculta apps sem nenhuma janela no space atual; reexibe os que voltaram a ter.
    func syncAppVisibility(_ all: [Win]) -> Set<pid_t> {
        var inCurrent: Set<pid_t> = []
        var hasWindows: Set<pid_t> = []
        for w in all {
            hasWindows.insert(w.pid)
            if (spaceOf[w.id] ?? current) == current { inCurrent.insert(w.pid) }
        }
        var shown: Set<pid_t> = []
        for p in hiddenByUs where inCurrent.contains(p) {
            hiddenByUs.remove(p)
            NSRunningApplication(processIdentifier: p)?.unhide()
            shown.insert(p)
        }
        for p in hasWindows.subtracting(inCurrent) where !hiddenByUs.contains(p) {
            guard let app = NSRunningApplication(processIdentifier: p), !app.isHidden else { continue }
            hiddenByUs.insert(p)
            app.hide()
        }
        return shown
    }

    // Garante que nenhuma janela de outro space esteja visível. Um app (ex.: Terminal com janelas
    // em dois spaces) pode reposicionar a janela escondida quando é ativado; e uma janela pode ter
    // escapado da troca se o app demorou a responder.
    func enforce(full: Bool) {
        let hp = hidePoint()
        for (id, s) in stashed where (spaceOf[id] ?? current) != current {
            if let p = axPos(s.el), p.x < hp.x - 50 || p.y < hp.y - 80 { axSetPos(s.el, hp) }
        }
        guard full else { return }
        for w in fetchAll().wins where stashed[w.id] == nil {
            if let s = spaceOf[w.id], s != current { stash(w) }
        }
    }

    func restoreAll() {
        for p in fsOrigins.values where !axGone(p.origin) {
            AXUIElementSetAttributeValue(p.origin, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        fsOrigins.removeAll()
        for id in Array(stashed.keys) { unstash(id) }
        for p in hiddenByUs { NSRunningApplication(processIdentifier: p)?.unhide() }
        hiddenByUs.removeAll()
    }

    // Janelas que ficaram presas no canto (ex.: o app caiu) voltam para a tela.
    func recoverStranded() {
        let hp = hidePoint()
        for w in fetchAll().wins {
            guard let p = axPos(w.el), p.x >= hp.x - 50, p.y >= hp.y - 80 else { continue }
            axSetPos(w.el, CGPoint(x: 100, y: 100))
        }
    }

    func switchTo(_ t: Int) {
        guard t != current, (1...spaceCount).contains(t) else { return }
        if visible { hide() }
        switching = true
        // Esquece janelas que foram fechadas.
        for (id, s) in stashed where axGone(s.el) { stashed[id] = nil; spaceOf[id] = nil }
        var all = fetchAll().wins
        for w in all where spaceOf[w.id] == nil { spaceOf[w.id] = current }
        let leaving = current
        let leavingEmpty = !all.contains { spaceOf[$0.id] == leaving }
        for w in all where spaceOf[w.id] == leaving { stash(w) }
        for (id, s) in spaceOf where s == t { unstash(id) }
        current = t
        if !committingSpace { frozenUntil = 0 }
        spaceMRU.removeAll { $0 == t }
        spaceMRU.insert(t, at: 0)
        // Space vazio some ao sair dele; os seguintes andam uma posição.
        if leavingEmpty && spaceCount > 1 {
            for (id, s) in spaceOf where s > leaving { spaceOf[id] = s - 1 }
            if current > leaving { current -= 1 }
            spaceMRU = spaceMRU.filter { $0 != leaving }.map { $0 > leaving ? $0 - 1 : $0 }
            if let i = frozen.firstIndex(of: leaving), i < frozenIdx { frozenIdx -= 1 }
            frozen = frozen.filter { $0 != leaving }.map { $0 > leaving ? $0 - 1 : $0 }
            spaceCount -= 1
        }
        all = fetchAll().wins
        let shown = syncAppVisibility(all)
        let wins = fetch()
        if let w = wins.first(where: { !$0.minimized && (!$0.appHidden || shown.contains($0.pid)) }) {
            tick += 1
            lastUsed[w.id] = tick
            seen[key(w)] = ProcessInfo.processInfo.systemUptime
            focus(w)
        }
        // Apps podem trazer de volta janelas escondidas ao serem ativados; confere de novo.
        for delay in [0.25, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [unowned self] in enforce(full: true) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [unowned self] in switching = false }
    }

    // ⌘⌥Tab passa a seleção para os spaces; ⌘Tab volta para as janelas.
    // Depois de uma troca com o painel aberto, o próximo ⌘⌥Tab já avança para o space seguinte.
    func setSpaceMode(_ on: Bool) {
        guard visible, view.spaceMode != on else { return }
        let advance = on && spaceOrderReady
        if on && !spaceOrderReady { pickSpaceOrder() }
        view.spaceMode = on
        if advance { moveSpace(1) } else { showSelectedSpace(); view.display() }
    }

    // Último space usado primeiro. Logo depois de uma troca, segue adiante na ordem congelada.
    func pickSpaceOrder() {
        spaceOrderReady = true
        let now = ProcessInfo.processInfo.systemUptime
        let quick = now < frozenUntil && frozen.indices.contains(frozenIdx)
        if quick {
            // Spaces criados ou removidos nesse meio-tempo.
            frozen = frozen.filter { spaceMRU.contains($0) } + spaceMRU.filter { !frozen.contains($0) }
            if let i = frozen.firstIndex(of: current) { frozenIdx = i }
        } else {
            frozen = spaceMRU
            frozenIdx = 0
        }
        frozen = frozen.filter { $0 <= spaceCount } + (1...spaceCount).filter { !frozen.contains($0) }
        let n = frozen.count
        spaceIdx = n > 1 ? (quick ? (frozenIdx + 1) % n : 1) : 0
    }

    func showSelectedSpace() {
        let s = frozen.indices.contains(spaceIdx) ? frozen[spaceIdx] : current
        view.spaceSel = s
    }

    // Depois de criar ou fechar um space com o painel em modo spaces.
    func refreshSpaces() {
        guard view.spaceMode else { return }
        let s = view.spaceSel
        frozen = frozen.filter { $0 <= spaceCount } + (1...spaceCount).filter { !frozen.contains($0) }
        spaceIdx = frozen.firstIndex(of: s) ?? min(spaceIdx, frozen.count - 1)
        showSelectedSpace()
    }

    func moveSpace(_ d: Int) {
        let n = frozen.count
        guard n > 0 else { return }
        spaceIdx = ((spaceIdx + d) % n + n) % n
        showSelectedSpace()
        view.display()
    }

    // `keepOpen`: soltou o ⌥ com o ⌘ ainda apertado; troca e reabre com as janelas do space novo.
    func commitSpace(keepOpen: Bool = false) {
        hide()
        guard frozen.indices.contains(spaceIdx) else { return }
        frozenIdx = spaceIdx
        frozenUntil = ProcessInfo.processInfo.systemUptime + freezeTime
        committingSpace = true
        switchTo(frozen[spaceIdx])
        committingSpace = false
        guard keepOpen else { return }
        spaceIdx = frozen.firstIndex(of: current) ?? 0
        open(afterSwitch: true)
    }

    func followFocus(_ p: pid_t) {
        guard !switching else { return }
        let ax = AXUIElementCreateApplication(p)
        AXUIElementSetMessagingTimeout(ax, 0.1)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &v) == .success, let v else { return }
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(v as! AXUIElement, &id) == .success,
              let s = spaceOf[id], s != current else { return }
        // O app foi ativado com a janela em outro space: fica aqui. Se ele tiver janela
        // neste space, foca ela; senão o app só fica ativo, sem janela.
        let here = fetch().filter { $0.pid == p }
        if let w = here.first(where: { !$0.minimized }) ?? here.first {
            tick += 1
            lastUsed[w.id] = tick
            focus(w)
        }
    }

    func moveToSpace(_ i: Int, _ t: Int) {
        guard i < view.items.count, t != current else { return }
        // Número além do último space cria um novo (sempre o próximo da sequência).
        let t = min(t, spaceCount + 1)
        if t > spaceCount { addSpace() }
        bumpMRU(t)
        let w = view.items[i]
        if w.tab != nil && w.tabCount > 1 {
            // Só essa aba vai: as outras continuam na janela, aqui.
            detachTab(w, to: t)
            removeItems { j, _ in j == i }
            for j in view.items.indices where view.items[j].id == w.id { view.items[j].tabCount -= 1 }
        } else {
            spaceOf[w.id] = t
            stash(w)
            removeItems { _, x in x.id == w.id }
        }
        if !view.items.contains(where: { $0.pid == w.pid }) {
            _ = syncAppVisibility(fetchAll().wins)
        }
        layout()
    }

    func fetchAll() -> (wins: [Win], z: [CGWindowID: Int]) {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != myPid }
        let meta = apps.map { ($0.processIdentifier, $0.localizedName ?? "", $0.icon,
                               $0.isHidden && !hiddenAsClosed.contains($0.processIdentifier)) }
        var buckets = [[Win]](repeating: [], count: meta.count)
        buckets.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: meta.count) { i in
                base[i] = windows(pid: meta[i].0, appName: meta[i].1, icon: meta[i].2, hidden: meta[i].3)
            }
        }
        var z: [CGWindowID: Int] = [:]
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for (i, d) in info.enumerated() {
            if let n = d[kCGWindowNumber as String] as? CGWindowID { z[n] = i }
        }
        let wins = buckets.flatMap { $0 }
        for w in wins { axCache[w.id] = (w.el, w.pid) }
        return (wins, z)
    }

    // Janelas já vistas, para achá-las depois mesmo em outro space do macOS.
    var axCache: [CGWindowID: (el: AXUIElement, pid: pid_t)] = [:]
    var remoteTried: [CGWindowID: TimeInterval] = [:]  // última tentativa; tenta de novo depois de 5 s
    var resolving = false

    // Janelas em outros spaces do macOS (o desktop visto de dentro do fullscreen, ou o fullscreen
    // visto do desktop). Só as que pertencem ao space virtual atual.
    func otherSpaceWins(excluding have: Set<CGWindowID>) -> [Win] {
        let cur = activeSpace()
        let known = Set(spacesByDisplay().joined())
        guard cur != 0, !known.isEmpty else { return [] }
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var alive: Set<CGWindowID> = []
        var out: [Win] = []
        var unresolved: [pid_t: Set<CGWindowID>] = [:]
        let now = ProcessInfo.processInfo.systemUptime
        for d in info {
            guard let id = d[kCGWindowNumber as String] as? CGWindowID, let pid = d[kCGWindowOwnerPID as String] as? pid_t,
                  (d[kCGWindowLayer as String] as? Int) == 0 else { continue }
            alive.insert(id)
            guard !have.contains(id), pid != myPid, stashed[id] == nil, (spaceOf[id] ?? current) == current,
                  let s = spaceOfWindow(id), s != cur, known.contains(s),
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { continue }
            guard let c = axCache[id] else {
                if now - (remoteTried[id] ?? 0) > 5 { unresolved[pid, default: []].insert(id) }
                continue
            }
            guard var w = makeWin(c.el, pid: pid, appName: app.localizedName ?? "", icon: app.icon,
                                  hidden: app.isHidden && !hiddenAsClosed.contains(pid)), w.id == id else { continue }
            w.otherSpace = true
            out.append(w)
        }
        axCache = axCache.filter { alive.contains($0.key) }
        resolveInBackground(unresolved)
        return out
    }

    // Janelas que o alternador nunca viu (ex.: ele abriu com o vídeo já em tela cheia).
    func resolveInBackground(_ want: [pid_t: Set<CGWindowID>]) {
        guard !want.isEmpty, !resolving else { return }
        resolving = true
        let now = ProcessInfo.processInfo.systemUptime
        for ids in want.values { for id in ids { remoteTried[id] = now } }
        DispatchQueue.global(qos: .utility).async { [unowned self] in
            var found: [CGWindowID: (AXUIElement, pid_t)] = [:]
            for (pid, ids) in want {
                for (id, el) in remoteWindowElements(pid: pid, want: ids) { found[id] = (el, pid) }
            }
            DispatchQueue.main.async { [unowned self] in
                resolving = false
                for (id, v) in found { axCache[id] = (v.0, v.1) }
            }
        }
    }

    func fetch() -> [Win] {
        let (all, z) = fetchAll()
        // Aparece se for do space atual e estiver na tela, minimizada ou com o app oculto.
        let valid = all.filter {
            (spaceOf[$0.id] ?? current) == current && stashed[$0.id] == nil
                && (z[$0.id] != nil || $0.minimized || $0.appHidden)
        }
        return valid.sorted { a, b in
            switch (z[a.id], z[b.id]) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                if a.minimized != b.minimized { return !a.minimized }
                return (lastUsed[a.id] ?? 0) > (lastUsed[b.id] ?? 0)
            }
        }
    }

    func layout() {
        guard let vf = mouseScreenFrame() else { return }
        view.spaceCount = spaceCount
        view.current = current
        view.occupied = occupiedSpaces()
        view.maxTiles = max(1, Int((vf.width * 0.9 - 2 * view.pad + view.gap) / (view.tileW + view.gap)))
        if !view.spaceMode { view.scrollToSel() }
        let sz = view.contentSize
        panel.setFrame(NSRect(x: (vf.midX - sz.width / 2).rounded(), y: (vf.midY - sz.height / 2).rounded(),
                              width: sz.width, height: sz.height), display: false)
        view.display()
    }

    // MARK: abas do Safari como janelas
    var seen: [String: TimeInterval] = [:]  // última vez que cada janela/aba esteve na frente

    func key(_ w: Win) -> String { itemKey(w.id, w.title, safari: w.safari) }

    // Anota o que está na frente; é o que dá a ordem das abas que não estão ativas.
    // Devolve false se não deu para saber qual janela está em foco.
    @discardableResult
    func noteFront() -> Bool {
        guard !visible, let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != myPid else { return false }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.05)
        guard let v = axAttr(ax, kAXFocusedWindowAttribute) else { return false }
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(v as! AXUIElement, &id) == .success, id != 0 else { return false }
        let title = axAttr(v as! AXUIElement, kAXTitleAttribute) as? String ?? ""
        axCache[id] = (v as! AXUIElement, app.processIdentifier)
        if app.bundleIdentifier == safariID && !fsChecked.contains(id) && (title.isEmpty || (axAttr(v as! AXUIElement, "AXFullScreen") as? Bool) == true) {
            noteFullscreen(v as! AXUIElement, id: id, pid: app.processIdentifier)
        }
        seen[itemKey(id, title, safari: false)] = ProcessInfo.processInfo.systemUptime
        if seen.count > 3000 {
            let cut = seen.values.sorted()[1500]
            seen = seen.filter { $0.value >= cut }
        }
        return true
    }

    // Ordena as janelas por uso recente.
    // `extra`: janelas de outros spaces do macOS; entram pela ordem de uso.
    // `markFront`: o primeiro da tela conta como o da frente (só quando não se sabe a janela em foco).
    func expandTabs(_ base: [Win], extra: [Win] = [], markFront: Bool = true) -> [Win] {
        let wins = base + extra
        let groups = wins.map { [$0] }
        // Ordem: o item da frente; depois por uso recente (o que esteve na frente por último);
        // os que nunca estiveram na frente seguem a ordem de empilhamento do macOS (todos os spaces).
        // Minimizados e apps ocultos vão para o fim.
        let now = ProcessInfo.processInfo.systemUptime
        var z: [CGWindowID: Int] = [:]
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for (i, d) in info.enumerated() {
            if let n = d[kCGWindowNumber as String] as? CGWindowID, z[n] == nil { z[n] = i }
        }
        var items: [(w: Win, rank: Int)] = []
        for (gi, g) in groups.enumerated() {
            let r = (gi < base.count ? gi : (z[wins[gi].id] ?? 100_000)) * 1000
            for (ti, t) in g.enumerated() {
                items.append((t, r + ti))
            }
        }
        // Os da frente (z de outros spaces) usam a posição global; os deste space, a ordem local.
        if markFront, !base.isEmpty, let front = groups.first?.first { seen[key(front)] = now }
        let sorted = items.sorted { a, b in
            let ha = a.w.minimized || a.w.appHidden, hb = b.w.minimized || b.w.appHidden
            if ha != hb { return !ha }
            switch (seen[key(a.w)], seen[key(b.w)]) {
            case let (x?, y?): return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.rank < b.rank
            }
        }.map(\.w)
        return pairFullscreen(sorted)
    }

    // Enquanto um vídeo está em tela cheia, a aba de onde ele veio não serve para nada:
    // ela fica logo depois da tela cheia, apagada, e não pode ser escolhida.
    func pairFullscreen(_ items: [Win]) -> [Win] {
        var out = items
        for fsID in items.filter({ $0.fullscreen && !$0.pageTitle.isEmpty }).map(\.id) {
            guard let i = out.firstIndex(where: { $0.id == fsID }) else { continue }
            let t = normTitle(out[i].pageTitle)
            guard let p = out.firstIndex(where: { $0.pid == out[i].pid && !$0.fullscreen && normTitle($0.title) == t }) else { continue }
            let tag = "\(fsID)"
            out[i].pair = tag
            out[i].icon = Favicons.shared.icon(out[i].pageTitle) ?? out[p].icon
            var parent = out.remove(at: p)
            parent.pair = tag
            parent.disabled = true
            let fi = out.firstIndex { $0.id == fsID }!
            out.insert(parent, at: fi + 1)
        }
        return out
    }

    // MARK: vídeo em tela cheia minimiza a janela de origem
    // Enquanto o vídeo está em tela cheia, a janela do Safari de onde ele veio fica minimizada,
    // para não ocupar a mesa. Volta quando a tela cheia acaba.
    var fsOrigins: [CGWindowID: (fs: AXUIElement, origin: AXUIElement)] = [:]
    var fsChecked: Set<CGWindowID> = []  // telas cheias já tratadas
    var fsTries: [CGWindowID: Int] = [:]  // tentativas de achar a origem (desiste depois de ~5 s)

    func noteFullscreen(_ el: AXUIElement, id: CGWindowID, pid: pid_t) {
        guard !fsChecked.contains(id) else { return }
        let tries = fsTries[id, default: 0] + 1
        fsTries[id] = tries
        if tries > 10 { fsChecked.insert(id); return }
        // Título da página ainda não carregou ou a animação não acabou: tenta de novo no próximo ciclo.
        guard let w = makeWin(el, pid: pid, appName: "", icon: nil, hidden: false),
              w.fullscreen, !w.pageTitle.isEmpty else { return }
        let t = normTitle(w.pageTitle)
        // A origem está na mesa (outro space do macOS): vem do cache se o Accessibility não listar.
        var cands = windows(pid: pid, appName: "", icon: nil, hidden: false)
        for (cid, c) in axCache where c.pid == pid && !cands.contains(where: { $0.id == cid }) {
            if let x = makeWin(c.el, pid: pid, appName: "", icon: nil, hidden: false) { cands.append(x) }
        }
        cands.removeAll { $0.fullscreen || $0.minimized }
        guard let o = cands.first(where: { normTitle($0.title) == t })
            ?? cands.first(where: { safariTabs($0.el).contains { normTitle(axAttr($0, kAXTitleAttribute) as? String ?? "") == t } })
        else { return }
        fsChecked.insert(id)
        fsOrigins[id] = (el, o.el)
        setMinimized(o, true)
    }

    func checkFullscreenEnded() {
        fsChecked = fsChecked.filter { axCache[$0] != nil || fsOrigins[$0] != nil }
        fsTries = fsTries.filter { axCache[$0.key] != nil }
        for (id, p) in fsOrigins where axGone(p.fs) || (axAttr(p.fs, "AXFullScreen") as? Bool) != true {
            fsOrigins[id] = nil
            fsChecked.remove(id)
            fsTries[id] = nil
            guard !axGone(p.origin) else { continue }
            AXUIElementSetAttributeValue(p.origin, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(p.origin, kAXRaiseAction as CFString)
        }
    }

    // Tira a aba para uma janela própria e manda essa janela para o space `t`.
    func detachTab(_ w: Win, to t: Int) {
        let before = Set(windows(pid: w.pid, appName: "", icon: nil, hidden: false).map(\.id))
        focus(w)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [unowned self] in
            guard pressMenu(w.pid, "MoveTabToNewWindow") else { return }
            func find(_ tries: Int) {
                if let n = windows(pid: w.pid, appName: w.appName, icon: w.icon, hidden: false).first(where: { !before.contains($0.id) }) {
                    spaceOf[n.id] = t
                    stash(n)
                    return
                }
                if tries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { find(tries - 1) } }
            }
            find(15)
        }
    }

    func removeItems(_ pred: (Int, Win) -> Bool) {
        var newSel = view.sel
        var out: [Win] = []
        for (j, x) in view.items.enumerated() {
            if pred(j, x) { if j < view.sel { newSel -= 1 } } else { out.append(x) }
        }
        view.items = out
        view.sel = max(0, min(newSel, out.count - 1))
    }

    // `afterSwitch`: reabre logo depois de trocar de space; a janela focada na troca fica selecionada.
    func open(spaces: Bool = false, afterSwitch: Bool = false) {
        Favicons.shared.refresh()
        // A janela da frente é anotada a cada 0,5 s; anota agora para não perder uma troca recente
        // (ex.: vídeo que acabou de entrar em tela cheia). Durante a transição para a tela cheia,
        // a lista da tela ainda é a da mesa, então a janela em foco vale mais que a de cima da tela.
        let noted = afterSwitch || noteFront()
        let here = fetch()
        let extra = otherSpaceWins(excluding: Set(here.map(\.id)))
        let wins = expandTabs(here, extra: extra, markFront: !noted)
        view.items = wins
        view.first = 0
        view.sel = afterSwitch ? 0 : wins.count > 1 ? 1 : 0
        if view.items.indices.contains(view.sel) && view.items[view.sel].disabled { skipDisabled(1) }
        view.spaceMode = false
        if !afterSwitch { spaceOrderReady = false }
        visible = true
        layout()
        if spaces { setSpaceMode(true) }
        panel.orderFrontRegardless()
    }

    func move(_ d: Int) {
        let n = view.items.count
        guard n > 0 else { return }
        view.sel = ((view.sel + d) % n + n) % n
        skipDisabled(d)
        view.scrollToSel()
        view.display()
    }

    func skipDisabled(_ d: Int) {
        let n = view.items.count
        for _ in 0..<n where view.items[view.sel].disabled { view.sel = ((view.sel + (d < 0 ? -1 : 1)) % n + n) % n }
    }

    func hide() {
        panel.orderOut(nil)
        visible = false
    }

    func commit() {
        guard visible else { return }
        if view.spaceMode { commitSpace(); return }
        hide()
        guard view.sel < view.items.count else { return }
        let w = view.items[view.sel]
        tick += 1
        lastUsed[w.id] = tick
        seen[key(w)] = ProcessInfo.processInfo.systemUptime
        // Em outro space do macOS: anda até ele e foca de novo quando a animação termina.
        if w.otherSpace && hopToSpace(of: w.id) {
            focus(w)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { focus(w) }
            return
        }
        focus(w)
    }

    func closeSelected() {
        guard view.sel < view.items.count else { return }
        let w = view.items[view.sel]
        if let tab = w.tab, w.tabCount > 1, closeTab(tab) {
            removeItems { j, _ in j == view.sel }
            for j in view.items.indices where view.items[j].id == w.id { view.items[j].tabCount -= 1 }
        } else {
            close(w)
            removeItems { j, x in j == view.sel || x.id == w.id }
        }
        layout()
    }

    // Minimiza a janela inteira (no Safari, junto com as outras abas dela).
    func minimizeSelected() {
        guard view.sel < view.items.count else { return }
        let w = view.items[view.sel]
        let on = !w.minimized
        setMinimized(w, on)
        for j in view.items.indices where view.items[j].id == w.id { view.items[j].minimized = on }
        view.display()
    }

    // MARK: ⌘W fechar janela — por cima de todos os apps.

    func focusedWin() -> Win? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != myPid else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.1)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &v) == .success, let v else { return nil }
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(v as! AXUIElement, &id) == .success else { return nil }
        return windows(pid: app.processIdentifier, appName: app.localizedName ?? "", icon: app.icon, hidden: false)
            .first { $0.id == id }
    }

    func closeFront() {
        guard let w = focusedWin() else { focusNextIfEmpty(); return }
        close(w)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [unowned self] in focusNextIfEmpty() }
    }

    // O app da frente ficou sem janela neste space: vai para o app de cima que ainda tenha.
    func focusNextIfEmpty() {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let wins = fetch().filter { !$0.minimized && !$0.appHidden }
        guard !wins.contains(where: { $0.pid == front }), let w = wins.first else { return }
        tick += 1
        lastUsed[w.id] = tick
        focus(w)
    }

    func handle(_ type: CGEventType, _ e: CGEvent) -> Bool {
        if e.getIntegerValueField(.eventSourceUserData) == hopMarker { return false }
        let f = e.flags
        if type == .flagsChanged {
            if visible && !f.contains(.maskCommand) { commit() }
            else if visible && view.spaceMode && !f.contains(.maskAlternate) { commitSpace(keepOpen: true) }
            if !f.contains(.maskCommand) { desktopShown = false }
            return false
        }
        guard type == .keyDown else { return false }
        let k = e.getIntegerValueField(.keyboardEventKeycode)
        let cmd = f.contains(.maskCommand)
        if k == 4 && cmd { lastCmdH = ProcessInfo.processInfo.systemUptime }
        // ⌘Tab: janelas. ⌘⌥Tab: spaces, último usado primeiro. Soltar o ⌥ troca de space; soltar o ⌘ confirma.
        if k == 48 && cmd {
            let opt = f.contains(.maskAlternate)
            if !visible { open(spaces: opt) }
            else if opt != view.spaceMode { setSpaceMode(opt) }
            else if opt { moveSpace(1) } else { move(1) }
            return true
        }
        // ⌘W no Safari fica com o próprio Safari: fecha a aba, não a janela inteira.
        if !visible && k == 13 && cmd && f.intersection([.maskShift, .maskControl, .maskAlternate]).isEmpty
            && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == safariID {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [unowned self] in focusNextIfEmpty() }
            return false
        }
        if !visible && cmd && f.intersection([.maskShift, .maskControl, .maskAlternate]).isEmpty,
           let action: () -> Void = [13: closeFront][k] {
            if e.getIntegerValueField(.keyboardEventAutorepeat) == 0 { action() }
            return true
        }
        if desktopShown && k == 2 && cmd {
            if e.getIntegerValueField(.keyboardEventAutorepeat) == 0 { showDesktop(); desktopShown = false }
            return true
        }
        guard visible else { return false }
        if view.spaceMode {
            if k == 53 { hide() }
            if cmd && e.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                if k == 24 || k == 69 { addSpace(); refreshSpaces(); layout() }
                if k == 27 || k == 78 { removeLastSpace(); refreshSpaces(); layout() }
            }
            return true
        }
        if k == 13 && cmd { closeSelected() }
        if k == 46 && cmd { minimizeSelected() }
        if k == 2 && cmd { hide(); showDesktop(); desktopShown = true; return true }
        // 1–9: manda a janela selecionada para aquele space.
        if let n = digitKeys[k], view.sel < view.items.count { moveToSpace(view.sel, n) }
        // + cria o próximo space; − fecha o último (as janelas vão para o anterior).
        if cmd && e.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            if k == 24 || k == 69 { addSpace(); layout() }
            if k == 27 || k == 78 { removeLastSpace() }
        }
        return true
    }
}

let digitKeys: [Int64: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

var eventTap: CFMachPort?

func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = eventTap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    return Switcher.shared.handle(type, event) ? nil : Unmanaged.passUnretained(event)
}

func startTap() -> Bool {
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                      eventsOfInterest: mask, callback: tapCallback, userInfo: nil) else { return false }
    eventTap = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    nativeSwitcher(false)
    _ = Switcher.shared
    return true
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts), startTap() { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            if AXIsProcessTrusted(), startTap() { t.invalidate(); self?.timer = nil }
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        cleanup()
    }
}

// Ao sair: devolve o Cmd+Tab nativo e traz de volta as janelas escondidas em outros spaces.
func cleanup() {
    nativeSwitcher(true)
    if eventTap != nil { Switcher.shared.restoreAll() }
}

atexit { cleanup() }
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { cleanup(); exit(0) }
    src.resume()
    signalSources.append(src)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
