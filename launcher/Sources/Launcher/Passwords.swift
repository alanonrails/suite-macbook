import AppKit
import Foundation

struct PasswordEntry {
    var name: String
    var username: String
    var password: String

    /// Item só de 2FA: no lugar da senha vem "Two-factor authentication (2FA)".
    var is2FA: Bool { password.lowercased().contains("two-factor authentication") }
}

/// Senhas lidas de ~/Documents/Launcher/senhas.csv. O launcher só lê; o arquivo é editado numa planilha.
enum Passwords {
    static let fileName = "senhas.csv"
    static var file: URL { Store.dir.appendingPathComponent(fileName) }

    static let header = "Title,Username,Password"

    static func load() -> (entries: [PasswordEntry], error: String?) {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return ([], "arquivo não existe: ~/Documents/Launcher/\(fileName)")
        }
        guard let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
        else { return ([], "não consegui ler \(fileName)") }

        var rows = parse(text)
        guard !rows.isEmpty else { return ([], nil) }

        // Colunas pelo nome no cabeçalho; sem cabeçalho, usa a ordem title, username, password.
        var col = (name: 0, user: 1, pass: 2)
        let head = rows[0].map { $0.trimmed.lowercased() }
        func index(_ names: [String]) -> Int? { head.firstIndex { names.contains($0) } }
        if let p = index(["password", "senha"]) {
            col.pass = p
            col.name = index(["title", "name", "nome", "título", "titulo"]) ?? -1
            col.user = index(["username", "user", "usuário", "usuario", "login", "email", "e-mail"]) ?? -1
            rows.removeFirst()
        }

        let entries: [PasswordEntry] = rows.compactMap { r in
            func get(_ i: Int) -> String { i >= 0 && i < r.count ? r[i].trimmed : "" }
            let e = PasswordEntry(name: get(col.name), username: get(col.user), password: get(col.pass))
            if e.password.isEmpty && e.name.isEmpty && e.username.isEmpty { return nil }
            return e
        }
        return (entries, nil)
    }

    static func displayName(_ e: PasswordEntry) -> String {
        e.name.isEmpty ? "(sem nome)" : e.name
    }

    /// Copia marcado como confidencial, para apps de histórico da área de transferência não guardarem.
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }

    /// Abre o CSV no app padrão (planilha). Se não existir, cria só com o cabeçalho.
    static func openFile() {
        if !FileManager.default.fileExists(atPath: file.path) {
            try? (header + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(file)
    }

    /// CSV com "," ou ";" (Excel e Numbers em português usam ";"), aspas e quebras de linha dentro dos campos.
    static func parse(_ raw: String) -> [[String]] {
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let sep: Character = delimiter(text)

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(text)
        chars.append("\n")
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                quoted = true
            } else if c == sep {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r" || c == "\r\n" {
                row.append(field); field = ""
                if row.contains(where: { !$0.trimmed.isEmpty }) { rows.append(row) }
                row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        return rows
    }

    /// O separador que mais aparece na primeira linha, fora das aspas.
    private static func delimiter(_ text: String) -> Character {
        var commas = 0, semis = 0, quoted = false
        for c in text {
            if c == "\"" { quoted.toggle() }
            else if !quoted && (c == "\n" || c == "\r" || c == "\r\n") { break }
            else if !quoted && c == "," { commas += 1 }
            else if !quoted && c == ";" { semis += 1 }
        }
        return semis > commas ? ";" : ","
    }
}
