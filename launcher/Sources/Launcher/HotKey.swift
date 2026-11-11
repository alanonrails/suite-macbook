import AppKit
import Carbon.HIToolbox

// Atalho global Cmd+Espaço. O atalho do Spotlight precisa estar desligado nos Ajustes.
final class HotKey {
    private let action: () -> Void
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data else { return noErr }
            let hk = Unmanaged<HotKey>.fromOpaque(data).takeUnretainedValue()
            DispatchQueue.main.async { hk.action() }
            return noErr
        }, 1, &spec, me, &handler)

        let id = EventHotKeyID(signature: OSType(0x4C4E4348), id: 1) // "LNCH"
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey), id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            NSLog("Launcher: não foi possível registrar Cmd+Espaço (%d)", status)
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
