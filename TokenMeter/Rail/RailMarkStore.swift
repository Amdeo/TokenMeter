import AppKit
import SwiftUI

/// 悬浮条上的供应商标记。
///
/// 标记是**单色模板图**，随视图的 `foregroundStyle` 染色。
/// 优先用矢量：`fill="currentColor"`、`viewBox 0 0 24 24` 的 SVG，任何尺寸都锐利。
/// 中转站这类只有一张彩色应用图标的品牌没有矢量可拿，从里面剥出来的单色剪影只能是位图，
/// 那就放一张**透明背景的单色 PNG**——比在条上画一个通用系统图标强，但它只在预算尺寸内锐利。
/// 两种资源都随 `Rail/Marks/` 一起进 bundle，Xcode 的同步组会把它们平铺到
/// `Contents/Resources/` 根下（与 `Providers/Extensions/<id>/icon-*.png` 同样的路径规则）。
///
/// 两个坑，都来自 SVG 本身：
/// - SVG 声明 `width="1em"`，`NSImage` 会把它读成 1×1pt 的固有尺寸，直接缩放会糊，
///   所以加载后显式给一个够大的尺寸，之后只做向下缩放。
/// - 图稿只有 alpha 有意义，必须标成模板图，否则 `foregroundStyle` 染不上色。
@MainActor
enum RailMarkStore {
    /// 远高于任何实际绘制尺寸，保证缩放只向下。
    private static let renderSize = NSSize(width: 256, height: 256)

    private static var images: [String: NSImage] = [:]
    /// 已经确认加载失败的资源名，避免每次重绘都去查一次 bundle。
    private static var missing: Set<String> = []

    static func image(named name: String) -> NSImage? {
        if let cached = images[name] { return cached }
        guard !missing.contains(name) else { return nil }
        guard let url = resourceURL(named: name),
              let image = NSImage(contentsOf: url)
        else {
            missing.insert(name)
            return nil
        }
        image.size = renderSize
        image.isTemplate = true
        images[name] = image
        return image
    }

    /// 先找矢量，再找位图。
    ///
    /// 同名两种格式都在时矢量赢：它是那个在任何尺寸下都锐利的版本。
    private static func resourceURL(named name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "svg")
            ?? Bundle.main.url(forResource: name, withExtension: "png")
    }

    /// 测试用：清空缓存，让下一次查询重新读 bundle。
    static func resetCache() {
        images.removeAll()
        missing.removeAll()
    }
}

/// 供应商的单色标记：有矢量 mark 就用它，没有就回落 SF Symbol。
///
/// **悬浮条与设置窗口共用这一个视图**——两处的标记必须是同一套，
/// 否则同一个订阅在条上和窗口里长得不一样。
struct ProviderMarkView: View {
    let resource: String?
    let fallbackSystemImage: String
    let size: CGFloat
    var tint: Color = TM.textPrimary

    var body: some View {
        Group {
            if let resource, let image = RailMarkStore.image(named: resource) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
            } else {
                // 没有单色标记就用 SF Symbol，**不回落到面板那张彩色 PNG**：
                // 把一张整块上色的应用图标按模板渲染出来是一团认不出来的纯色方块。
                Image(systemName: fallbackSystemImage)
                    .resizable()
                    .scaledToFit()
            }
        }
        .foregroundStyle(tint)
        .frame(width: size, height: size)
    }
}
