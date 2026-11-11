import AppKit
import Foundation
import Translation
import SQLite3

enum Store {
    static let dir: URL = {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Launcher", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        let old = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Launcher", isDirectory: true)
        for name in ["apps.json"] {
            let target = base.appendingPathComponent(name)
            let source = old.appendingPathComponent(name)
            if !fm.fileExists(atPath: target.path), fm.fileExists(atPath: source.path) {
                try? fm.copyItem(at: source, to: target)
            }
        }
        if !fm.fileExists(atPath: base.appendingPathComponent("notas.txt").path),
           let note = UserDefaults.standard.string(forKey: "note") {
            try? note.write(to: base.appendingPathComponent("notas.txt"), atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: base.appendingPathComponent("notificacoes-ocultas.json").path),
           let ids = UserDefaults.standard.array(forKey: "hiddenNotifications") as? [Int64],
           let data = try? JSONEncoder().encode(ids) {
            try? data.write(to: base.appendingPathComponent("notificacoes-ocultas.json"), options: .atomic)
        }
        return base
    }()

    static func readText(_ name: String) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    static func writeText(_ text: String, _ name: String) {
        try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    static func loadIDs(_ name: String) -> [Int64] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return [] }
        return (try? JSONDecoder().decode([Int64].self, from: data)) ?? []
    }

    static func saveIDs(_ ids: [Int64], _ name: String) {
        guard let data = try? JSONEncoder().encode(ids) else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    static func load(_ name: String) -> [GridEntry]? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode([GridEntry].self, from: data)
    }

    static func save(_ entries: [GridEntry], _ name: String) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

}

/// De onde veio cada app (e os bookmarks), na ordem em que os grupos aparecem no quicklink apps.
enum Origin: Int, CaseIterable {
    case appStore, homebrew, pkg, manual, mine, bookmark, system

    var title: String {
        switch self {
        case .appStore: return "app store"
        case .homebrew: return "homebrew"
        case .pkg: return "instalador .pkg"
        case .manual: return "manual (.dmg / .zip)"
        case .mine: return "seus apps"
        case .bookmark: return "bookmarks"
        case .system: return "veio com o mac"
        }
    }

    /// Texto curto, à direita de cada resultado da busca.
    var short: String {
        switch self {
        case .appStore: return "app store"
        case .homebrew: return "homebrew"
        case .pkg: return ".pkg"
        case .manual: return "manual"
        case .mine: return "seu app"
        case .bookmark: return "bookmark"
        case .system: return "veio com o mac"
        }
    }
}

struct AppEntry: Equatable {
    let name: String
    /// Caminho do app ou endereço do bookmark.
    let target: String
    let origin: Origin
    var isApp: Bool { target.hasPrefix("/") }
}

enum AppScanner {
    /// Apps instalados e bookmarks salvos, em ordem alfabética.
    static func all() -> [AppEntry] {
        let receipts = homebrewReceipts()
        var list = installed().map { AppEntry(name: $0.name, target: $0.path, origin: origin(of: $0.path, receipts: receipts)) }
        // Bookmarks: os que já existiam no apps.json (inclusive dentro das antigas pastas).
        let saved = Store.load("apps.json") ?? []
        list += saved.flatMap { $0.isFolder ? $0.children : [$0] }
            .filter { !$0.target.hasPrefix("/") }
            .map { AppEntry(name: $0.name, target: $0.target, origin: .bookmark) }
        return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func installed() -> [(name: String, path: String)] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities", home + "/Applications"]
        var seen = Set<String>()
        var result: [(String, String)] = []
        func add(_ path: String) {
            var name = fm.displayName(atPath: path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            guard seen.insert(name).inserted else { return }
            result.append((name, path))
        }
        for dir in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where n.hasSuffix(".app") && !n.hasPrefix(".") { add(dir + "/" + n) }
        }
        add("/System/Library/CoreServices/Finder.app")
        return result
    }

    /// Texto dos recibos do Homebrew: cada cask registra os apps e pacotes .pkg que instalou.
    static func homebrewReceipts() -> String {
        var text = ""
        for root in ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"] {
            guard let casks = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for c in casks {
                text += (try? String(contentsOfFile: "\(root)/\(c)/.metadata/INSTALL_RECEIPT.json", encoding: .utf8)) ?? ""
            }
        }
        return text
    }

    private static var cache: [String: Origin] = [:]

    static func origin(of path: String, receipts: String) -> Origin {
        if let o = cache[path] { return o }
        let o = classify(path, receipts: receipts)
        cache[path] = o
        return o
    }

    private static func classify(_ path: String, receipts: String) -> Origin {
        let fm = FileManager.default
        // Apps do sistema: em /System, ou (como o Safari) links para a parte protegida do sistema.
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if path.hasPrefix("/System/") || real.hasPrefix("/System/") || real.contains("/Cryptexes/") { return .system }
        if fm.fileExists(atPath: path + "/Contents/_MASReceipt/receipt") { return .appStore }
        let file = (path as NSString).lastPathComponent
        if receipts.contains("\"\(file)\"") || receipts.contains("/\(file)\"") { return .homebrew }
        let bundle = Bundle(path: path)?.bundleIdentifier ?? ""
        if bundle.hasPrefix("com.alan") { return .mine }
        if let pkg = pkgID(path) { return receipts.contains("\"\(pkg)\"") ? .homebrew : .pkg }
        return .manual
    }

    /// Pacote .pkg que instalou o app, se houver (recibo do instalador do macOS).
    private static func pkgID(_ path: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        p.arguments = ["--file-info", path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        for line in out.split(separator: "\n") where line.hasPrefix("pkgid: ") {
            return String(line.dropFirst(7))
        }
        return nil
    }
}

final class FileSearch {
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private let limit: Int
    private let onResults: ([String]) -> Void

    static let iCloudRoot = "/Library/Mobile Documents/com~apple~CloudDocs"

    init(limit: Int, onResults: @escaping ([String]) -> Void) {
        self.limit = limit
        self.onResults = onResults
    }

    func search(_ text: String) {
        stop()
        let t = text.trimmed.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "?", with: "")
        guard !t.isEmpty else {
            onResults([])
            return
        }
        let predicate = NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\(t)*")
        run(predicate, scopes: [NSMetadataQueryUserHomeScope])
    }

    func recents() {
        stop()
        guard let predicate = NSPredicate(fromMetadataQueryString: "kMDItemLastUsedDate >= $time.today(-14)") else { return }
        run(predicate, scopes: [NSMetadataQueryUserHomeScope])
    }

    func stop() {
        query?.stop()
        query = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }

    private func run(_ predicate: NSPredicate, scopes: [Any]) {
        let q = NSMetadataQuery()
        q.predicate = predicate
        q.searchScopes = scopes
        q.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        q.notificationBatchingInterval = 0.05
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryGatheringProgress, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: q, queue: .main) { [weak self] _ in
                self?.collect()
            })
        }
        query = q
        q.start()
    }

    private func collect() {
        guard let q = query else { return }
        q.disableUpdates()
        var paths: [String] = []
        for i in 0..<q.resultCount {
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            if path.hasSuffix(".app") || path.contains("/.") || path.contains(".app/") { continue }
            if path.contains("/Library/") && !path.contains(FileSearch.iCloudRoot) { continue }
            paths.append(path)
            if paths.count >= limit { break }
        }
        q.enableUpdates()
        onResults(paths)
    }
}

enum Translator {
    static func translate(_ text: String, from source: String, to target: String) async -> (text: String?, error: String?) {
        guard #available(macOS 26.0, *) else { return (nil, "tradução exige macOS 26") }
        do {
            let session = TranslationSession(installedSource: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
            let response = try await session.translate(text)
            return (response.targetText, nil)
        } catch {
            return (nil, "idioma não baixado: ajustes > geral > idioma e região > idiomas de tradução")
        }
    }
}

/// Histórico web do Safari (precisa de Acesso Total ao Disco para o Launcher).
enum WebHistory {
    struct Entry {
        let url: URL
        var title: String
        var visits: Int
        var last: Double
        /// Já em minúsculas, para a busca não refazer isso a cada tecla.
        var bare = ""
        var lowTitle = ""
    }

    /// Lido e escrito só na thread principal; a leitura do banco roda em segundo plano.
    private static var cache: [Entry] = []
    private static var cacheKey: [Date?] = []
    private static var loading = false
    private static let queue = DispatchQueue(label: "launcher.historico")

    static let safariDB = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/History.db")

    private static func modDate(_ u: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date
    }

    /// Recarrega o histórico em segundo plano se o Safari gravou algo novo (ao abrir o Launcher).
    static func preload() {
        let key = [modDate(safariDB), modDate(URL(fileURLWithPath: safariDB.path + "-wal"))]
        guard key != cacheKey, !loading else { return }
        loading = true
        queue.async {
            let list = read()
            DispatchQueue.main.async {
                cache = list
                cacheKey = key
                loading = false
            }
        }
    }

    private static func read() -> [Entry] {
        var byURL: [String: Entry] = [:]
        readSafari { s, title, visits, when in
            guard let url = URL(string: s) else { return }
            if var e = byURL[s] {
                e.visits += visits
                if when >= e.last { e.last = when; if !title.isEmpty { e.title = title } }
                byURL[s] = e
            } else {
                byURL[s] = Entry(url: url, title: title, visits: visits, last: when)
            }
        }
        return byURL.values.map { e in
            var e = e
            e.bare = bare(e.url)
            e.lowTitle = e.title.lowercased()
            return e
        }
    }

    /// Lê o History.db do Safari (só leitura). Sem permissão, não faz nada.
    private static func readSafari(_ add: (String, String, Int, Double) -> Void) {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(safariDB.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return }
        sqlite3_busy_timeout(db, 200)
        let sql = """
            SELECT i.url, v.title, i.visit_count, MAX(v.visit_time) FROM history_items i
            JOIN history_visits v ON v.history_item = i.id GROUP BY i.id ORDER BY 4 DESC LIMIT 20000
            """
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        while sqlite3_step(st) == SQLITE_ROW {
            guard let u = sqlite3_column_text(st, 0) else { continue }
            let title = sqlite3_column_text(st, 1).map { String(cString: $0) } ?? ""
            // visit_time conta a partir de 2001; o resto usa 1970.
            add(String(cString: u), title, Int(sqlite3_column_int(st, 2)), sqlite3_column_double(st, 3) + 978_307_200)
        }
    }

    /// Endereço sem esquema nem "www.", para comparar com o que foi digitado.
    static func bare(_ url: URL) -> String {
        var s = url.absoluteString.lowercased()
        for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func search(_ q: String, limit: Int) -> [Entry] {
        let q = q.lowercased()
        var scored: [(Entry, Int)] = []
        for e in cache {
            let score: Int
            if e.bare.hasPrefix(q) { score = e.bare.contains("/") ? 3 : 4 }
            else if e.lowTitle.hasPrefix(q) { score = 2 }
            else if e.bare.contains(q) || e.lowTitle.contains(q) { score = 1 }
            else { continue }
            scored.append((e, score))
        }
        return scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.0.visits != b.0.visits { return a.0.visits > b.0.visits }
            return a.0.last > b.0.last
        }.prefix(limit).map(\.0)
    }
}
