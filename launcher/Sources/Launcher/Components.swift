import AppKit
import SwiftUI

// MARK: - Editor de notas

/// Editor de texto AppKit: permite seleção com texto preto sobre amarelo e foco controlado pelo Tab.
struct NoteEditor: NSViewRepresentable {
    @Binding var text: String
    let focused: Bool
    let onFocus: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteEditor
        init(_ parent: NoteEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NoteScrollView()
        sv.drawsBackground = false
        sv.borderType = .noBorder
        sv.hasVerticalScroller = false
        sv.hasHorizontalScroller = false
        sv.horizontalScrollElasticity = .none

        let tv = NoteTextView(frame: NSRect(origin: .zero, size: sv.contentSize))
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: sv.contentSize.width, height: CGFloat.greatestFiniteMagnitude)

        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let fg = NSColor(hex: 0xEBDBB2)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.font = font
        tv.textColor = fg
        tv.typingAttributes = [.font: font, .foregroundColor: fg]
        tv.drawsBackground = false
        tv.insertionPointColor = NSColor(hex: 0xFABD2F)
        tv.selectedTextAttributes = Theme.selection
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.textContainerInset = NSSize(width: 2, height: 4)
        tv.string = text
        tv.delegate = context.coordinator
        tv.onFocus = onFocus
        sv.documentView = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = sv.documentView as? NoteTextView else { return }
        tv.onFocus = onFocus
        if tv.string != text {
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            tv.scrollToEndOfDocument(nil)
        }
        if focused, tv.window?.firstResponder !== tv {
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }
}

/// Mantém o texto exatamente na largura da caixa: quebra linha em vez de rolar na horizontal.
final class NoteScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let doc = documentView, abs(doc.frame.width - contentSize.width) > 0.5 else { return }
        doc.setFrameSize(NSSize(width: contentSize.width, height: doc.frame.height))
    }
}

final class NoteTextView: NSTextView {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { DispatchQueue.main.async { self.onFocus?() } }
        return ok
    }
}

// MARK: - Terminal

struct TerminalBalloon: View {
    @EnvironmentObject var state: LauncherState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let error = state.termError {
                    Text(error).foregroundColor(Theme.red).lineLimit(2)
                } else {
                    Text("abre numa janela nova do Terminal").foregroundColor(Theme.fgDim)
                }
                Spacer(minLength: 8)
                Text(state.termHistory.isEmpty ? "enter executa" : "enter executa · ↓ últimos")
                    .foregroundColor(Theme.gray)
            }
            .font(Theme.mono(11))
            .padding(.horizontal, 14)
            .frame(height: 26)
            if !state.termHistory.isEmpty {
                Line()
                ResultList(items: state.termRecent.map {
                    ResultItem(title: $0, detail: "", symbol: "terminal", iconPath: nil, action: .open(URL(fileURLWithPath: "/")))
                }, selection: state.termRecall ?? -1, maxHeight: state.balloonMax)
            }
        }
    }
}
