import SwiftUI
import AppKit

struct PlatformLogo: View {
    let definition: any ProviderDefinition
    var size: CGFloat = 30

    var body: some View {
        let metadata = definition.metadata
        Group {
            if let image = Self.image(for: definition.id, resourceName: metadata.iconResourceName) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(size * metadata.iconInsetFraction)
            } else {
                Image(systemName: metadata.fallbackSystemImage)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color(hex: metadata.tintRGB))
                    .padding(size * 0.2)
            }
        }
        .frame(width: size, height: size)
        .background(Color(hex: metadata.tintRGB).opacity(0.09), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(Color(hex: metadata.tintRGB).opacity(0.28), lineWidth: 1)
        )
        .accessibilityLabel(metadata.displayName)
    }

    @MainActor
    private static var cache: [ProviderID: NSImage] = [:]

    @MainActor
    private static func image(for providerID: ProviderID, resourceName: String?) -> NSImage? {
        guard let resourceName else { return nil }
        if let cached = cache[providerID] { return cached }
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[providerID] = image
        return image
    }
}
