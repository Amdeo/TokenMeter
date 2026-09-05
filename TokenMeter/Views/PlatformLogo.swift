import SwiftUI
import AppKit

struct PlatformLogo: View {
    let platform: Platform
    var size: CGFloat = 30

    var body: some View {
        Group {
            if let image = Self.image(for: platform) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(platform == .deepSeek ? size * 0.08 : 0)
            } else {
                Image(systemName: platform.icon)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(platform.tint)
                    .padding(size * 0.2)
            }
        }
        .frame(width: size, height: size)
        .background(platform.tint.opacity(0.09), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(platform.tint.opacity(0.28), lineWidth: 1)
        )
        .accessibilityLabel(platform.rawValue)
    }

    @MainActor
    private static var cache: [Platform: NSImage] = [:]

    @MainActor
    private static func image(for platform: Platform) -> NSImage? {
        if let cached = cache[platform] { return cached }
        guard let url = Bundle.main.url(forResource: platform.iconResourceName, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[platform] = image
        return image
    }
}

extension Platform {
    var iconResourceName: String {
        switch self {
        case .deepSeek: "icon-deepseek"
        case .zhipu: "icon-zhipu"
        case .kimi: "icon-kimi"
        case .openCodeGo: "icon-opencodego"
        case .miniMax: "icon-minimax"
        }
    }
}
