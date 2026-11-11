import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PanelController!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ClaudeRunner.shared.resolve()
        LocationPermission.shared.request()
        controller = PanelController()
        hotKey = HotKey { [weak self] in
            self?.controller.toggle()
        }
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }
}

// Se o launcher foi aberto de dentro de uma sessão do Claude (ex.: pelo build.sh),
// ele herda as variáveis dela e repassa para tudo o que abre (Terminal, comandos).
// Só as variáveis de sessão; configurações como CLAUDE_CONFIG_DIR são mantidas.
let claudeSessionVars = [
    "CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDE_PID",
    "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
    "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_EXECPATH", "CLAUDE_EFFORT", "AI_AGENT",
]
for key in claudeSessionVars {
    unsetenv(key)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
