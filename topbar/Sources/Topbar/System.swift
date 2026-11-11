import Cocoa
import ApplicationServices

struct MenuItem {
    let el: AXUIElement
    let title: String
}

func menus(pid: pid_t) -> [MenuItem] {
    let ax = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(ax, 0.1)
    var bar: CFTypeRef?
    guard AXUIElementCopyAttributeValue(ax, kAXMenuBarAttribute as CFString, &bar) == .success, let bar else { return [] }
    var kids: CFTypeRef?
    guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success,
          let list = kids as? [AXUIElement] else { return [] }
    return list.dropFirst().compactMap { el in
        var t: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &t)
        guard let s = t as? String, !s.isEmpty else { return nil }
        return MenuItem(el: el, title: s)
    }
}

struct MenuEntry {
    let el: AXUIElement
    let title: String
    let shortcut: String
    let enabled: Bool
    let submenu: Bool
    var separator: Bool { title.isEmpty }
}

func shortcutLabel(_ char: String?, _ mods: Int) -> String {
    guard let c = char, let u = c.unicodeScalars.first, u.value >= 0x21, u.value < 0xF700 else { return "" }
    var s = ""
    if mods & 4 != 0 { s += "⌃" }
    if mods & 2 != 0 { s += "⌥" }
    if mods & 1 != 0 { s += "⇧" }
    if mods & 8 == 0 { s += "⌘" }
    return s + c.uppercased()
}

func entries(of el: AXUIElement) -> [MenuEntry] {
    AXUIElementSetMessagingTimeout(el, 0.3)
    var kids: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
          let menu = (kids as? [AXUIElement])?.first else { return [] }
    var items: CFTypeRef?
    guard AXUIElementCopyAttributeValue(menu, kAXChildrenAttribute as CFString, &items) == .success,
          let list = items as? [AXUIElement] else { return [] }
    let attrs = [kAXTitleAttribute, kAXEnabledAttribute, "AXMenuItemCmdChar", "AXMenuItemCmdModifiers", kAXChildrenAttribute] as CFArray
    var out: [MenuEntry] = []
    for it in list {
        var vals: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(it, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &vals) == .success,
              let a = vals as? [Any], a.count == 5 else { continue }
        let title = a[0] as? String ?? ""
        if title.isEmpty && (out.last?.separator ?? true) { continue }
        out.append(MenuEntry(el: it, title: title, shortcut: shortcutLabel(a[2] as? String, a[3] as? Int ?? 0),
                             enabled: a[1] as? Bool ?? true, submenu: (a[4] as? [AXUIElement])?.isEmpty == false))
    }
    while out.last?.separator == true { out.removeLast() }
    return out
}

enum Kiosk {
    static func apply() {
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        let dock = "com.apple.dock" as CFString
        let global = kCFPreferencesAnyApplication
        func set(_ key: String, _ value: CFPropertyList, _ domain: CFString) -> Bool {
            if let cur = CFPreferencesCopyAppValue(key as CFString, domain), CFEqual(cur, value) { return false }
            CFPreferencesSetAppValue(key as CFString, value, domain)
            return true
        }
        var dockChanged = set("autohide", kCFBooleanTrue, dock)
        dockChanged = set("autohide-delay", 1000.0 as CFNumber, dock) || dockChanged
        dockChanged = set("autohide-time-modifier", 0.0 as CFNumber, dock) || dockChanged
        CFPreferencesAppSynchronize(dock)
        let menuChanged = set("_HIHideMenuBar", kCFBooleanTrue, global)
        _ = set("AppleMenuBarVisibleInFullscreen", kCFBooleanFalse, global)
        CFPreferencesAppSynchronize(global)
        let cc = "com.apple.controlcenter" as CFString
        _ = set("AutoHideMenuBarOption", 0 as CFNumber, cc)
        CFPreferencesAppSynchronize(cc)
        DispatchQueue.global(qos: .utility).async {
            NSAppleScript(source: "tell application \"System Events\" to set autohide menu bar of dock preferences to true")?.executeAndReturnError(nil)
        }
        if menuChanged {
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("AppleInterfaceMenuBarHidingChangedNotification"), object: nil, userInfo: nil, deliverImmediately: true)
        }
        if dockChanged {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            p.arguments = ["Dock"]
            try? p.run()
        }
    }
}
