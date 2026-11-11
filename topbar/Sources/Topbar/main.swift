import Cocoa
import ServiceManagement

var eventTap: CFMachPort?

// Só o F10 de verdade (Fn+F10). A tecla especial de mudo fica com o sistema.
func isF10(_ type: CGEventType, _ e: CGEvent) -> Bool {
    guard type == .keyDown else { return false }
    let other: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
    return e.getIntegerValueField(.keyboardEventKeycode) == 109 && e.flags.intersection(other).isEmpty
        && e.getIntegerValueField(.keyboardEventAutorepeat) == 0
}

func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let pass = Unmanaged.passUnretained(event)
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let t = eventTap { CGEvent.tapEnable(tap: t, enable: true) }
        return pass
    default:
        break
    }
    if isF10(type, event) {
        Bar.shared.toggle()
        return nil
    }
    if type == .keyDown && Bar.shared.key(event.getIntegerValueField(.keyboardEventKeycode)) { return nil }
    return pass
}

func startTap() -> Bool {
    let types: [CGEventType] = [.keyDown]
    let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                      eventsOfInterest: mask, callback: tapCallback, userInfo: nil) else { return false }
    eventTap = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    _ = Bar.shared.menuPanel
    return true
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        Kiosk.apply()
        MenuBarCover.shared.refresh()
        if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MenuBarCover.shared.refresh()
        }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts), startTap() { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            if AXIsProcessTrusted(), startTap() { t.invalidate(); self?.timer = nil }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
