import CoreGraphics
import Foundation

/// 指针判定的两个区域，放在一起是因为它们之间的**关系**才是显示/隐藏循环安全的原因。
///
/// 移植自 Pulse 的 `PanelHitArea`。
///
/// **细条的命中区必须完全落在条的命中区之内。** 隐藏只在指针离开**条**时发生，
/// 所以细条要是能伸到条外面，就会出现这样的点：先把条藏起来，然后立刻落在细条上——
/// 而细条的跟踪区又把它显示出来，于是再藏一次。这就是那个反复修过的开/关循环，
/// 换了一身衣服又回来了。`stripIsContainedInRail(maxEntries:)` 对每一种条长、
/// 每一条边断言这个包含关系，并且作为测试在每次跑测试时执行。
enum RailHitArea {
    /// 某个环数下窗口的尺寸。窗口尺寸由条长推出来，两处必须用同一个来源。
    static func panelSize(for edge: RailEdge, railLength: CGFloat, notchSize: CGSize? = nil) -> CGSize {
        RailPanelLayout.size(for: edge, railLength: railLength, notchSize: notchSize)
    }

    /// 贴住物理刘海时，条向上延伸到屏幕物理顶端、宽度至少与外壳同宽。
    ///
    /// 条下方不加内边距：环上方那片是屏幕自己的边框，不是这个窗口留出来的，
    /// 去凑它只会让一个 36pt 的环下面压着 38pt 的黑。
    static func notchSurface(rail: CGRect, notchSize: CGSize) -> CGRect {
        let width = max(rail.width, notchSize.width)
        return CGRect(
            x: rail.midX - width / 2,
            y: rail.minY - notchSize.height,
            width: width,
            height: rail.height + notchSize.height
        )
    }

    /// 条在窗口里的矩形，用窗口的左上角坐标。
    static func rail(
        edge: RailEdge,
        railSize: CGSize,
        panelSize: CGSize,
        railTop: CGFloat,
        railLeading: CGFloat
    ) -> CGRect {
        let x: CGFloat = switch edge {
        case .left: 0
        case .right: panelSize.width - railSize.width
        case .top: railLeading
        }
        return CGRect(x: x, y: railTop, width: railSize.width, height: railSize.height)
    }

    /// 某个点落在哪个环上，用窗口的左上角坐标。
    ///
    /// 只有圆是可点的：名字和空着的条身保持它们原有的「拖动面」含义。
    static func slot(
        at point: CGPoint,
        edge: RailEdge,
        entryCount: Int,
        railSize: CGSize,
        panelSize: CGSize,
        railTop: CGFloat,
        railLeading: CGFloat,
        docked: Bool
    ) -> Int? {
        let rail = rail(
            edge: edge,
            railSize: railSize,
            panelSize: panelSize,
            railTop: railTop,
            railLeading: railLeading
        )
        guard rail.contains(point) else { return nil }

        // 含选中环的放大与一点指针宽容，但不至于够到它下面的百分比文字。
        let radius = RailLayout.ringDiameter / 2 * 1.08
        let across = RailLayout.ringCentreAcross(on: edge.axis)

        for index in 0..<max(entryCount, 0) {
            let along = RailLayout.firstRingAlong(docked: docked, on: edge.axis)
                + CGFloat(index) * RailLayout.ringStep(on: edge.axis)
            let centre = edge.isVertical
                ? CGPoint(x: rail.minX + across, y: rail.minY + along)
                : CGPoint(x: rail.minX + along, y: rail.minY + across)

            let dx = point.x - centre.x
            let dy = point.y - centre.y
            if dx * dx + dy * dy <= radius * radius { return index }
        }

        return nil
    }

    /// 细条只在贴边时存在——离开边之后条保持展开——所以它总是紧贴着屏幕边。
    static func strip(
        edge: RailEdge,
        railSize: CGSize,
        panelSize: CGSize,
        railTop: CGFloat,
        railLeading: CGFloat
    ) -> CGRect {
        let rail = rail(
            edge: edge,
            railSize: railSize,
            panelSize: panelSize,
            railTop: railTop,
            railLeading: railLeading
        )
        let hit = RailLayout.collapsedHitSize(on: edge.axis)

        // 沿条的走向居中（那也是它画出来的位置），横跨方向紧贴屏幕边。
        // 走向方向加上卡片那条带得到的同样宽容，细条才不是一根绊线。
        switch edge {
        case .left:
            return CGRect(x: rail.minX, y: rail.midY - hit.height / 2, width: hit.width, height: hit.height)
                .insetBy(dx: 0, dy: -RailLayout.pointerSlack)
        case .right:
            return CGRect(x: rail.maxX - hit.width, y: rail.midY - hit.height / 2, width: hit.width, height: hit.height)
                .insetBy(dx: 0, dy: -RailLayout.pointerSlack)
        case .top:
            return CGRect(x: rail.midX - hit.width / 2, y: rail.minY, width: hit.width, height: hit.height)
                .insetBy(dx: -RailLayout.pointerSlack, dy: 0)
        }
    }

    /// 细条能不能在不离开条的区域的前提下被够到，对每一种可能出现的条长。
    ///
    /// **只量贴边态**：细条只在贴边时存在（`RailView` 的展开条件是「悬浮恒展开」），
    /// 所以这才是真实的不变量。悬浮态的条比细条还短——`endPadding` 少一个
    /// `flareHeight`，单项时只有 102pt，短于细条 112pt 的命中区——但那一种状态里
    /// 细条根本不会出现，去断言它是在断言一个不存在的约束。
    ///
    /// 条内的偏移量也一起遍历：条不再钉在窗口中央，所以每个偏移都要成立。
    static func stripIsContainedInRail(maxEntries: Int) -> Bool {
        for edge in RailEdge.allCases {
            for count in 1...max(maxEntries, 1) {
                let size = RailLayout.size(for: count, on: edge.axis, docked: true)
                let panel = panelSize(for: edge, railLength: max(size.width, size.height))
                let travel = edge.isVertical
                    ? max(panel.height - size.height, 0)
                    : max(panel.width - size.width, 0)

                for offset in stride(from: 0.0, through: travel, by: 1) {
                    let top = edge.isVertical ? offset : 0
                    let leading = edge.isVertical ? 0 : offset
                    let rail = rail(
                        edge: edge,
                        railSize: size,
                        panelSize: panel,
                        railTop: top,
                        railLeading: leading
                    )
                    let strip = strip(
                        edge: edge,
                        railSize: size,
                        panelSize: panel,
                        railTop: top,
                        railLeading: leading
                    )
                    guard rail.contains(strip) else { return false }
                }
            }
        }
        return true
    }
}
