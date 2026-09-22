import AppKit
import Testing
@testable import TokenMeter

/// 悬浮条标记资源回归：标记必须真的进了 app bundle，且按模板图加载。
///
/// 这组断言同时是「`Rail/Marks/` 这个文件系统同步组会不会把图片资源拷贝进 bundle」
/// 的验证——加载不到就说明同步组没有处理它，标记得改走别的路线。
@MainActor
struct RailMarkTests {
    /// 与 `ProviderMetadata.railMarkResource` 声明的资源名一致。
    /// `apikeyfun` 是唯一一张位图标记：那个品牌只有彩色应用图标，没有矢量可取。
    private static let svgMarks = [
        "claude", "openai", "deepseek", "kimi", "minimax", "opencode", "zai",
    ]
    private static let rasterMarks = ["apikeyfun"]
    private static var allMarks: [String] { svgMarks + rasterMarks }

    @Test
    func everyMarkShipsInTheBundle() throws {
        for name in Self.svgMarks {
            let url = try #require(
                Bundle.main.url(forResource: name, withExtension: "svg"),
                "标记 \(name).svg 没有进 bundle"
            )
            #expect(url.isFileURL)
        }
        // 同步组对图片资源的拷贝路径与 `.swift` 不同，位图要单独确认一次。
        for name in Self.rasterMarks {
            let url = try #require(
                Bundle.main.url(forResource: name, withExtension: "png"),
                "标记 \(name).png 没有进 bundle"
            )
            #expect(url.isFileURL)
        }
    }

    @Test
    func everyMarkLoadsAsATemplateImage() throws {
        RailMarkStore.resetCache()
        for name in Self.allMarks {
            let image = try #require(RailMarkStore.image(named: name), "标记 \(name) 加载失败")
            #expect(image.isTemplate, "标记 \(name) 不是模板图，染色会失效")
            // SVG 声明 width="1em"，不显式设尺寸的话固有大小是 1×1pt。
            #expect(image.size.width > 1, "标记 \(name) 的固有尺寸没被撑开")
            #expect(image.size.height > 1)
            #expect(!image.representations.isEmpty)
        }
    }

    @Test
    func markDrawingIsNotBlank() throws {
        RailMarkStore.resetCache()
        for name in Self.allMarks {
            let image = try #require(RailMarkStore.image(named: name))
            // 标记是纯 alpha 图形；画不出东西说明解析成了空图，
            // 那种情况下环里会是一块空白而不是一个 logo。
            #expect(Self.inkCoverage(of: image) > 0.02, "标记 \(name) 画出来几乎是空白")
        }
    }

    /// 位图标记的墨必须是**实的**。
    ///
    /// 从彩色图标剥剪影时，很容易把墨留在中间灰上（整张图就成了半透明），
    /// 染出来比旁边那些矢量标记淡一大截——而这件事在代码里看不出来，只有渲染出来才发现。
    @Test
    func rasterMarksAreSolidInkRatherThanHalfTransparent() throws {
        RailMarkStore.resetCache()
        for name in Self.rasterMarks {
            let image = try #require(RailMarkStore.image(named: name))
            let peak = Self.peakAlpha(of: image)
            #expect(peak > 0.95, "标记 \(name) 最实的墨只有 \(peak)，染出来会发灰")
        }
    }

    @Test
    func unknownMarkIsReportedMissingRatherThanFaked() {
        RailMarkStore.resetCache()
        #expect(RailMarkStore.image(named: "definitely-not-a-mark") == nil)
    }

    /// 把标记画进一个 64×64 的位图，返回非透明像素占比。
    private static func inkCoverage(of image: NSImage) -> Double {
        guard let rep = rendered(image, side: 64) else { return 0 }
        var inked = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                inked += 1
            }
        }
        return Double(inked) / Double(rep.pixelsWide * rep.pixelsHigh)
    }

    /// 画出来最实的那一点有多不透明。整张图都停在中间灰就是「剥剪影时没归一化」。
    private static func peakAlpha(of image: NSImage) -> Double {
        guard let rep = rendered(image, side: 64) else { return 0 }
        var peak = 0.0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                peak = max(peak, rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
            }
        }
        return peak
    }

    /// 用与 `ProviderMarkView` 相同的方式把标记画进位图：模板渲染，只留 alpha。
    private static func rendered(_ image: NSImage, side: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        NSColor.black.set()
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        context.flushGraphics()
        return rep
    }
}
