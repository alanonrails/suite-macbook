import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

enum Theme {
    static let bg = Color(hex: 0x282828)
    static let bgHard = Color(hex: 0x1D2021)
    static let bg1 = Color(hex: 0x3C3836)
    static let bg2 = Color(hex: 0x504945)
    static let fg = Color(hex: 0xEBDBB2)
    static let fgDim = Color(hex: 0xA89984)
    static let gray = Color(hex: 0x928374)
    static let yellow = Color(hex: 0xFABD2F)
    static let orange = Color(hex: 0xFE8019)
    static let green = Color(hex: 0xB8BB26)
    static let red = Color(hex: 0xFB4934)
    static let aqua = Color(hex: 0x8EC07C)

    /// Seleção de texto: fundo amarelo com texto preto, para contrastar.
    static let selection: [NSAttributedString.Key: Any] = [
        .backgroundColor: NSColor(hex: 0xFABD2F),
        .foregroundColor: NSColor.black
    ]

    static let rowHeight: CGFloat = 32

    static func mono(_ size: CGFloat = 15, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
