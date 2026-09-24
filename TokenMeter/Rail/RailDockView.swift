import SwiftUI

/// 悬浮条本身，不论它当前是完整展开、卷成贴着屏幕边的细条，还是两者之间的某一刻。
///
/// 移植自 Pulse 的 `UsageDockView`，去掉 bot 动画标记与第二圈。
///
/// 两种状态曾经是两个视图互相替换，那正是细条读起来像**消失**、而条像在它位置上
/// **出现**的原因。它们是同一个东西：一个泊位，尺寸与轮廓都是动画的，
/// 环在它张得足够大之后淡入。
struct RailDockView: View {
    let entries: [RailEntry]
    let edge: RailEdge
    /// 融在屏幕边上，还是自由站在桌面上。只有剪影会变：贴边时外扩进屏幕边，
    /// 悬浮时收成一个胶囊。
    var isDocked: Bool = true
    /// 展开，还是卷成了细条。
    var isExpanded: Bool = true
    var notchSize: CGSize?
    /// 某个额度快到临界时给细条染色。
    var alert: Color?
    let selectedID: UUID?
    let glassEnabled: Bool
    /// 条的尺寸预算。窗口按同一份算，两处必须一致。
    var metrics = RailMetrics()
    /// 环上画什么（倒数、第二圈、窗口时钟、活动动画）。
    var options = RailRingOptions()
    /// 正在取数：开着活动动画时环上会跑一段弧。
    var isRefreshing = false

    private var railSize: CGSize {
        metrics.size(for: entries.count, on: edge.axis, docked: isDocked)
    }

    private var currentSize: CGSize {
        isExpanded ? railSize : RailLayout.collapsedSize(on: edge.axis)
    }

    var body: some View {
        // 不论在画什么，都按完整尺寸布局，这样它开合时周围的东西都不会动。
        //
        // **两个孩子的对齐方式不一样，所以 ZStack 不带 alignment。**
        // 泊位要横跨方向贴着屏幕边（`stackAlignment`），而环恒在条的中心线上
        // （`RailLayout.ringCentreAcross` 就是按居中算的，命中区与绘制必须同源）。
        // 早先两者共用一个 `alignment: stackAlignment`，而 `ZStack` 的对齐是相对
        // **最大的那个孩子**算的、不是相对外层 frame：卷起来时泊位只有 6pt 宽、
        // 环那一列有 38pt 宽，ZStack 于是按 38pt 排布、再被 64pt 的外层 frame 居中，
        // 细条因此离屏幕边 13pt——而它本该焊在边上。
        ZStack {
            berth

            rings
                .opacity(isExpanded ? 1 : 0)
                // 它有自己的时序，覆盖形状所乘的那个弹簧：内容在泊位张到装得下它们之后
                // 才出现，在它合上之前就消失。少了这个延迟，它们会在还是一个细条的
                // 形状上淡起来——那正是「这两者曾经是两个东西」的破绽。
                .animation(
                    .easeOut(duration: isExpanded ? 0.18 : 0.10)
                        .delay(isExpanded ? 0.12 : 0),
                    value: isExpanded
                )
                .frame(width: railSize.width, height: railSize.height)
        }
        .frame(width: railSize.width, height: railSize.height)
        // 贴住刘海的条卷起来时，命中测试整个关掉：屏幕上那时没有条可以点。
        .allowsHitTesting(notchSize == nil || isExpanded)
        .accessibilityHidden(notchSize != nil && !isExpanded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("订阅用量悬浮条")
    }

    @ViewBuilder
    private var berth: some View {
        if let notchSize {
            let surface = RailHitArea.notchSurface(
                rail: CGRect(origin: .zero, size: railSize),
                notchSize: notchSize
            )
            RailSurface(
                shape: RailNotchBerthShape(notchSize: notchSize, openness: isExpanded ? 1 : 0, metrics: metrics),
                glassEnabled: glassEnabled
            )
            // 比表面更宽，宽出的是圆角在屏幕边扫进去的那段空间；
            // 形状自己会把条身那部分缩回来。
            .frame(width: surface.width + metrics.flareWidth * 2, height: surface.height)
            .offset(y: surface.minY)
            .frame(width: railSize.width, height: railSize.height, alignment: .top)
        } else {
            ordinaryBerth
        }
    }

    private var ordinaryBerth: some View {
        RailSurface(
            shape: RailBerthShape(
                edge: edge,
                isDocked: isDocked,
                openness: isExpanded ? 1 : 0,
                metrics: metrics
            ),
            glassEnabled: glassEnabled,
            // 只有细条带告警色：展开时环自己已经说了哪个额度在哪里。
            tint: isExpanded ? nil : alert,
            stroke: isDocked ? nil : TM.borderStrong
        )
        .frame(width: currentSize.width, height: currentSize.height)
        // 把这个小盒子按 `stackAlignment` 摆进条的整块地方里：横跨方向贴屏幕边，
        // 沿条方向居中——`RailHitArea.strip` 正是按同一个规则算命中区的。
        .frame(width: railSize.width, height: railSize.height, alignment: edge.stackAlignment)
    }

    private var rings: some View {
        // 同一批项，按条的走向叠放。`AnyLayout` 让它们在换轴时仍是同一组视图，
        // 而不是两组被替换——从侧边重新贴到顶边的条会把环带过去，而不是重建它们。
        let stack = edge.isVertical
            ? AnyLayout(VStackLayout(spacing: metrics.itemSpacing))
            : AnyLayout(HStackLayout(spacing: metrics.itemSpacing))

        return stack {
            ForEach(entries) { entry in
                item(for: entry)
            }
        }
        // 两端的余量。贴边时外扩已经啃掉了一段，`endPadding` 会把那部分减掉，
        // 于是两种状态**看得见**的呼吸感一致——这正是命中区算环心时用的那个数，
        // 两处必须同源。
        .padding(
            edge.isVertical ? .vertical : .horizontal,
            metrics.endPadding(docked: isDocked)
        )
    }

    private func ring(for entry: RailEntry, selected: Bool) -> some View {
        RailRingView(
            entry: entry,
            isSelected: selected,
            options: options,
            isRefreshing: isRefreshing
        )
    }

    @ViewBuilder
    private func item(for entry: RailEntry) -> some View {
        let selected = entry.id == selectedID

        // 悬停由 `RailView` 从采样的指针位置反推（`selectRing(at:)`），
        // 所以这里不需要跟踪区。`contentShape` 只为了让整项成为可访问的按钮区域。
        switch edge.axis {
        case .vertical:
            if metrics.showsPercentages(on: .vertical) {
                // 环与数字。这个总高必须等于 `metrics.itemLength(on: .vertical)`，
                // 否则环心会与命中区算出来的位置错开。
                VStack(spacing: RailLayout.ringToTextSpacing) {
                    if metrics.labelAboveRing {
                        RailRingLabel(entry: entry, showsRemaining: options.showsRemaining)
                        ring(for: entry, selected: selected)
                    } else {
                        ring(for: entry, selected: selected)
                        RailRingLabel(entry: entry, showsRemaining: options.showsRemaining)
                    }
                }
                .frame(height: metrics.itemLength(on: .vertical))
                .contentShape(.rect)
                .accessibilityAddTraits(.isButton)
            } else {
                ring(for: entry, selected: selected)
                    .contentShape(.rect)
                    .accessibilityAddTraits(.isButton)
            }

        case .horizontal:
            if metrics.showsPercentages(on: .horizontal) {
                // 贴顶的条把数字放在环**下方**：一行字落在条的横跨方向，占的是厚度。
                VStack(spacing: RailLayout.ringToTextSpacing) {
                    ring(for: entry, selected: selected)
                    RailRingLabel(entry: entry, showsRemaining: options.showsRemaining)
                }
                .frame(width: metrics.itemLength(on: .horizontal))
                .contentShape(.rect)
                .accessibilityAddTraits(.isButton)
            } else {
                ring(for: entry, selected: selected)
                    .frame(width: metrics.itemLength(on: .horizontal))
                    .contentShape(.rect)
                    .accessibilityAddTraits(.isButton)
            }
        }
    }
}
