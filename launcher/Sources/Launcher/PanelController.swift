import AppKit
import SwiftUI

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        let editor = super.fieldEditor(createFlag, for: object)
        (editor as? NSTextView)?.selectedTextAttributes = Theme.selection
        return editor
    }
}

final class PanelController: NSObject, NSWindowDelegate {
    private let state = LauncherState()
    private let panel: LauncherPanel
    private var monitor: Any?
    private var timer: Timer?
    /// Nenhuma tecla apertada desde que o painel abriu.
    private var fresh = false

    override init() {
        panel = LauncherPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.delegate = self

        let host = NSHostingView(rootView: LauncherView().environmentObject(state))
        host.sizingOptions = []
        panel.contentView = host

        state.hidePanel = { [weak self] in self?.hide() }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let width = (vf.width / 3).rounded()
        let height = (vf.height * 0.92).rounded()
        let top = vf.maxY - vf.height * 0.04
        panel.setFrame(NSRect(x: (vf.midX - width / 2).rounded(), y: (top - height).rounded(), width: width, height: height), display: false)
        state.notificationsMax = (vf.height * 0.35).rounded()
        state.barTop = (vf.height * 0.14).rounded()
        state.balloonMax = (vf.height * 0.4).rounded()
        state.favoritesFit = Favorites.fit(width)
        WebHistory.preload()
        state.resume()
        state.refreshStatus()
        panel.makeKeyAndOrderFront(nil)
        state.focusToken += 1
        fresh = true
        state.refreshApps()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.state.refreshStatus()
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        guard e.window === panel else { return e }

        // ⌫ como primeira tecla ao abrir limpa tudo.
        if fresh {
            fresh = false
            if e.keyCode == 51 && e.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty {
                state.clearAll()
                return nil
            }
        }

        if e.modifierFlags.contains(.command) {
            if (e.keyCode == 36 || e.keyCode == 76) && state.mode == .apps
                && LauncherState.guessURL(state.query) != nil {
                state.addBookmark()
                return nil
            }
            if state.mode == .senhas {
                if e.keyCode == 36 || e.keyCode == 76 { state.copyPassword(user: true); return nil }
                if e.charactersIgnoringModifiers?.lowercased() == "o" { Passwords.openFile(); state.hidePanel?(); return nil }
            }
            // Sem menu principal, os atalhos de edição não chegam ao campo de texto.
            let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
            let key = e.charactersIgnoringModifiers?.lowercased()
            var action: Selector?
            if mods == .command {
                switch key {
                case "c": action = #selector(NSText.copy(_:))
                case "v": action = #selector(NSText.paste(_:))
                case "x": action = #selector(NSText.cut(_:))
                case "a": action = #selector(NSText.selectAll(_:))
                default: break
                }
            }
            if let action, NSApp.sendAction(action, to: nil, from: panel) {
                return nil
            }
            return e
        }

        if let tv = panel.firstResponder as? NSTextView, !tv.isFieldEditor {
            if e.keyCode == 53 {
                state.focusField()
                return nil
            }
            return e
        }

        if state.inBalloon { return handleBalloon(e) }

        switch e.keyCode {
        case 53:
            if state.escape() { hide() }
            return nil
        case 36, 76:
            state.submit()
            return nil
        case 48:
            if !state.tab() { state.enterBalloon() }
            return nil
        case 125 where state.query.isEmpty && state.mode == nil && !state.showQuicklinks:
            state.openQuicklinks()
            return nil
        case 125:
            state.move(1)
            return nil
        case 126:
            state.move(-1)
            return nil
        case 123, 124:
            return state.moveFavorite(e.keyCode == 123 ? -1 : 1) ? nil : e
        case 51 where state.query.isEmpty:
            return state.back() ? nil : e
        default:
            return e
        }
    }

    /// Teclas com o foco na área de baixo: esc/tab voltam ao campo, setas e enter navegam.
    private func handleBalloon(_ e: NSEvent) -> NSEvent? {
        let k = e.keyCode
        if k == 48 { state.focusField(); return nil }

        // Notificações: ↑↓ escolhe, ⌫ apaga a escolhida.
        if state.notificationsFocused {
            switch k {
            case 53: state.focusField()
            case 125: state.moveNotification(1)
            case 126: state.moveNotification(-1)
            case 51: state.dismissSelectedNotification()
            default: break
            }
            return nil
        }

        // Tradução: ←→ entre os idiomas e o inverter; enter abre a lista ou inverte; esc fecha a lista.
        if state.mode == .traduzir {
            switch k {
            case 53:
                if state.picking != nil { state.picking = nil } else { state.focusField() }
            case 123: state.translateMove(-1, 0)
            case 124: state.translateMove(1, 0)
            case 125: state.translateMove(0, 1)
            case 126: state.translateMove(0, -1)
            case 36, 76: state.translateEnter()
            default: break
            }
            return nil
        }

        switch k {
        case 123, 124:
            _ = state.moveFavorite(k == 123 ? -1 : 1)
        case 53:
            if state.escape() { state.focusField() }
        case 36, 76:
            state.submit()
        case 125:
            state.move(1)
        case 126:
            state.move(-1)
        default:
            break
        }
        return nil
    }
}
