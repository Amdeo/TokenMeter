import SwiftUI

/// 条与卡片的填充。
///
/// 移植自 Pulse 的 `PanelSurface`，改名是必须的：`Views/MenuBarView.swift` 已经有一个
/// 同名的 `PanelSurface`（面板的页面外壳），两者含义完全不同。
///
/// **用的是实心填充，不是面板那套玻璃。** 面板可以走 `TMPanelBackground` 是因为它是个圆角矩形；
/// 条的轮廓是贴着屏幕边的泊位形状，`LiquidGlassBackground` 自带的圆角矩形套不进去。
/// 而且条一整天悬在用户的任意内容之上，实心表面是唯一在什么背景上都读得清的那个——
/// Pulse 的注释里写的是同一个结论。
///
/// 颜色仍取 `TM` 的自适应令牌，所以它跟着 app 的浅色/深色走，不会自成一套。
/// 用户在设置里开着玻璃且系统支持时，交给 `glassEffect` 直接吃这个形状。
struct RailSurface<S: Shape>: View {
    let shape: S
    let glassEnabled: Bool
    /// 某个额度快到临界时给表面染色；nil 表示保持中性。
    var tint: Color?
    /// 描边颜色；nil 表示不描边。
    ///
    /// **贴边的条不描边**：它是焊在屏幕边上的，整圈描边会在屏幕边缘留下一条 1pt 的细线，
    /// 而那正是「贴着边」最不该有的东西。悬浮的条和详情卡片是自由站立的，
    /// 亮色外观下它们可能是白底、贴在浅色壁纸上会看不出来，所以那两种要描。
    var stroke: Color?

    var body: some View {
        // 刻意可命中，而且没有它条就拖不动：只有窗口里的某个东西认领了那个点，
        // 窗口才会收到那次按下，而这个表面是覆盖环之间那一片空白的唯一东西。
        // 这里认领它没有任何风险：拖动是窗口自己在 `RailWindow.sendEvent` 里接的，
        // 早于任何视图看到事件，所以这里没有可以从它手上抢走按下的把手。
        surface
            // 认领到胶囊自己的轮廓上而不是它的外接矩形，于是整条胶囊都能被抓住，
            // 它没填满的四个角仍然让点击穿过去落到背后的东西上。
            .contentShape(shape)
    }

    @ViewBuilder
    private var surface: some View {
        if glassEnabled, #available(macOS 26.0, *) {
            Color.clear.glassEffect(.clear.tint(tint), in: shape)
        } else {
            shape
                .fill(tint ?? TM.panelMid)
                .overlay {
                    if let stroke {
                        // `stroke` 而不是 `strokeBorder`：这些形状不是 `InsettableShape`，
                        // 而且 1pt 的居中描边在这里看不出差别。
                        shape.stroke(stroke, lineWidth: 1)
                    }
                }
        }
    }
}
