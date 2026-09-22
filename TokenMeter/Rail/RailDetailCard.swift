import SwiftUI

/// 悬停时展开的详情卡片。
///
/// 移植自 Pulse 的 `UsageDetailCard`，去掉它的预算预测与余额行（余额在 TokenMeter 里
/// 本来就是一个额度行，走同一条渲染路径）。
struct RailDetailCard: View {
    let entry: RailEntry
    /// 贴在哪条屏幕边上；指针画在朝向条的那一侧。
    let edge: RailEdge
    let glassEnabled: Bool
    /// 指针尖端应该落在这条边的哪个位置，从卡片自己的上沿或前缘量起。
    ///
    /// 卡片会被窗口自己的边缘推来推去（见 `RailView.cardPadding`），
    /// 所以指针不能只是坐在卡片中央——它必须独立摆放，才能一直指着被选中的那个环。
    let pointerCenter: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: RailCardLayout.contentSpacing) {
            header

            // 供应商报几行就画几行：有的套餐只有一个账号级窗口，有的按模型各有限额。
            ForEach(entry.rows) { row in
                rowView(row)
            }

            // **只有标题的卡片读起来像加载失败。** 读不到数时下面这句话必须说清楚
            // 是哪里出了问题，而不是让卡片空着。
            if entry.rows.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: RailCardLayout.messageFontSize, weight: .regular, design: .rounded))
                    .foregroundStyle(TM.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let footnote {
                Text(footnote)
                    .font(.system(size: RailCardLayout.footnoteFontSize, weight: .regular, design: .rounded))
                    .foregroundStyle(TM.textTertiary)
            }
        }
        .padding(RailCardLayout.padding)
        .frame(width: RailCardLayout.width, alignment: .leading)
        // 朝条那一侧留出指针的空间。下面的形状把卡身与指针一起盖住。
        .padding(pointerSide, RailCardLayout.pointerWidth)
        // 卡片跟着条的表面走：一个玻璃胶囊配一张实心深色卡片，读起来是两个组件，不是一个面板。
        .background(
            RailSurface(
                shape: RailBubbleShape(
                    edge: edge,
                    pointerCenter: pointerCenter,
                    cornerRadius: RailCardLayout.cornerRadius,
                    pointerWidth: RailCardLayout.pointerWidth,
                    pointerHeight: RailCardLayout.pointerHeight
                ),
                glassEnabled: glassEnabled,
                stroke: TM.borderStrong
            )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.title) 用量详情")
    }

    /// 指针从卡片的哪一侧伸出去：朝向条的那一侧。
    private var pointerSide: Edge.Set {
        switch edge {
        case .left: .leading
        case .right: .trailing
        case .top: .top
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            mark
            Text(entry.title)
                // 恒为一行。卡片的高度在 SwiftUI 布局之前就由 `RailCardLayout` 算出来了，
                // 会换行的标题会让卡片高于窗口为它预算的高度，然后被屏幕边齐边裁掉。
                .lineLimit(1)
                .font(.system(size: RailCardLayout.titleFontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(TM.textPrimary)
            Spacer(minLength: 0)
        }
        .frame(height: RailCardLayout.headerHeight)
    }

    @ViewBuilder
    private var mark: some View {
        if let resource = entry.markResource, let image = RailMarkStore.image(named: resource) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(TM.textPrimary)
                .frame(width: RailCardLayout.headerIconSize, height: RailCardLayout.headerIconSize)
        } else {
            Image(systemName: entry.fallbackSystemImage)
                .resizable()
                .scaledToFit()
                .foregroundStyle(TM.textPrimary)
                .frame(width: RailCardLayout.headerIconSize, height: RailCardLayout.headerIconSize)
        }
    }

    private func rowView(_ row: RailEntry.Row) -> some View {
        VStack(alignment: .leading, spacing: RailCardLayout.rowInternalSpacing) {
            HStack(spacing: 6) {
                Text(row.name)
                    .font(.system(size: RailCardLayout.rowFontSize, weight: .medium, design: .rounded))
                    .foregroundStyle(TM.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Int((row.fraction * 100).rounded()))%")
                    .font(.system(size: RailCardLayout.rowFontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(rowColor(row))
            }
            .frame(height: RailCardLayout.rowTextLineHeight)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(TM.meterTrack)
                    Capsule()
                        .fill(rowColor(row))
                        .frame(width: max(geometry.size.width * min(max(row.fraction, 0), 1), 0))
                }
            }
            .frame(height: RailCardLayout.progressBarHeight)

            Text(detailText(row))
                .font(.system(size: RailCardLayout.rowFontSize, weight: .regular, design: .rounded))
                .foregroundStyle(TM.textTertiary)
                .lineLimit(1)
                .frame(height: RailCardLayout.rowTextLineHeight)
        }
    }

    /// 逐行的颜色取用户在编辑页选的那一套，与面板卡片里的进度条一致；
    /// 没配过就按额度类型取默认色。
    private func rowColor(_ row: RailEntry.Row) -> Color {
        if let rgb = row.colorRGB { return Color(hex: rgb) }
        return SubscriptionQuotaColors.defaultColor(forKind: row.kind)
    }

    /// 一行的第二段说明：什么时候刷新，以及用量本身。
    ///
    /// 顺序是有讲究的：重置时间是这个 app 里最常被问的那个数，
    /// 而「已用 / 上限」在余额型额度上会很长，放后面让它先被截断。
    private func detailText(_ row: RailEntry.Row) -> String {
        let reset = row.resetAt.map { SubscriptionCardPresentation.resetHintText(for: $0) }
        let amounts = "\(row.usedText) / \(row.limitText)"
        return [reset, amounts].compactMap { $0 }.joined(separator: " · ")
    }

    private var emptyMessage: String {
        if let error = entry.errorMessage { return error }
        return entry.state.label
    }

    /// 额度下面那行「这个数有多可信」。
    private var footnote: String? {
        guard entry.state == .realtime, let updatedAt = entry.updatedAt else { return nil }
        // 只有超过一个刷新周期才值得说，否则每次悬停都在报一个刚发生的事。
        guard Date().timeIntervalSince(updatedAt) > 300 else { return nil }
        return "截至 \(updatedAt.tokenMeterTimeText)"
    }
}

/// 详情卡片的轮廓：圆角卡身与指针是**一条**路径。
///
/// 移植自 Pulse 的 `UsageBubbleShape`。
///
/// 这两者以前是并排的两个视图——一个圆角矩形和一个用内边距推到位的小三角。
/// 换一个订阅会同时改变卡片高度与指针目标，而两个各自做动画的视图不会同步：
/// 过渡中途尾巴会明显从卡片上掉下来。画成一条路径就不可能发生，
/// 因为已经没有任何东西可以走散了。
struct RailBubbleShape: Shape {
    /// 指针从哪一侧伸出去——朝向条的那一侧。
    let edge: RailEdge
    /// 指针沿它伸出的那条边的中心：卡片在条旁边时从上沿往下量，
    /// 挂在条下面时从前缘往里量。
    var pointerCenter: CGFloat
    let cornerRadius: CGFloat
    let pointerWidth: CGFloat
    let pointerHeight: CGFloat

    /// 让指针作为形状的一部分滑动，而不是一个可能自己走一条曲线的独立动画。
    var animatableData: CGFloat {
        get { pointerCenter }
        set { pointerCenter = newValue }
    }

    func path(in rect: CGRect) -> Path {
        // 挂在条下面的卡片是同一条剪影转了四分之一圈。在这个横过来的矩形里画、
        // 再转回去，于是几何只有一份——而且因为旋转不是镜像，卡身与尾巴必须共享的
        // 绕向得以保持。镜像会反转尾巴的方向，在两者之间打出一个缺口，
        // 贴左边的那次就是这样。
        guard edge.isVertical else {
            let canonical = CGRect(x: 0, y: 0, width: rect.height, height: rect.width)
            return facingSideways(in: canonical).applying(
                CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: rect.height)
            )
        }

        return facingSideways(in: rect)
    }

    private func facingSideways(in rect: CGRect) -> Path {
        // 指针住在朝条那一侧的一条带子里；卡身占掉剩下的部分。
        let body = CGRect(
            x: edge.isLeft ? pointerWidth : 0,
            y: 0,
            width: max(rect.width - pointerWidth, 0),
            height: rect.height
        )

        var path = Path(
            roundedRect: body,
            cornerSize: CGSize(width: cornerRadius, height: cornerRadius),
            style: .continuous
        )

        path.addPath(pointerPath(in: rect, body: body))
        return path
    }

    /// 尾巴，作为一个与卡身边缘重叠的子路径，填充之后两者读起来是一条剪影。
    private func pointerPath(in rect: CGRect, body: CGRect) -> Path {
        let half = pointerHeight / 2
        // 让尾巴避开圆角，而且即使调用方给了超范围的值也留在卡片之内。
        let centre = min(
            max(pointerCenter, cornerRadius + half),
            max(rect.height - cornerRadius - half, cornerRadius + half)
        )

        let baseX = edge.isLeft ? body.minX : body.maxX
        let tipX = edge.isLeft ? rect.minX : rect.maxX
        let reach = tipX - baseX

        // 按与卡身圆角矩形**同向**的方向遍历这条尾巴。两者是分别填充为一个形状的
        // 独立子路径，在非零填充规则下反向的绕向会在重叠处**相消**——
        // 贴左边那次正是这样：镜像几何反转了尾巴的方向，与卡身的重叠打出了一个缺口。
        let sweep = edge.isLeft ? -half : half

        // 两条侧边的两个控制点各自的位置，作为 `reach` 与 `sweep` 的比例。
        // 起点贴着卡片的边，让侧边沿着那条边离开卡片再弯向尖端；
        // 第二个决定两条侧边怎么相遇：约 50°，足够尖，能明确指向一个环。
        let nearAlong: CGFloat = 0.24
        let nearAcross: CGFloat = 0.44
        let farAlong: CGFloat = 0.55
        let farAcross: CGFloat = 0.24

        var path = Path()
        path.move(to: CGPoint(x: baseX, y: centre - sweep))
        path.addCurve(
            to: CGPoint(x: tipX, y: centre),
            control1: CGPoint(x: baseX + reach * nearAlong, y: centre - sweep * nearAcross),
            control2: CGPoint(x: baseX + reach * farAlong, y: centre - sweep * farAcross)
        )
        path.addCurve(
            to: CGPoint(x: baseX, y: centre + sweep),
            control1: CGPoint(x: baseX + reach * farAlong, y: centre + sweep * farAcross),
            control2: CGPoint(x: baseX + reach * nearAlong, y: centre + sweep * nearAcross)
        )
        // 咬回卡身一点，让接缝被填充盖住，而不是沿着边缘留下一条缝。
        path.addLine(to: CGPoint(x: baseX - reach * 0.08, y: centre + sweep))
        path.addLine(to: CGPoint(x: baseX - reach * 0.08, y: centre - sweep))
        path.closeSubpath()
        return path
    }
}
