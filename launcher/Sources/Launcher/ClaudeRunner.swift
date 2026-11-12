import Foundation

final class StreamParser {
    private var buffer = Data()
    private let onText: (String) -> Void
    private(set) var text = ""
    private(set) var final: String?
    private(set) var isError = false
    /// Sessão do claude, para a próxima pergunta continuar a conversa.
    private(set) var sessionID: String?

    init(onText: @escaping (String) -> Void) {
        self.onText = onText
    }

    func feed(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 10) {
            let line = Data(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if let id = obj["session_id"] as? String { sessionID = id }
        switch obj["type"] as? String {
        case "stream_event":
            guard let event = obj["event"] as? [String: Any] else { return }
            switch event["type"] as? String {
            case "message_start":
                text = ""
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let t = delta["text"] as? String {
                    text += t
                    onText(text)
                }
            default:
                break
            }
        case "result":
            final = obj["result"] as? String
            isError = obj["is_error"] as? Bool ?? false
        default:
            break
        }
    }
}

final class ClaudeRunner {
    static let shared = ClaudeRunner()

    private var executable: String?
    private var searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    private var current: Process?
    /// Conversa em andamento; cada pergunta nova continua dela.
    private var sessionID: String?
    /// Hora da última pergunta; depois de 2 horas sem perguntar, começa uma conversa nova.
    private var lastAsk: Date?
    private static let sessionTimeout: TimeInterval = 2 * 60 * 60

    private static let readOnlyTools = [
        "Read", "Glob", "Grep", "WebSearch", "WebFetch",
        "Bash(ls:*)", "Bash(df:*)", "Bash(du:*)", "Bash(cat:*)", "Bash(head:*)", "Bash(tail:*)",
        "Bash(wc:*)", "Bash(mdfind:*)", "Bash(stat:*)", "Bash(file:*)", "Bash(pwd)", "Bash(date)",
        "Bash(whoami)", "Bash(which:*)", "Bash(ps:*)", "Bash(uptime)", "Bash(sw_vers)",
        "Bash(pmset -g:*)", "Bash(diskutil list:*)", "Bash(diskutil info:*)"
    ]

    private static let systemPrompt = """
    Você responde dentro de um launcher do macOS. Responda em português do Brasil, curto e direto, em texto puro, sem markdown.
    Você pode usar ferramentas somente leitura para consultar o sistema. Nunca tente alterar arquivos, apps ou ajustes.
    Se o pedido exigir qualquer alteração (mover, copiar, renomear, apagar, criar, instalar, abrir apps, mudar ajustes), escreva uma frase dizendo exatamente o que será feito, com caminhos completos, e termine com um bloco neste formato:
    <comandos>
    um comando zsh por linha
    </comandos>
    Os comandos serão mostrados ao usuário e executados só depois da confirmação dele. Use caminhos absolutos ou com ~ e coloque aspas em caminhos com espaços.
    """

    func resolve() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude", home + "/.npm-global/bin/claude", home + "/.bun/bin/claude"]
        executable = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lic", "echo \"__PATH__$PATH\"; command -v claude"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if p.isRunning { p.terminate() }
            }
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            var path: String?
            var exe: String?
            for line in text.split(separator: "\n").map(String.init) {
                if line.hasPrefix("__PATH__") {
                    path = String(line.dropFirst(8))
                } else if line.hasPrefix("/"), line.hasSuffix("/claude") {
                    exe = line
                }
            }
            DispatchQueue.main.async {
                if let path, !path.isEmpty { self.searchPath = path }
                if let exe { self.executable = exe }
            }
        }
    }

    /// Ambiente com o PATH do shell de login do usuário.
    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        return env
    }

    private func configure(_ p: Process) {
        p.environment = environment
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        p.standardInput = FileHandle.nullDevice
    }

    func ask(_ prompt: String, onText: @escaping (String) -> Void, onDone: @escaping (String, String?) -> Void) {
        current?.terminate()
        guard let exe = executable else {
            onDone("", "claude não encontrado no sistema")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["-p", prompt,
                       "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                       "--append-system-prompt", Self.systemPrompt,
                       "--disallowedTools", "Edit", "Write", "NotebookEdit",
                       "--allowedTools"] + Self.readOnlyTools
        if let last = lastAsk, Date().timeIntervalSince(last) > Self.sessionTimeout { sessionID = nil }
        lastAsk = Date()
        if let id = sessionID { p.arguments! += ["--resume", id] }
        configure(p)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let parser = StreamParser(onText: onText)
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { parser.feed(data) }
        }
        p.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            let rest = out.fileHandleForReading.readDataToEndOfFile()
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                parser.feed(rest)
                parser.feed(Data([10]))
                // Se a sessão não pôde ser retomada, a próxima pergunta começa uma conversa nova.
                self.sessionID = parser.sessionID ?? (parser.isError || status != 0 ? nil : self.sessionID)
                if parser.isError {
                    onDone("", parser.final ?? "erro do claude")
                } else if let final = parser.final {
                    onDone(final, nil)
                } else if status != 0 {
                    onDone("", "erro ao chamar o claude (código \(status))")
                } else {
                    onDone(parser.text, nil)
                }
            }
        }
        do {
            try p.run()
            current = p
        } catch {
            onDone("", "não foi possível iniciar o claude")
        }
    }

    func execute(_ commands: [String], onDone: @escaping (String, Bool) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", "set -e\n" + commands.joined(separator: "\n")]
        configure(p)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try p.run()
            } catch {
                DispatchQueue.main.async { onDone(error.localizedDescription, false) }
                return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            let ok = p.terminationStatus == 0
            DispatchQueue.main.async { onDone(text, ok) }
        }
    }

    static func split(_ text: String) -> (answer: String, commands: [String]) {
        guard let open = text.range(of: "<comandos>") else {
            var t = text
            if let lt = t.range(of: "<", options: .backwards), "<comandos>".hasPrefix(String(t[lt.lowerBound...])) {
                t = String(t[..<lt.lowerBound])
            }
            return (t.trimmed, [])
        }
        let answer = String(text[..<open.lowerBound]).trimmed
        var rest = String(text[open.upperBound...])
        guard let close = rest.range(of: "</comandos>") else { return (answer, []) }
        rest = String(rest[..<close.lowerBound])
        let commands = rest.split(separator: "\n")
            .map { String($0).trimmed }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") }
        return (answer, commands)
    }
}
