import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LauncherView: View {
    @EnvironmentObject var state: LauncherState
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: state.barTop)
            // Uma caixa só, sem espaços: status, busca, resultados e notificações.
            VStack(spacing: 0) {
                StatusLine()
                Line()
                searchBar
                if showsBalloon {
                    Line()
                    balloon
                }
                // Notificações só aparecem com a barra vazia; ao buscar, dão lugar aos resultados.
                if state.query.isEmpty && state.mode == nil && !state.showQuicklinks && hasNotifications {
                    Line()
                    NotificationColumn()
                }
            }
            .background(Theme.bg)
            .overlay(Rectangle().strokeBorder(Theme.bg2, lineWidth: 1))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .tint(Theme.yellow)
        .transaction { t in
            t.animation = nil
            t.disablesAnimations = true
        }
        .onChange(of: state.query) { _, _ in state.queryChanged() }
        .onChange(of: state.focusToken) { _, _ in fieldFocused = true }
        .onChange(of: state.inBalloon) { _, inside in if inside { fieldFocused = false } }
        .onChange(of: fieldFocused) { _, focused in if focused && state.inBalloon { state.inBalloon = false } }
        .onAppear { fieldFocused = true }
    }

    private var hasNotifications: Bool {
        state.notificationsBlocked || !state.notifications.isEmpty
    }

    private var showsBalloon: Bool {
        state.mode != nil || !state.results.isEmpty
    }

    private var placeholder: String {
        switch state.mode {
        case .none: return "buscar"
        case .ia?: return "pergunte ou peça uma ação"
        case .notas?: return "texto para adicionar ao final"
        case .apps?: return "filtrar apps"
        case .traduzir?: return "texto para traduzir"
        case .terminal?: return "comando para abrir no Terminal"
        case .senhas?: return "buscar senha"
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Text(">")
                .font(Theme.mono(18, .bold))
                .foregroundColor(state.inBalloon ? Theme.gray : Theme.yellow)
            if let mode = state.mode {
                Tag(text: mode.rawValue, color: Theme.yellow)
            }
            ZStack(alignment: .leading) {
                // Placeholder próprio: o prompt do TextField ignora a cor e fica preto.
                if state.query.isEmpty {
                    Text(placeholder)
                        .font(Theme.mono(18))
                        .foregroundColor(Theme.gray)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
                TextField("", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(18))
                    .foregroundColor(state.inBalloon ? Theme.fgDim : Theme.fg)
                    .focused($fieldFocused)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }

    @ViewBuilder private var balloon: some View {
        switch state.mode {
        case .none:
            if state.favoritesActive {
                FavoritesRow()
                Line()
            }
            ResultList(items: state.results, selection: state.inFavorites && state.favoritesActive ? -1 : state.selection,
                       maxHeight: state.balloonMax)
        case .ia?: IABalloon()
        case .notas?: NotesBalloon()
        case .apps?: AppsBalloon()
        case .traduzir?: TranslateBalloon()
        case .terminal?: TerminalBalloon()
        case .senhas?: PasswordsBalloon()
        }
    }
}

/// Linha de cima: data e hora à esquerda; notas (se houver), wi-fi e bateria à direita.
struct StatusLine: View {
    @EnvironmentObject var state: LauncherState

    var body: some View {
        HStack(spacing: 14) {
            Text(state.clockDay + "  " + state.clockTime)
                .foregroundColor(Theme.fg)
            Spacer(minLength: 0)
            if hasNotes {
                Image(systemName: "note.text")
                    .foregroundColor(Theme.yellow)
            }
            if let w = state.wifi {
                Image(systemName: w.connected ? "wifi" : "wifi.slash", variableValue: Double(w.bars) / 3)
                    .foregroundColor(w.connected ? Theme.fg : Theme.gray)
            }
            if let b = state.battery {
                HStack(spacing: 6) {
                    Image(systemName: batterySymbol(b))
                    Text("\(b.percent)%")
                }
                .foregroundColor(b.percent <= 20 && !b.plugged ? Theme.red : Theme.fg)
            }
        }
        .font(Theme.mono(13, .bold))
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    private var hasNotes: Bool {
        state.note.split(separator: "\n").contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func batterySymbol(_ b: BatteryInfo) -> String {
        if b.charging { return "battery.100.bolt" }
        if b.percent >= 88 { return "battery.100" }
        if b.percent >= 63 { return "battery.75" }
        if b.percent >= 38 { return "battery.50" }
        if b.percent >= 13 { return "battery.25" }
        return "battery.0"
    }
}

struct NotificationColumn: View {
    @EnvironmentObject var state: LauncherState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                cards
                    .background(
                        GeometryReader { g in
                            Color.clear
                                .onAppear { state.setNotificationsHeight(g.size.height) }
                                .onChange(of: g.size.height) { _, h in state.setNotificationsHeight(h) }
                        }
                    )
            }
            .scrollIndicators(.never)
            .frame(height: min(state.notificationsHeight, state.notificationsMax))
            .onChange(of: state.notificationSel) { _, s in proxy.scrollTo(s) }
        }
    }

    private var cards: some View {
        VStack(spacing: 0) {
            if state.notificationsBlocked {
                Text("notificações: " + state.notificationsError)
                    .font(Theme.mono(12))
                    .foregroundColor(Theme.gray)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !state.notifications.isEmpty {
                HStack {
                    Text("notificações")
                        .font(Theme.mono(11, .bold))
                        .foregroundColor(Theme.gray)
                    Spacer()
                    Text(state.notificationsFocused ? "⌫ apagar" : "tab para escolher")
                        .font(Theme.mono(11))
                        .foregroundColor(Theme.gray)
                }
                .padding(.horizontal, 14)
                .frame(height: 26)
            }
            // Mais recente no topo.
            ForEach(Array(state.notifications.enumerated()), id: \.offset) { i, n in
                Line()
                NotificationCard(n: n, selected: state.notificationsFocused && i == state.notificationSel)
                    .id(i)
            }
        }
    }
}

struct NotificationCard: View {
    let n: SystemNotification
    let selected: Bool

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(selected ? Theme.yellow : Color.clear)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let path = n.appPath {
                        Image(nsImage: IconCache.file(path))
                            .resizable()
                            .frame(width: 16, height: 16)
                    }
                    Text(n.app.lowercased())
                        .font(Theme.mono(11, .bold))
                        .foregroundColor(selected ? Theme.yellow : Theme.gray)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(SystemStatus.ago(n.date))
                        .font(Theme.mono(11))
                        .foregroundColor(Theme.gray)
                }
                if !n.title.isEmpty {
                    Text(n.title)
                        .font(Theme.mono(13, .bold))
                        .foregroundColor(Theme.fg)
                        .lineLimit(2)
                }
                if !n.subtitle.isEmpty {
                    Text(n.subtitle)
                        .font(Theme.mono(12))
                        .foregroundColor(Theme.fgDim)
                        .lineLimit(1)
                }
                if !n.body.isEmpty {
                    Text(n.body)
                        .font(Theme.mono(12))
                        .foregroundColor(Theme.fgDim)
                        .lineLimit(4)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.bg1 : Color.clear)
    }
}

struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(Theme.mono(13, .bold))
            .foregroundColor(Theme.bgHard)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color)
    }
}

/// Etiqueta pequena com borda, para marcar itens numa lista (ex.: 2FA).
struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(Theme.mono(10, .heavy))
                .tracking(1)
        }
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(color.opacity(0.14))
        .overlay(Rectangle().strokeBorder(color.opacity(0.7), lineWidth: 1))
    }
}

struct Line: View {
    var body: some View {
        Rectangle().fill(Theme.bg2).frame(height: 1)
    }
}

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(Theme.mono(11, .bold))
            .foregroundColor(Theme.gray)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }
}

struct EmptyHint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.mono(13))
            .foregroundColor(Theme.gray)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
    }
}

struct ResultRow: View {
    let item: ResultItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(selected ? Theme.yellow : Color.clear)
                .frame(width: 3)
            icon.frame(width: 18, height: 18)
            Text(item.title)
                .font(Theme.mono())
                .foregroundColor(Theme.fg)
                .lineLimit(1)
                .truncationMode(.middle)
            if let tag = item.tag {
                Badge(text: tag, color: Theme.aqua).fixedSize()
            }
            Spacer(minLength: 8)
            Text(item.detail)
                .font(Theme.mono(12))
                .foregroundColor(Theme.gray)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 200, alignment: .trailing)
                .padding(.trailing, 14)
        }
        .frame(height: Theme.rowHeight)
        .background(selected ? Theme.bg1 : Color.clear)
    }

    @ViewBuilder private var icon: some View {
        if let path = item.iconPath {
            Image(nsImage: IconCache.file(path)).resizable().interpolation(.high)
        } else {
            Image(systemName: item.symbol)
                .font(.system(size: 14))
                .foregroundColor(selected ? Theme.yellow : Theme.fgDim)
        }
    }
}

/// Fileira de apps favoritos; ←→ escolhe, enter abre.
struct FavoritesRow: View {
    @EnvironmentObject var state: LauncherState

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(state.favorites.enumerated()), id: \.offset) { i, path in
                let selected = state.inFavorites && i == state.favoriteSel
                VStack(spacing: 4) {
                    Image(nsImage: IconCache.file(path)).resizable().interpolation(.high)
                        .frame(width: 32, height: 32)
                    Text(Favorites.name(path).lowercased())
                        .font(Theme.mono(11))
                        .foregroundColor(selected ? Theme.yellow : Theme.gray)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64)
                .background(selected ? Theme.bg1 : Color.clear)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(selected ? Theme.yellow : Color.clear).frame(height: 2)
                }
            }
        }
        .padding(.horizontal, Favorites.padding)
        .padding(.vertical, 4)
    }
}

struct ResultList: View {
    let items: [ResultItem]
    let selection: Int
    let maxHeight: CGFloat

    var body: some View {
        let height = min(CGFloat(items.count) * Theme.rowHeight + 8, maxHeight)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        ResultRow(item: item, selected: i == selection)
                            .id(i)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.never)
            .frame(height: height)
            .onChange(of: selection) { _, s in proxy.scrollTo(s) }
        }
    }
}

/// Quicklink apps: lista em ordem alfabética, agrupada pela origem de cada app.
struct AppsBalloon: View {
    @EnvironmentObject var state: LauncherState

    var body: some View {
        let list = state.appsList
        if state.apps.isEmpty {
            EmptyHint("carregando apps…")
        } else if list.isEmpty {
            // Nada achado: o título dos bookmarks continua, com a dica de salvar o site digitado.
            VStack(spacing: 0) {
                EmptyHint("nenhum app")
                header(.bookmark)
            }
            .padding(.bottom, 8)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(groups(list), id: \.0) { origin, items in
                            header(origin)
                            ForEach(items, id: \.0) { i, e in
                                ResultRow(item: ResultItem(title: e.name, detail: e.isApp ? "" : e.target, symbol: e.isApp ? "app" : "bookmark",
                                                           iconPath: e.isApp ? e.target : nil, action: .open(URL(fileURLWithPath: "/"))),
                                          selected: i == state.selection)
                                    .id(i)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
                .scrollIndicators(.never)
                .frame(height: state.balloonMax)
                .onChange(of: state.selection) { _, s in proxy.scrollTo(s) }
            }
        }
    }

    /// Grupos na ordem das origens, com o índice de cada app na lista (o da seleção).
    /// O grupo dos bookmarks aparece mesmo vazio, por causa da dica de salvar.
    private func groups(_ list: [AppEntry]) -> [(Int, [(Int, AppEntry)])] {
        Origin.allCases.compactMap { o in
            let items = list.enumerated().filter { $0.element.origin == o }.map { ($0.offset, $0.element) }
            return items.isEmpty && o != .bookmark ? nil : (o.rawValue, items)
        }.map { ($0.0, $0.1) }
    }

    private func header(_ rawOrigin: Int) -> some View {
        header(Origin(rawValue: rawOrigin) ?? .manual)
    }

    private func header(_ origin: Origin) -> some View {
        HStack {
            Text(origin.title)
                .font(Theme.mono(11, .bold))
            Spacer()
            if origin == .bookmark {
                Text("⌘enter salva")
                    .font(Theme.mono(11))
            }
        }
        .foregroundColor(Theme.gray)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

struct NotesBalloon: View {
    @EnvironmentObject var state: LauncherState

    var body: some View {
        NoteEditor(text: $state.note, focused: state.inBalloon) {
            if !state.inBalloon { state.inBalloon = true }
        }
        .padding(10)
        .frame(height: 280)
    }
}

struct IABalloon: View {
    @EnvironmentObject var state: LauncherState

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView(.vertical) { content }
                .scrollIndicators(.never)
                .frame(height: state.balloonMax)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.iaHistory.indices.contains(state.iaIndex) {
                let entry = state.iaHistory[state.iaIndex]
                HStack(alignment: .top, spacing: 8) {
                    Text("›").foregroundColor(Theme.aqua)
                    Text(entry.question).foregroundColor(Theme.fgDim).textSelection(.enabled)
                }
                .font(Theme.mono(14))
                if entry.answer.isEmpty && entry.phase == .thinking {
                    Text("pensando…")
                        .font(Theme.mono(14))
                        .foregroundColor(Theme.gray)
                } else {
                    Text(entry.answer)
                        .font(Theme.mono(14))
                        .foregroundColor(entry.phase == .error ? Theme.red : Theme.fg)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if !entry.commands.isEmpty {
                    CommandBlock(entry: entry)
                }
                Text("↑↓ histórico  \(state.iaIndex + 1)/\(state.iaHistory.count)")
                    .font(Theme.mono(11))
                    .foregroundColor(Theme.gray)
            } else {
                Text("pergunte algo ao claude")
                    .font(Theme.mono(14))
                    .foregroundColor(Theme.gray)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CommandBlock: View {
    let entry: IAEntry

    var body: some View {
        let phase = entry.phase
        VStack(alignment: .leading, spacing: 0) {
            Text(phase == .confirm ? "confirmar ação" : "comandos")
                .font(Theme.mono(11, .bold))
                .foregroundColor(phase == .confirm ? Theme.orange : Theme.gray)
                .padding([.horizontal, .top], 10)
                .padding(.bottom, 6)
            ForEach(Array(entry.commands.enumerated()), id: \.offset) { _, command in
                Text("$ \(command)")
                    .font(Theme.mono(13))
                    .foregroundColor(phase == .cancelled ? Theme.gray : Theme.fg)
                    .strikethrough(phase == .cancelled)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
            }
            switch phase {
            case .confirm:
                HStack(spacing: 16) {
                    Text("[enter] executar").foregroundColor(Theme.green)
                    Text("[esc] cancelar").foregroundColor(Theme.red)
                }
                .font(Theme.mono(12, .bold))
                .padding(10)
            case .running:
                Text("executando…")
                    .font(Theme.mono(12, .bold))
                    .foregroundColor(Theme.gray)
                    .padding(10)
            case .cancelled:
                Text("✗ cancelado")
                    .font(Theme.mono(12, .bold))
                    .foregroundColor(Theme.red)
                    .padding(10)
            case .done, .failed:
                Line().padding(.top, 8)
                Text(entry.output)
                    .font(Theme.mono(12))
                    .foregroundColor(Theme.fgDim)
                    .lineLimit(12)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                Text(phase == .done ? "✓ concluído" : "✗ erro")
                    .font(Theme.mono(12, .bold))
                    .foregroundColor(phase == .done ? Theme.green : Theme.red)
                    .padding(10)
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgHard)
        .overlay(Rectangle().strokeBorder(phase == .confirm ? Theme.orange : Theme.bg2, lineWidth: 1))
    }
}

struct TranslateBalloon: View {
    @EnvironmentObject var state: LauncherState

    /// Destaque do teclado só com o foco embaixo (tab).
    private func focused(_ i: Int) -> Bool { state.inBalloon && state.picking == nil && state.translateFocus == i }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                chip(state.sourceLang, open: state.picking == 0, focused: focused(0))
                Text("⇄")
                    .font(Theme.mono(15, .bold))
                    .foregroundColor(focused(1) ? Theme.bgHard : Theme.yellow)
                    .padding(.horizontal, 4)
                    .background(focused(1) ? Theme.yellow : Color.clear)
                chip(state.targetLang, open: state.picking == 1, focused: focused(2))
                Spacer()
                Text(state.inBalloon ? "←→ escolhe · enter muda" : "tab para trocar os idiomas")
                    .font(Theme.mono(11))
                    .foregroundColor(Theme.gray)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)

            if state.picking != nil {
                Line()
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(Array(Languages.names.enumerated()), id: \.offset) { i, lang in
                        let on = i == state.pickSel
                        Text(lang.lowercased())
                            .font(Theme.mono(12))
                            .foregroundColor(on ? Theme.bgHard : Theme.fg)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(on ? Theme.yellow : Theme.bg1)
                    }
                }
                .padding(10)
            }

            Line()
            textBlock(state.sourceLang, state.query.isEmpty ? "digite no campo acima" : state.query, state.query.isEmpty ? Theme.gray : Theme.fg)
            Line()
            if let error = state.translationError {
                textBlock(state.targetLang, error, Theme.red)
            } else {
                textBlock(state.targetLang, state.translation.isEmpty ? "—" : state.translation, Theme.aqua)
            }
        }
    }

    private func chip(_ title: String, open: Bool, focused: Bool) -> some View {
        Text(title.lowercased())
            .font(Theme.mono(13))
            .foregroundColor(open || focused ? Theme.bgHard : Theme.fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(open || focused ? Theme.yellow : Theme.bg1)
    }

    private func textBlock(_ label: String, _ text: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.lowercased())
                .font(Theme.mono(11, .bold))
                .foregroundColor(Theme.gray)
            Text(text)
                .font(Theme.mono(15))
                .foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }
}


/// Quicklink senhas: nome e usuário; a senha nunca aparece.
struct PasswordsBalloon: View {
    @EnvironmentObject var state: LauncherState

    var body: some View {
        let list = state.passwordsList
        VStack(spacing: 0) {
            if let error = state.passwordsError {
                EmptyHint(error)
            } else if list.isEmpty {
                EmptyHint(state.passwords.isEmpty ? "nenhuma senha no arquivo" : "nenhuma senha encontrada")
            } else {
                ResultList(items: list.map { e in
                    ResultItem(title: Passwords.displayName(e), detail: e.username, symbol: e.is2FA ? "lock.shield" : "key",
                               iconPath: nil, action: .open(URL(fileURLWithPath: "/")), tag: e.is2FA ? "2FA" : nil)
                }, selection: state.selection, maxHeight: state.balloonMax - 30)
            }
            Line()
            Text("enter copia senha · ⌘enter copia usuário · ⌘o abre o arquivo")
                .font(Theme.mono(11))
                .foregroundColor(Theme.gray)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .frame(height: 30)
        }
    }
}
