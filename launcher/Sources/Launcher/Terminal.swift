import AppKit

/// Abre uma janela nova do Terminal.app rodando o comando digitado no quicklink terminal.
enum TerminalRunner {
    static func open(_ command: String) -> String? {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty
        // Se o Terminal estava fechado, ele já abre com uma janela; usa ela em vez de criar outra.
        let run = running
            ? "do script \"\(escaped)\""
            : "reopen\n    do script \"\(escaped)\" in window 1"
        let source = """
        tell application "Terminal"
            \(run)
            activate
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            return error[NSAppleScript.errorMessage] as? String ?? "não foi possível abrir o Terminal"
        }
        return nil
    }
}
