import SwiftUI
import UIKit

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

enum ASDTheme {
    static let bg = Color(hex: 0xFFFEFA)        // 奶油底
    static let card = Color(hex: 0xF1F1EF)      // 卡片灰
    static let ink = Color(hex: 0x000000)
    static let subtle = Color(hex: 0x1F2329, alpha: 0.6)  // 隐私说明
    static let brand = Color(hex: 0x0066FF)     // yomoa 品牌蓝
}

/// 从 bundle 加载图(loose PNG，UIImage(named:) 可找到)
func bundleImage(_ name: String) -> Image {
    if let ui = UIImage(named: name) { return Image(uiImage: ui) }
    return Image(systemName: "photo")
}
