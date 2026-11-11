import AppKit
import SwiftUI

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum Mode: String, CaseIterable {
    case terminal, ia, apps, notas, traduzir, senhas
}

enum IAPhase {
    case thinking, answered, confirm, running, done, failed, cancelled, error
}

struct IAEntry {
    var question: String
    var answer: String
    var commands: [String]
    var output: String
    var phase: IAPhase
}

enum ItemAction {
    case open(URL)
    case quicklink(Mode)
}

struct ResultItem {
    let title: String
    let detail: String
    let symbol: String
    let iconPath: String?
    let action: ItemAction
    /// Etiqueta opcional ao lado do detalhe (ex.: 2fa).
    var tag: String? = nil
}

struct GridEntry: Codable, Equatable {
    var id: String
    var name: String
    var target: String
    var children: [GridEntry]
    var isFolder: Bool { target.isEmpty }
}

/// Apps mais usados, na fileira do topo da lista de quicklinks.
enum Favorites {
    static let paths = [
        "/System/Applications/System Settings.app",
        "/System/Library/CoreServices/Finder.app",
        "/Applications/Safari.app",
        "/System/Applications/Passwords.app",
        "/Applications/WhatsApp.app",
        "/System/Applications/Mail.app",
    ].filter { FileManager.default.fileExists(atPath: $0) }

    static func name(_ path: String) -> String {
        (FileManager.default.displayName(atPath: path) as NSString).deletingPathExtension
    }

    /// Largura mínima de cada app; os que cabem se espalham pela linha.
    static let tileWidth: CGFloat = 84
    static let padding: CGFloat = 8

    static func fit(_ width: CGFloat) -> Int { max(Int((width - 2 * padding) / tileWidth), 0) }
}

enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func file(_ path: String) -> NSImage {
        if let image = cache[path] { return image }
        // Apps como o Safari são links simbólicos; o ícone do link vem com a seta de atalho.
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let image = NSWorkspace.shared.icon(forFile: real)
        cache[path] = image
        return image
    }
}

enum Languages {
    static let all: [(name: String, code: String)] = [
        ("Português", "pt-BR"), ("Inglês", "en-US"), ("Espanhol", "es-ES"), ("Francês", "fr-FR"),
        ("Alemão", "de-DE"), ("Italiano", "it-IT"), ("Japonês", "ja-JP"), ("Chinês", "zh-Hans"),
        ("Coreano", "ko-KR"), ("Russo", "ru-RU")
    ]
    static var names: [String] { all.map { $0.name } }
    static func code(_ name: String) -> String { all.first { $0.name == name }?.code ?? "en-US" }
}

final class LauncherState: ObservableObject {
    @Published var query = ""
    @Published var mode: Mode?
    @Published var selection = 0
    @Published var focusToken = 0
    @Published var balloonMax: CGFloat = 500
    @Published var notificationsMax: CGFloat = 300
    @Published var notificationsHeight: CGFloat = 0
    @Published var barTop: CGFloat = 150

    @Published var battery: BatteryInfo?
    @Published var wifi: WifiInfo?
    @Published var clockTime = ""
    @Published var clockDay = ""
    @Published var notifications: [SystemNotification] = []
    @Published var notificationsBlocked = false
    @Published var notificationsError = ""
    private var hiddenNotifications = Set(Store.loadIDs("notificacoes-ocultas.json"))

    @Published var apps: [AppEntry] = [] { didSet { refreshResults() } }
    /// Foco na área de baixo (balão) em vez do campo de busca.
    @Published var inBalloon = false
    /// Lista de todos os quicklinks, aberta com ↓ no campo vazio.
    @Published var showQuicklinks = false { didSet { refreshResults() } }
    /// Foco na fileira de apps favoritos, no topo da lista de quicklinks.
    @Published var inFavorites = false
    @Published var favoriteSel = 0
    /// Quantos favoritos cabem na largura do painel.
    @Published var favoritesFit = Favorites.paths.count
    /// Notificação selecionada quando o foco está nelas (tab com a barra vazia).
    @Published var notificationSel = 0
    /// Tradução, com o foco embaixo: 0 idioma de origem, 1 inverter, 2 idioma de destino.
    @Published var translateFocus = 0
    /// Idioma marcado na lista aberta com enter num dos idiomas.
    @Published var pickSel = 0

    /// Quicklink senhas: lido do CSV toda vez que o quicklink abre.
    @Published var passwords: [PasswordEntry] = []
    @Published var passwordsError: String?

    @Published var fileHits: [String] = [] { didSet { refreshResults() } }

    @Published var iaHistory: [IAEntry] = []
    @Published var iaIndex = -1

    @Published var sourceLang = "Português"
    @Published var targetLang = "Inglês"
    @Published var picking: Int?
    @Published var translation = ""
    @Published var translationError: String?

    @Published var termHistory: [String] = (Store.readText("terminal-historico.txt") ?? "")
        .split(separator: "\n").map(String.init) {
        didSet { Store.writeText(termHistory.joined(separator: "\n"), "terminal-historico.txt") }
    }
    @Published var termError: String?
    /// Comando escolhido na lista de últimos comandos (0 = mais recente); nil = no campo.
    @Published private(set) var termRecall: Int?

    @Published var note: String = Store.readText("notas.txt") ?? "" {
        didSet { if note != oldValue { Store.writeText(note, "notas.txt") } }
    }

    var hidePanel: (() -> Void)?
    private lazy var quickSearch = FileSearch(limit: 5) { [weak self] paths in self?.fileHits = paths }
    private var translateTask: Task<Void, Never>?

    init() {
        refreshApps()
    }

    private var trimmedQuery: String { query.trimmed.lowercased() }

    func reloadFromDisk() {
        let text = Store.readText("notas.txt") ?? ""
        if text != note { note = text }
        hiddenNotifications = Set(Store.loadIDs("notificacoes-ocultas.json"))
    }

    /// ⌘espaço reabre como estava ao fechar; só relê os arquivos, que podem ter mudado.
    func resume() {
        reloadFromDisk()
        if mode == .senhas { loadPasswords() }
        selection = min(selection, max(itemCount - 1, 0))
        inBalloon = false
    }

    func activate(_ m: Mode) {
        mode = m
        query = ""
        selection = 0
        picking = nil
        inBalloon = false
        showQuicklinks = false
        translateFocus = 0
        iaIndex = iaHistory.count - 1
        termRecall = nil
        termError = nil
        if m == .senhas { loadPasswords() }
    }

    private func loadPasswords() {
        let r = Passwords.load()
        passwords = r.entries
        passwordsError = r.error
    }

    func queryChanged() {
        selection = 0
        if !query.isEmpty { showQuicklinks = false }
        refreshResults()
        switch mode {
        case .none:
            quickSearch.search(query)
        case .traduzir?:
            scheduleTranslate()
        default:
            break
        }
    }

    func tab() -> Bool {
        guard mode == nil, let m = Mode(rawValue: trimmedQuery) else { return false }
        activate(m)
        return true
    }

    func focusField() {
        inBalloon = false
        focusToken += 1
    }

    /// Tab: leva o foco para a área de baixo, se houver algo nela.
    func enterBalloon() {
        let ok: Bool
        switch mode {
        case .none:
            // Sem resultados, o tab vai para as notificações.
            ok = !results.isEmpty || (query.isEmpty && !notifications.isEmpty)
            notificationSel = 0
        case .notas?: ok = true
        case .apps?: ok = !appsList.isEmpty
        case .ia?: ok = false
        case .terminal?: ok = false
        case .traduzir?: ok = true
        case .senhas?: ok = !passwordsList.isEmpty
        }
        if ok { inBalloon = true }
    }

    private static let notificationQueue = DispatchQueue(label: "launcher.notificacoes")

    func dismissNotification(_ id: Int64) {
        hiddenNotifications.insert(id)
        saveHiddenNotifications()
        notifications.removeAll { $0.id == id }
    }

    /// Foco nas notificações: tab com a barra vazia e sem resultados.
    var notificationsFocused: Bool { inBalloon && mode == nil && results.isEmpty }

    func moveNotification(_ d: Int) {
        guard !notifications.isEmpty else { return }
        notificationSel = min(max(notificationSel + d, 0), notifications.count - 1)
    }

    func dismissSelectedNotification() {
        guard notifications.indices.contains(notificationSel) else { return }
        dismissNotification(notifications[notificationSel].id)
        notificationSel = min(notificationSel, max(notifications.count - 1, 0))
        if notifications.isEmpty { focusField() }
    }

    private func saveHiddenNotifications() {
        Store.saveIDs(Array(hiddenNotifications), "notificacoes-ocultas.json")
    }

    func setNotificationsHeight(_ h: CGFloat) {
        DispatchQueue.main.async {
            if abs(self.notificationsHeight - h) > 0.5 { self.notificationsHeight = h }
        }
    }

    func refreshStatus() {
        battery = SystemStatus.battery()
        wifi = SystemStatus.wifi()
        let now = Date()
        clockTime = SystemStatus.time(now)
        clockDay = SystemStatus.day(now)
        Self.notificationQueue.async {
            let list = NotificationReader.read()
            let error = NotificationReader.lastError
            DispatchQueue.main.async {
                self.notificationsError = error
                let all = list ?? []
                if list != nil {
                    let pruned = self.hiddenNotifications.intersection(all.map { $0.id })
                    if pruned != self.hiddenNotifications {
                        self.hiddenNotifications = pruned
                        self.saveHiddenNotifications()
                    }
                }
                self.notifications = all.filter { !self.hiddenNotifications.contains($0.id) }
                self.notificationsBlocked = list == nil
            }
        }
    }

    private static let appsQueue = DispatchQueue(label: "launcher.apps")

    func refreshApps() {
        Self.appsQueue.async {
            let list = AppScanner.all()
            DispatchQueue.main.async {
                if list != self.apps { self.apps = list }
            }
        }
    }

    /// Resultados da busca, calculados uma vez por mudança (e não a cada redesenho da tela).
    @Published private(set) var results: [ResultItem] = []

    func refreshResults() {
        let r = computeResults()
        if r.map(\.title) != results.map(\.title) || r.map(\.detail) != results.map(\.detail) { results = r }
    }

    private func computeResults() -> [ResultItem] {
        let q = trimmedQuery
        guard !q.isEmpty else {
            guard showQuicklinks else { return [] }
            return Mode.allCases.map { ResultItem(title: $0.rawValue, detail: "quicklink", symbol: "arrow.right.square", iconPath: nil, action: .quicklink($0)) }
        }
        var list: [ResultItem] = Mode.allCases
            .filter { $0.rawValue.hasPrefix(q) }
            .map { ResultItem(title: $0.rawValue, detail: "quicklink", symbol: "arrow.right.square", iconPath: nil, action: .quicklink($0)) }
        list += Self.rank(apps, q).prefix(5).compactMap { e in
            if e.isApp {
                return ResultItem(title: e.name, detail: e.origin.short, symbol: "app", iconPath: e.target, action: .open(URL(fileURLWithPath: e.target)))
            }
            return URL(string: e.target).map { ResultItem(title: e.name, detail: e.origin.short, symbol: "bookmark", iconPath: nil, action: .open($0)) }
        }
        list += fileHits.prefix(5).map(Self.fileItem)
        list += WebHistory.search(q, limit: 5).map { e in
            ResultItem(title: e.title.isEmpty ? WebHistory.bare(e.url) : e.title, detail: WebHistory.bare(e.url),
                       symbol: "clock", iconPath: nil, action: .open(e.url))
        }
        if let url = Self.guessURL(query) {
            list.append(ResultItem(title: url.absoluteString, detail: "link", symbol: "globe", iconPath: nil, action: .open(url)))
        }
        if let url = Self.searchURL(query) {
            list.append(ResultItem(title: query.trimmed, detail: "google", symbol: "magnifyingglass", iconPath: nil, action: .open(url)))
        }
        return list
    }

    /// Quicklink apps: agrupado pela origem, em ordem alfabética dentro de cada grupo.
    var appsList: [AppEntry] {
        let q = trimmedQuery
        let list = q.isEmpty ? apps : apps.filter { $0.name.lowercased().contains(q) }
        return list.sorted { a, b in
            if a.origin != b.origin { return a.origin.rawValue < b.origin.rawValue }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Quicklink senhas: busca no nome e no usuário (a senha fica de fora).
    var passwordsList: [PasswordEntry] {
        let q = trimmedQuery
        let list = q.isEmpty ? passwords : passwords.filter { e in
            [e.name, e.username].contains { $0.lowercased().contains(q) }
        }
        return list.sorted { Passwords.displayName($0).localizedCaseInsensitiveCompare(Passwords.displayName($1)) == .orderedAscending }
    }

    private var itemCount: Int {
        switch mode {
        case .none: return results.count
        case .apps?: return appsList.count
        case .senhas?: return passwordsList.count
        default: return 0
        }
    }

    func move(_ delta: Int) {
        if mode == .terminal {
            recall(delta)
            return
        }
        if mode == .ia {
            guard !iaHistory.isEmpty, iaHistory.last?.phase != .confirm else { return }
            iaIndex = min(max(iaIndex + delta, 0), iaHistory.count - 1)
            return
        }
        // Lista de quicklinks: ↓ sai dos favoritos, ↑ no primeiro quicklink volta para eles.
        if favoritesActive {
            if inFavorites {
                if delta > 0 { inFavorites = false; selection = 0 }
                return
            }
            if delta < 0 && selection == 0 { inFavorites = true; return }
        }
        let count = itemCount
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    func openQuicklinks() {
        mode = nil
        selection = 0
        inFavorites = !favorites.isEmpty
        favoriteSel = 0
        showQuicklinks = true
    }

    /// Favoritos que cabem; os últimos saem primeiro.
    var favorites: [String] { Array(Favorites.paths.prefix(favoritesFit)) }

    var favoritesActive: Bool { mode == nil && showQuicklinks && !favorites.isEmpty }

    /// ←→ na fileira de favoritos. Retorna false se o foco não está nela.
    func moveFavorite(_ d: Int) -> Bool {
        guard favoritesActive && inFavorites else { return false }
        favoriteSel = min(max(favoriteSel + d, 0), favorites.count - 1)
        return true
    }

    func escape() -> Bool {
        if showQuicklinks && mode == nil {
            showQuicklinks = false
            if inBalloon { focusField() }
            return false
        }
        if mode == .ia, iaIndex >= 0, iaIndex == iaHistory.count - 1, iaHistory[iaIndex].phase == .confirm {
            iaHistory[iaIndex].phase = .cancelled
            return false
        }
        return true
    }

    func back() -> Bool {
        if mode != nil {
            mode = nil
            selection = 0
            return true
        }
        return false
    }

    func perform(_ action: ItemAction) {
        switch action {
        case .quicklink(let m):
            activate(m)
        case .open(let url):
            Self.openURL(url)
            hidePanel?()
        }
    }

    /// Com o Safari fechado, abrir youtube.com (que redireciona para www.youtube.com)
    /// faz ele baixar a página como .html. Então, se o navegador estiver fechado,
    /// segue o redirecionamento antes e entrega ao navegador o endereço final.
    static func openURL(_ url: URL) {
        let ws = NSWorkspace.shared
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let browser = ws.urlForApplication(toOpen: url),
              let id = Bundle(url: browser)?.bundleIdentifier,
              NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
        else {
            ws.open(url)
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 1.5)
        request.httpMethod = "HEAD"
        // Sem isso o YouTube redireciona para a versão de celular (m.youtube.com).
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let final = response?.url ?? url
            DispatchQueue.main.async { ws.open(final) }
        }.resume()
    }

    func openEntry(_ e: AppEntry) {
        if e.isApp {
            perform(.open(URL(fileURLWithPath: e.target)))
        } else if let url = URL(string: e.target) {
            perform(.open(url))
        }
    }

    func submit() {
        switch mode {
        case .none:
            if favoritesActive && inFavorites {
                let list = favorites
                if list.indices.contains(favoriteSel) { perform(.open(URL(fileURLWithPath: list[favoriteSel]))) }
                return
            }
            let r = results
            if r.indices.contains(selection) { perform(r[selection].action) }
        case .apps?:
            let list = appsList
            if list.indices.contains(selection) { openEntry(list[selection]) }
        case .notas?:
            let text = query.trimmed
            guard !text.isEmpty else { return }
            note += (note.isEmpty || note.hasSuffix("\n") ? "" : "\n") + text
            query = ""
        case .ia?:
            submitIA()
        case .terminal?:
            runTerminal()
        case .traduzir?:
            guard !translation.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(translation, forType: .string)
            hidePanel?()
        case .senhas?:
            copyPassword(user: false)
        }
    }

    /// Enter copia a senha; ⌘enter copia o usuário.
    func copyPassword(user: Bool) {
        let list = passwordsList
        guard list.indices.contains(selection) else { return }
        let e = list[selection]
        if !user && e.is2FA { return }
        let text = user ? e.username : e.password
        guard !text.isEmpty else { return }
        Passwords.copy(text)
        hidePanel?()
    }

    private func submitIA() {
        if let last = iaHistory.indices.last, iaIndex == last, iaHistory[last].phase == .confirm {
            iaHistory[last].phase = .running
            ClaudeRunner.shared.execute(iaHistory[last].commands) { [weak self] output, ok in
                guard let self, self.iaHistory.indices.contains(last) else { return }
                self.iaHistory[last].output = output.trimmed.isEmpty ? "(sem saída)" : output.trimmed
                self.iaHistory[last].phase = ok ? .done : .failed
            }
            return
        }
        let q = query.trimmed
        guard !q.isEmpty else { return }
        if let phase = iaHistory.last?.phase, phase == .thinking || phase == .running { return }
        iaHistory.append(IAEntry(question: q, answer: "", commands: [], output: "", phase: .thinking))
        let idx = iaHistory.count - 1
        iaIndex = idx
        query = ""
        ClaudeRunner.shared.ask(q, onText: { [weak self] text in
            guard let self, self.iaHistory.indices.contains(idx) else { return }
            self.iaHistory[idx].answer = ClaudeRunner.split(text).answer
        }, onDone: { [weak self] text, error in
            guard let self, self.iaHistory.indices.contains(idx) else { return }
            if let error {
                self.iaHistory[idx].answer = error
                self.iaHistory[idx].phase = .error
                return
            }
            let parts = ClaudeRunner.split(text)
            self.iaHistory[idx].answer = parts.answer
            self.iaHistory[idx].commands = parts.commands
            self.iaHistory[idx].phase = parts.commands.isEmpty ? .answered : .confirm
        })
    }

    private func runTerminal() {
        let command = query.trimmed
        guard !command.isEmpty else { return }
        termRecall = nil
        if let error = TerminalRunner.open(command) {
            termError = error
            return
        }
        termError = nil
        termHistory.removeAll { $0 == command }
        termHistory.append(command)
        if termHistory.count > 100 { termHistory.removeFirst(termHistory.count - 100) }
        query = ""
        hidePanel?()
    }

    /// Últimos comandos, do mais recente ao mais antigo.
    var termRecent: [String] { termHistory.reversed() }

    /// ↓ desce pela lista de últimos comandos; ↑ sobe e, no topo, volta ao campo vazio.
    private func recall(_ delta: Int) {
        let commands = termRecent
        guard !commands.isEmpty else { return }
        let i = (termRecall ?? -1) + delta
        if i < 0 {
            termRecall = nil
            query = ""
            return
        }
        termRecall = min(i, commands.count - 1)
        query = commands[termRecall!]
    }

    private func scheduleTranslate() {
        translateTask?.cancel()
        let text = query.trimmed
        guard !text.isEmpty else {
            translation = ""
            translationError = nil
            return
        }
        let source = Languages.code(sourceLang)
        let target = Languages.code(targetLang)
        translateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            let result = await Translator.translate(text, from: source, to: target)
            if Task.isCancelled { return }
            self?.translation = result.text ?? ""
            self?.translationError = result.error
        }
    }

    func languagesChanged() {
        if mode == .traduzir { scheduleTranslate() }
    }

    static func rank(_ items: [AppEntry], _ q: String) -> [AppEntry] {
        items.filter { $0.name.lowercased().contains(q) }.sorted { a, b in
            let pa = a.name.lowercased().hasPrefix(q)
            let pb = b.name.lowercased().hasPrefix(q)
            if pa != pb { return pa }
            return a.name.count < b.name.count
        }
    }

    /// ⌘enter no quicklink apps com um site digitado: salva como bookmark (no apps.json).
    func addBookmark() {
        guard let url = Self.guessURL(query) else { return }
        var name = url.host ?? url.absoluteString
        if name.hasPrefix("www.") { name.removeFirst(4) }
        if let dot = name.firstIndex(of: ".") { name = String(name[..<dot]) }
        var saved = Store.load("apps.json") ?? []
        saved.append(GridEntry(id: UUID().uuidString, name: name, target: url.absoluteString, children: []))
        Store.save(saved, "apps.json")
        query = ""
        refreshApps()
    }

    // MARK: tradução pelo teclado

    /// ←/→ entre origem, inverter e destino; com a lista de idiomas aberta, anda por ela (4 colunas).
    func translateMove(_ dx: Int, _ dy: Int) {
        if picking != nil {
            let n = Languages.names.count
            let next = pickSel + dx + dy * 4
            if next >= 0 && next < n { pickSel = next }
            return
        }
        translateFocus = min(max(translateFocus + dx, 0), 2)
    }

    /// Enter: inverte os idiomas, abre a lista de idiomas ou escolhe o marcado nela.
    func translateEnter() {
        if let side = picking {
            let lang = Languages.names[pickSel]
            if side == 0 { sourceLang = lang } else { targetLang = lang }
            picking = nil
            languagesChanged()
            return
        }
        if translateFocus == 1 {
            swap(&sourceLang, &targetLang)
            languagesChanged()
            return
        }
        let side = translateFocus == 0 ? 0 : 1
        picking = side
        pickSel = Languages.names.firstIndex(of: side == 0 ? sourceLang : targetLang) ?? 0
    }

    static func fileItem(_ path: String) -> ResultItem {
        let ns = path as NSString
        var dir = (ns.deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        if let r = dir.range(of: "~" + FileSearch.iCloudRoot) { dir.replaceSubrange(r, with: "iCloud Drive") }
        return ResultItem(title: ns.lastPathComponent, detail: dir, symbol: "doc", iconPath: path, action: .open(URL(fileURLWithPath: path)))
    }

    static func guessURL(_ text: String) -> URL? {
        let t = text.trimmed
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        if t.contains("://") { return URL(string: t) }
        return URL(string: t.contains(".") ? "https://\(t)" : "https://\(t).com")
    }

    static func searchURL(_ text: String) -> URL? {
        guard let q = text.trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics), !q.isEmpty else { return nil }
        return URL(string: "https://www.google.com/search?q=\(q)")
    }
}
