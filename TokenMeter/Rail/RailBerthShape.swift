import SwiftUI

/// 条的轮廓：像从屏幕边上长出来，而不是被摆在旁边。
///
/// 移植自 Pulse 的 `DockBerthShape`，去掉它的圆端档位——TokenMeter 只有一种收尾样式
/// （Pulse 的默认「柔化端」：四阶超椭圆角 + 凹形外扩）。
///
/// 贴着屏幕的那条边整段是平的，那里什么都不圆，所以条和屏幕边之间永远不会露出壁纸。
/// 条**身**在两端各内缩 `flareHeight`，每一端通过一个凹形圆角扫出去接上屏幕边：
/// 它水平地离开条身平直的那条边，垂直地接上屏幕边，所以两个接点都是切线连续的。
///
/// 外扩画在边界矩形之内，所以 `RailLayout.verticalPadding` 必须 >= `flareHeight`：
/// 排在条身平直上沿之外的内容会落到形状外面被裁掉。
struct RailBerthShape: Shape {
    /// 条贴着哪条屏幕边。
    ///
    /// 只画一遍朝右的，然后搬到位置上：贴左边镜像，贴顶转四分之一圈。
    /// 轮廓里没有文字、没有不对称的细节，所以变换画好的路径是精确的，
    /// 也就避免第二份可能与这份走散的几何。
    var edge: RailEdge = .right
    /// 离开屏幕边之后没有东西可以融合，外扩让位给一个两端全圆的胶囊。
    /// 在桌面中间画一个贴着屏幕边的轮廓，读起来像渲染故障而不是设计。
    var isDocked: Bool = true

    /// 泊位张开多少：0 是卷起的细条，1 是完整的条。
    ///
    /// 细条不是另一种形状——它就是这一种把外扩与圆角一路收到头，所以两者之间可以做动画，
    /// 是同一个物体在改变尺寸，而不是一个被换成另一个。收到 0 时外扩消失、
    /// 圆角等于整个宽度，留下的正好是一侧圆的细条。
    var openness: CGFloat = 1
    /// 尺寸预算：圆角与外扩的取值由它决定（圆端与柔化端是两套数）。
    var metrics = RailMetrics()

    /// 让轮廓本身可插值，于是动画的每一步都是重画出来的剪影，而不是把一个形状淡入另一个。
    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    private var flareHeight: CGFloat { metrics.flareHeight * openness }
    private var flareWidth: CGFloat { metrics.flareWidth * openness }
    private var cornerRadius: CGFloat {
        RailLayout.collapsedWidth + (metrics.cornerRadius - RailLayout.collapsedWidth) * openness
    }

    func path(in rect: CGRect) -> Path {
        guard isDocked else { return Self.floating(in: rect) }

        switch edge {
        case .right:
            return facingRight(in: rect)

        case .left:
            return facingRight(in: rect).applying(
                CGAffineTransform(translationX: rect.width, y: 0).scaledBy(x: -1, y: 1)
            )

        case .top:
            // 逆时针转四分之一圈，把外扩从右边带到顶边。标准矩形就是这一块横过来放，
            // 所以画法不变、只有摆放变了——而且因为是旋转而不是镜像，路径的绕向得以保持。
            let canonical = CGRect(x: 0, y: 0, width: rect.height, height: rect.width)
            return facingRight(in: canonical).applying(
                CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: rect.height)
            )
        }
    }

    /// 真正的胶囊：两端是半圆，不是圆掉的角。
    ///
    /// 圆，不是超椭圆。超椭圆把曲率缓和进它两侧的直边里，而在这个宽度下
    /// 一端的两个角之间根本没有直边——没有东西可以缓和，画出来会像一个被压扁的菱形。
    /// 完全圆的端头才是自由站着的胶囊该有的样子。
    private static func floating(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        return Path(
            roundedRect: rect,
            cornerSize: CGSize(width: radius, height: radius),
            style: .circular
        )
    }

    private func facingRight(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let f = min(flareHeight, h / 2)
        // 两个凸角长在条身上，条身占据 y 的 [f, h - f]。
        let r = max(min(cornerRadius, min(w, (h - f * 2) / 2)), 0)
        // 外扩必须给那个角让出位置：`flareWidth + r` 一旦超过宽度，
        // 条身平直的上沿就会往回走，路径会自己折起来。
        let fw = max(min(flareWidth, w - r), 0)

        // 把每个圆角的控制点从它的端点上拉开。0.55 是常见的圆弧近似值，
        // 它让这段扫掠保持饱满，而不是被压平成一道缝。
        let k: CGFloat = 0.55

        var path = Path()

        // 条身平直的上沿，从左到右。
        path.move(to: CGPoint(x: r, y: f))
        path.addLine(to: CGPoint(x: w - fw, y: f))

        // 凹形圆角向上扫进屏幕边。
        path.addCurve(
            to: CGPoint(x: w, y: 0),
            control1: CGPoint(x: w - fw * (1 - k), y: f),
            control2: CGPoint(x: w, y: f * k)
        )

        // 整段高度贴着屏幕。
        path.addLine(to: CGPoint(x: w, y: h))

        // 镜像的圆角向下扫回条身的下沿。
        path.addCurve(
            to: CGPoint(x: w - fw, y: h - f),
            control1: CGPoint(x: w, y: h - f * k),
            control2: CGPoint(x: w - fw * (1 - k), y: h - f)
        )

        // 条身平直的下沿，从右到左。
        path.addLine(to: CGPoint(x: r, y: h - f))

        // 左下角：从圆心正下方开始，到圆心正左方结束。
        appendCorner(
            to: &path,
            center: CGPoint(x: r, y: h - f - r),
            radius: r,
            from: CGVector(dx: 0, dy: 1),
            to: CGVector(dx: -1, dy: 0)
        )

        // 左边。
        path.addLine(to: CGPoint(x: 0, y: f + r))

        // 左上角：从圆心正左方开始，到圆心正上方结束。
        appendCorner(
            to: &path,
            center: CGPoint(x: r, y: f + r),
            radius: r,
            from: CGVector(dx: -1, dy: 0),
            to: CGVector(dx: 0, dy: -1)
        )

        path.closeSubpath()
        return path
    }

    /// 追加四分之一条超椭圆——macOS 给自己那些圆角矩形用的、曲率连续的「squircle」角——
    /// 而不是一段圆弧。
    ///
    /// 圆弧从直边上的零曲率瞬间跳到角开始处的 `1/radius`。那个不连续正是「边被切掉一块」
    /// 的观感来源。超椭圆把曲率缓和进来，于是直边和圆角属于同一条描边。
    /// SwiftUI 给普通圆角矩形提供了 `.continuous`，但泊位轮廓必须手画，所以这里采样它。
    ///
    /// `from` 与 `to` 是从 `center` 到圆角起点、终点的单位方向；它们必须垂直且与轴对齐。
    private func appendCorner(
        to path: inout Path,
        center: CGPoint,
        radius: CGFloat,
        from start: CGVector,
        to end: CGVector
    ) {
        guard radius > 0 else { return }

        for step in 1...Self.cornerSampleCount {
            let t = CGFloat(step) / CGFloat(Self.cornerSampleCount) * (.pi / 2)
            // |x/r|^n + |y/r|^n = 1 的参数形式。
            let along = pow(cos(t), 2 / squircleExponent)
            let across = pow(sin(t), 2 / squircleExponent)

            path.addLine(to: CGPoint(
                x: center.x + radius * (start.dx * along + end.dx * across),
                y: center.y + radius * (start.dy * along + end.dy * across)
            ))
        }
    }

    /// 超椭圆指数。2 是正圆；4 接近 Apple 用的 squircle，
    /// 既让圆角保持饱满，又把它缓和进两侧的直边。圆端用 2——见 `RailMetrics.usesRoundEnds`。
    private var squircleExponent: CGFloat { metrics.cornerExponent }
    /// 分段足够多，采样出来的曲线在条的实际尺寸下保持亚像素平滑。
    private static let cornerSampleCount = 48
}

/// 摄像头外壳的延伸，与屏幕物理顶端齐平。
///
/// 移植自 Pulse 的 `NotchBerthShape`。环仍然排在外壳下方；只有表面长上去。
///
/// 画法与它所替代的贴顶条一致：条身两侧通过一个凹形圆角**向外**扫进屏幕上沿，
/// 于是这个表面读起来是从屏幕边里长出来的，而不是贴着它停着的一块板。
/// 少了那个圆角，上面两个角就是方的，而那是贴边条从来没有过的样子。
struct RailNotchBerthShape: Shape {
    var notchSize: CGSize
    var openness: CGFloat = 1
    var metrics = RailMetrics()

    /// 把每个圆角的控制点从端点上拉开，与 `RailBerthShape` 用同一个 0.55 圆弧近似。
    /// 两者保持一致比这个数字本身更重要：有刘海的 Mac 和没有的，看到的应该是同一条条。
    private static let fillet: CGFloat = 0.55

    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    /// `rect` 是条身**加上**两侧各 `metrics.flareWidth`，那是圆角扫进去的空间。
    /// 调用方按它给 frame；`RailHitArea.notchSurface` 仍然只是条身本身，
    /// 所以可抓区域永远不会多过条画出来的部分。
    func path(in rect: CGRect) -> Path {
        let progress = min(max(openness, 0), 1)
        guard progress > 0 else { return Path() }

        let flareWidth = metrics.flareWidth * progress
        let flareHeight = min(metrics.flareHeight * progress, rect.height)
        let body = rect.insetBy(dx: metrics.flareWidth, dy: 0)

        let width = notchSize.width + (body.width - notchSize.width) * progress
        let height = notchSize.height + (body.height - notchSize.height) * progress
        let minX = rect.midX - width / 2
        let maxX = rect.midX + width / 2
        let top = rect.minY
        let bottom = top + height

        // 下边两个角不能拿走超过表面在圆角之下剩下的高度，否则两条曲线会相交、轮廓会折起来。
        let radius = min(metrics.cornerRadius, width / 2, max(height - flareHeight, 0))
        let k = Self.fillet

        var path = Path()

        // 沿屏幕上沿从左到右，越过左边圆角离开它的地方。
        path.move(to: CGPoint(x: minX - flareWidth, y: top))

        // 向下进入条身的左边。离开屏幕边时是水平的，接上条身时是垂直的，
        // 所以两个接点都是切线连续的。
        path.addCurve(
            to: CGPoint(x: minX, y: top + flareHeight),
            control1: CGPoint(x: minX - flareWidth * (1 - k), y: top),
            control2: CGPoint(x: minX, y: top + flareHeight * (1 - k))
        )

        path.addLine(to: CGPoint(x: minX, y: bottom - radius))
        path.addArc(
            tangent1End: CGPoint(x: minX, y: bottom),
            tangent2End: CGPoint(x: maxX, y: bottom),
            radius: radius
        )
        path.addLine(to: CGPoint(x: maxX - radius, y: bottom))
        path.addArc(
            tangent1End: CGPoint(x: maxX, y: bottom),
            tangent2End: CGPoint(x: maxX, y: top),
            radius: radius
        )

        path.addLine(to: CGPoint(x: maxX, y: top + flareHeight))

        // 镜像的圆角扫回屏幕边。
        path.addCurve(
            to: CGPoint(x: maxX + flareWidth, y: top),
            control1: CGPoint(x: maxX, y: top + flareHeight * (1 - k)),
            control2: CGPoint(x: maxX + flareWidth * (1 - k), y: top)
        )

        path.closeSubpath()
        return path
    }
}
