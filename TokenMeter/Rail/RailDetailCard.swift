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
    /// 总使用量只有比例没有金额，那一行就只写重置时间。
    private func detailText(_ row: RailEntry.Row) -> String {
        let reset = row.resetAt.map { SubscriptionCardPresentation.resetHintText(for: $0) }
        let amounts = [row.usedText, row.limitText].compactMap { $0 }.joined(separator: " / ")
        return [reset, amounts.isEmpty ? nil : amounts].compactMap { $0 }.joined(separator: " · ")
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

/// 详情卡片的轮廓：圆角卡身与指针是**一条**连续的路径。
///
/// 移植自 Pulse 的 `UsageBubbleShape`，但做了关键改动：Pulse 用两个子路径叠着画——
/// 圆角矩形加一条往卡身里咬一点的尾巴，接缝靠填充盖住。**填充**时没问题，
/// **描边**却把两条子路径都描出来：卡身边线在根部被描一道、尾巴自己的底边往里偏一点
/// 再描一道，重叠处是位差明显的两道竖缝。
///
/// 所以这里画一条轮廓：沿圆角卡身走到指针根部就拐出去、绕尖角一圈回来，
/// 再继续走完剩下的卡身。填充与描边读的都是同一条线，根部没有接缝也没有位差。
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
        // 再转回去，于是几何只有一份。
        guard edge.isVertical else {
            let canonical = CGRect(x: 0, y: 0, width: rect.height, height: rect.width)
            return facingRight(in: canonical).applying(
                CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: rect.height)
            )
        }

        var path = facingRight(in: rect)
        if edge == .left {
            // 单个子路径没有绕向这回事，镜像不会在两段重叠处打出缺口——直接镜像就行。
            path = path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.width, ty: 0))
        }
        return path
    }

    /// 朝右的剪影：卡身占左边，指针伸进右边的带子里。
    ///
    /// 走法：从指针上根出发，拐出去绕尖角一圈回到下根，顺着右缘往下走完右下角、
    /// 底边、左下角、左边、左上角、顶边、右上角，最后回到指针上根收尾。
    private func facingRight(in rect: CGRect) -> Path {
        let half = pointerHeight / 2
        // 让指针避开圆角，而且即使调用方给了超范围的值也留在卡片之内。
        let centre = min(
            max(pointerCenter, cornerRadius + half),
            max(rect.height - cornerRadius - half, cornerRadius + half)
        )

        let left = rect.minX
        let side = rect.maxX - pointerWidth
        let tip = rect.maxX
        let top = rect.minY
        let bottom = rect.maxY
        let radius = cornerRadius
        // 四分之一圆的贝塞尔近似。
        let arc = radius * 0.5523

        var path = Path()
        path.move(to: CGPoint(x: side, y: centre - half))

        // 指针两侧：根部切线落在卡片边上（先沿边走一小段再弯出去），像气泡一样长出来；
        // 尖端约 50°，足够尖，能明确指向一个环。
        let reach = tip - side
        let farAlong: CGFloat = 0.55
        let farAcross: CGFloat = 0.22
        path.addCurve(
            to: CGPoint(x: tip, y: centre),
            control1: CGPoint(x: side, y: centre - half * 0.5),
            control2: CGPoint(x: side + reach * farAlong, y: centre - half * farAcross)
        )
        path.addCurve(
            to: CGPoint(x: side, y: centre + half),
            control1: CGPoint(x: side + reach * farAlong, y: centre + half * farAcross),
            control2: CGPoint(x: side, y: centre + half * 0.5)
        )

        // 右下角 → 底边 → 左下角 → 左边 → 左上角 → 顶边 → 右上角。
        path.addLine(to: CGPoint(x: side, y: bottom - radius))
        path.addCurve(
            to: CGPoint(x: side - radius, y: bottom),
            control1: CGPoint(x: side, y: bottom - radius + arc),
            control2: CGPoint(x: side - radius + arc, y: bottom)
        )
        path.addLine(to: CGPoint(x: left + radius, y: bottom))
        path.addCurve(
            to: CGPoint(x: left, y: bottom - radius),
            control1: CGPoint(x: left + radius - arc, y: bottom),
            control2: CGPoint(x: left, y: bottom - radius + arc)
        )
        path.addLine(to: CGPoint(x: left, y: top + radius))
        path.addCurve(
            to: CGPoint(x: left + radius, y: top),
            control1: CGPoint(x: left, y: top + radius - arc),
            control2: CGPoint(x: left + radius - arc, y: top)
        )
        path.addLine(to: CGPoint(x: side - radius, y: top))
        path.addCurve(
            to: CGPoint(x: side, y: top + radius),
            control1: CGPoint(x: side - radius + arc, y: top),
            control2: CGPoint(x: side, y: top + radius - arc)
        )
        path.addLine(to: CGPoint(x: side, y: centre - half))
        path.closeSubpath()
        return path
    }
}
