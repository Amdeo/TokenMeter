import Foundation
import Observation
import SwiftUI

/// 条的背面朝哪一侧——也就是详情卡片往哪一侧展开。
///
/// 贴边时就是条融进的那条屏幕边；悬浮时是条所在的那半屏，这样卡片总是朝宽敞的一侧
/// 展开，而不是展开到屏幕外面去。
enum RailEdge: String, Sendable, CaseIterable {
    case left
    case right
    case top

    /// 条沿哪个方向延伸。
    ///
    /// 原来所有直接读 `edge` 的地方——环所在的栈、卡片展开的方向、外扩融进哪一端、
    /// 两个比例里哪一个被钉住——真正关心的其实只是这个。
    enum Axis: Sendable {
        case vertical
        case horizontal
    }

    var axis: Axis { self == .top ? .horizontal : .vertical }
    var isVertical: Bool { axis == .vertical }
    var isLeft: Bool { self == .left }

    /// 条在窗口里钉在哪个角。沿条方向的偏移另行施加（`RailPlacement.railTop`
    /// 与 `railLeading`），所以这里钉的是那两个偏移量量起的那个角。
    var railAlignment: Alignment {
        switch self {
        case .left, .top: .topLeading
        case .right: .topTrailing
        }
    }

    /// 条与它的细条**在**这个容器里怎么摆：容器正好是条的大小，
    /// 所以这是把细条沿条居中、横跨方向贴着屏幕边。
    var stackAlignment: Alignment {
        switch self {
        case .left: .leading
        case .right: .trailing
        case .top: .top
        }
    }

    /// 卡片挂在条的哪一侧：背离条背的那一侧。
    var cardAlignment: Alignment {
        switch self {
        case .left: .topTrailing
        case .right: .topLeading
        case .top: .topLeading
        }
    }

    /// 卡片沿「展开方向」的轴往哪边走。正值在侧边贴边时是向右、在顶边贴边时是向下，
    /// 两个方向都是 SwiftUI 的正方向。
    var cardDirection: CGFloat {
        switch self {
        case .left, .top: 1
        case .right: -1
        }
    }

    /// 卡片展开动画从卡片的哪个角长出来。
    var cardRevealOrigin: CGFloat {
        switch self {
        case .left, .top: 0
        case .right: 1
        }
    }
}

/// 条是融在屏幕边上还是自由站着。
enum RailDock: Equatable, Hashable, Sendable {
    case edge(RailEdge)
    case floating

    var edge: RailEdge? {
        if case .edge(let edge) = self { return edge }
        return nil
    }

    var isDocked: Bool { edge != nil }
}

/// 放置条的纯几何。移植自 Pulse 的 `PanelPlacement` 几何部分。
///
/// 与状态分开是为了可测：这些函数不碰 `NSScreen`、不碰 `UserDefaults`，
/// 屏幕数据以参数传入，测试可以直接喂一组假的屏幕矩形。
enum RailGeometry {
    /// 条要离屏幕边多近才融上去。
    /// 宽到故意贴边很容易命中，紧到「故意停在边**附近**」仍然成立。
    static let dockDistance: CGFloat = 32

    /// 贴顶的条，它自己的上沿应该在哪。
    ///
    /// 不是 `visibleFrame.maxY`——那在菜单栏底下，停在离屏幕上沿一个菜单栏高度的地方
    /// 并不算贴着屏幕边，看起来也不是。有刘海时，条比刘海两侧任何一边都宽，居中会有
    /// 大半条压在刘海后面（那里什么都画不出来），所以停在刘海自己的那条线上，
    /// 那也正是菜单栏结束的地方。
    static func topEdge(screenFrame: CGRect, visibleFrame: CGRect, topInset: CGFloat) -> CGFloat {
        guard topInset > 0 else { return screenFrame.maxY }
        return min(screenFrame.maxY - topInset, visibleFrame.maxY)
    }

    /// 拖动过程中该落在哪条边上。移植自 Pulse `FloatingPanel.carry()` 的判定。
    ///
    /// 贴边是**在拖动过程中**决定的，不是松手时：等到 mouse-up 才吸附会让条从指针底下
    /// 跳出去。
    ///
    /// 顶端按**指针**判，不是按条。竖着站的条几乎和屏幕一样高，它的上沿一被抬起来就
    /// 顶到屏幕上沿——按那个判会让条在刚被拿起的一瞬间就翻倒。把指针甩到屏幕顶端才是
    /// 那个刻意的动作，而且和够到菜单栏是同一个动作。
    ///
    /// `railOrigin` 是条的**左下角**（屏幕坐标自下而上）。
    static func dockedEdge(
        forPointer pointer: CGPoint,
        railOrigin: CGPoint,
        railSize: CGSize,
        visible: CGRect
    ) -> RailDock {
        if visible.maxY - pointer.y <= dockDistance {
            return .edge(.top)
        }
        if railOrigin.x - visible.minX <= dockDistance {
            return .edge(.left)
        }
        if visible.maxX - (railOrigin.x + railSize.width) <= dockDistance {
            return .edge(.right)
        }
        return .floating
    }

    /// 把条的左下角原点钳制在可用区之内。
    static func clampedRailOrigin(_ wanted: CGPoint, railSize: CGSize, visible: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(wanted.x, visible.minX), max(visible.maxX - railSize.width, visible.minX)),
            y: min(max(wanted.y, visible.minY), max(visible.maxY - railSize.height, visible.minY))
        )
    }

    /// 窗口要放哪儿，以及条在窗口里的哪儿——第二个是**屏幕坐标**，刻意的。
    ///
    /// `frame` 是**请求值**。条带全部订阅时窗口比笔记本的可用区还高，AppKit 不会给一个
    /// 放不下的 frame（`constrainFrameRect` 会把它往下拉，让顶边留在菜单栏之下）。
    /// 从窗口自己的边量起的偏移量因此是相对一个窗口从未有过的位置，
    /// 别的东西量的都是真实位置，拖动时这个差值会来回滚。
    /// 屏幕坐标不会这样出错：改完 frame 之后、用窗口**实际拿到**的 frame 去问
    /// `offsets(forRailTopLeft:in:rail:)`。
    struct Layout {
        let frame: CGRect
        /// 条左上角在屏幕坐标里的位置。
        let railOrigin: CGPoint
    }

    static func layout(
        dock: RailDock,
        horizontalRatio: Double,
        verticalRatio: Double,
        notch: CGRect?,
        visible: CGRect,
        topEdge: CGFloat,
        panel: CGSize,
        rail: CGSize
    ) -> Layout {
        // 贴顶时自由的坐标是横向的，而且窗口是从条**向下**挂，不是以条为中心——
        // 那是卡片唯一能展开的方向。
        if case .edge(.top) = dock {
            let railX = min(
                max(
                    notch.map { $0.midX - rail.width / 2 }
                        ?? (visible.minX + CGFloat(horizontalRatio) * max(visible.width - rail.width, 0)),
                    visible.minX
                ),
                max(visible.maxX - rail.width, visible.minX)
            )
            let railTopY = notch?.minY ?? topEdge

            let windowX = min(
                max(railX + rail.width / 2 - panel.width / 2, visible.minX),
                max(visible.maxX - panel.width, visible.minX)
            )
            let windowY = max((notch?.maxY ?? railTopY) - panel.height, visible.minY)

            return Layout(
                frame: CGRect(x: windowX, y: windowY, width: panel.width, height: panel.height),
                railOrigin: CGPoint(x: railX, y: railTopY)
            )
        }

        let railX: CGFloat = switch dock {
        case .edge(.left): visible.minX
        case .edge(.right): visible.maxX - rail.width
        case .edge(.top): visible.minX  // 上面已处理，走不到
        case .floating:
            // 悬浮的意思是**不贴着**。少了这一条，把存储的位置仍是贴边位置时切到自由摆放，
            // 条会紧贴着屏幕侧面、却戴着悬浮时才有的轮廓。
            min(
                max(
                    visible.minX + CGFloat(horizontalRatio) * max(visible.width - rail.width, 0),
                    visible.minX + dockDistance
                ),
                max(visible.maxX - rail.width - dockDistance, visible.minX + dockDistance)
            )
        }

        // 屏幕坐标自下而上，所以比例 0——条在顶端——是**最高**的 y。
        let railY = visible.minY + CGFloat(1 - verticalRatio) * max(visible.height - rail.height, 0)

        let windowX = (dock.edge ?? .right).isLeft ? railX : railX + rail.width - panel.width
        let windowY = min(
            max(railY + rail.height / 2 - panel.height / 2, visible.minY),
            max(visible.maxY - panel.height, visible.minY)
        )

        return Layout(
            frame: CGRect(x: windowX, y: windowY, width: panel.width, height: panel.height),
            // 条的**上沿**：它的左下角原点加上它的长度。
            railOrigin: CGPoint(x: railX, y: railY + rail.height)
        )
    }

    /// 条在**这个** frame 的窗口里的偏移量。
    ///
    /// 两个偏移量都做了钳制，无论窗口拿到的 frame 和请求的差多少，条都不会被要求
    /// 坐到自己所在窗口的外面去。
    static func offsets(forRailTopLeft origin: CGPoint, in frame: CGRect, rail: CGSize) -> (top: CGFloat, leading: CGFloat) {
        (
            top: min(max(frame.maxY - origin.y, 0), max(frame.height - rail.height, 0)),
            leading: min(max(origin.x - frame.minX, 0), max(frame.width - rail.width, 0))
        )
    }

    /// 把条放到屏幕上的某个位置时，两个比例应该是多少。
    static func ratios(forRailAt origin: CGPoint, in visible: CGRect, rail: CGSize) -> (h: Double, v: Double) {
        let across = max(visible.width - rail.width, 0)
        let down = max(visible.height - rail.height, 0)
        return (
            across > 0 ? Double((origin.x - visible.minX) / across) : 0.5,
            down > 0 ? 1 - Double((origin.y - visible.minY) / down) : 0.5
        )
    }

    // MARK: - 卡片摆放

    /// 一个环心**沿**条的位置。
    ///
    /// 环心从条的第一个环偏移开始，每项前进「一项 + 一个间隙」。
    /// 这条与 `RailHitArea.slot` 必须同源：命中判定走的就是这些数。
    static func ringCentre(
        forIndex index: Int,
        on axis: RailEdge.Axis,
        docked: Bool,
        metrics: RailMetrics
    ) -> CGFloat {
        metrics.firstRingAlong(docked: docked, on: axis)
            + CGFloat(index) * metrics.ringStep(on: axis)
    }

    /// 卡片沿条从哪儿开始，从条自己的前缘量起。
    ///
    /// 钳制是相对**窗口**而不是相对条的：卡片可以比条长，而窗口在它两端都还有空间，
    /// 所以卡片被允许进到那片空间里——从条的起点之前开始——而不是被推到窗口边缘齐边切掉。
    static func cardPadding(
        ringCentre: CGFloat,
        cardAlong: CGFloat,
        railAlong: CGFloat,
        panelAlong: CGFloat
    ) -> CGFloat {
        let raw = ringCentre - cardAlong / 2
        let first = -railAlong
        let last = max(panelAlong - railAlong - cardAlong, first)
        return min(max(raw, first), last)
    }

    /// 指针落在卡片里的哪儿：环心相对卡片自己前缘的位置，
    /// 于是即使卡片被钳得离开了中心，尖端也仍然指着那个环。
    /// 与卡片的圆角保持一个半径加半个指针高的距离，免得尾巴长到圆角上。
    static func pointerCentre(
        ringCentre: CGFloat,
        cardPadding: CGFloat,
        cardAlong: CGFloat
    ) -> CGFloat {
        let raw = ringCentre - cardPadding
        let inset = RailCardLayout.cornerRadius + RailCardLayout.pointerHeight / 2
        let first = min(inset, cardAlong / 2)
        let last = max(cardAlong - inset, first)
        return min(max(raw, first), last)
    }

    /// 卡片离条多远。
    ///
    /// 在条旁边是它自己的宽度加上指针和间隙；在条下面是条的厚度加上间隙，
    /// 因为那个方向上指针本来就在卡片自己的 frame 里。
    static func cardOffset(edge: RailEdge, railSize: CGSize, notchSize: CGSize?) -> CGSize {
        switch edge.axis {
        case .vertical:
            let inset = RailCardLayout.width
                + RailCardLayout.pointerWidth
                + RailCardLayout.horizontalGap
            return CGSize(width: inset * edge.cardDirection, height: 0)
        case .horizontal:
            let bottom = notchSize.map {
                RailHitArea.notchSurface(
                    rail: CGRect(origin: .zero, size: railSize),
                    notchSize: $0
                ).maxY
            } ?? railSize.height
            return CGSize(width: 0, height: bottom + RailCardLayout.horizontalGap)
        }
    }
}

/// 条停在哪儿，以及跨启动的记忆。
///
/// 位置是**条的**，不是窗口的。窗口比条宽得多（它带着卡片展开的空间），
/// 而条在窗口的哪一侧会随着条跨过屏幕中线而翻转。存窗口的位置会让条在那个瞬间
/// 跳一个卡片的宽度——而那正是用户手里握着的东西。
///
/// 两个坐标都是「条可移动范围」的比例而不是绝对点数，所以显示器、菜单栏或 Dock
/// 在两次运行之间变了，条也会落在合理的位置。
@MainActor
@Observable
final class RailPlacement {
    private(set) var dock: RailDock
    /// 0 把条放在可用区左边，1 放在右边。只在悬浮时有意义。
    private(set) var horizontalRatio: Double
    /// 0 把条的上沿放在可用区顶端，1 让它的底沿落在底端。
    private(set) var verticalRatio: Double

    /// 条的上沿在窗口里的位置，从窗口自己的上沿往下量——SwiftUI 的方向。
    ///
    /// 由最后一次放置窗口的人写入，因为它只能从屏幕算出来：窗口被留在可用区以内
    /// 好让卡片总有空间，条停在屏幕顶端或底端附近时窗口无法再往前，那最后一段就得靠
    /// 条**在窗口内**移动。少了它，条会在离屏幕两端几百点的地方停死。
    private(set) var railTop: CGFloat = 0

    /// 同样，沿窗口的另一轴。只有横在屏幕顶端的条会在这个方向移动；
    /// 贴着侧边时条被钉在窗口的一侧，这里恒为 0。
    private(set) var railLeading: CGFloat = 0

    /// 只在贴住物理刘海时存在；从不持久化。
    var notch: CGRect?

    /// 条被留在哪块显示器上，按 `RailScreen` 的命名。
    ///
    /// 两个比例是**某一块**屏可用区的比例，它们只说条在一块屏上的哪里，不说哪一块。
    /// 少了它，条每次启动、每次改设置、每次重新放置都会回到当时的主屏。
    private(set) var display: String?

    /// 条正被拖着横穿屏幕。
    ///
    /// 拖动现在归窗口所有、不在窗口里的某个视图手里，所以内容是这样知道的：
    /// 指针扫过环时卡片要收起来，条也不能从握着它的那只手底下自己藏起来。
    var isDragging = false

    /// 面板正被按着鼠标，不论有没有移动过。
    ///
    /// `isDragging` 是在第一次**移动**时才置位的，按下到那一帧之间有空档。
    /// 在那个空档里移动面板比拖动中移动更糟：抓取偏移是按下时量的，
    /// 指针一动的瞬间条就会跳。
    var isPressed = false

    /// 条自己的右键菜单正开着。
    ///
    /// 菜单弹出来时指针在菜单上，用观察器的每一条判据看都在条之外——少了这个标志，
    /// 菜单一出现条就会卷成细条，菜单就指着一片空了。
    var isMenuOpen = false

    /// 条是完整展开还是卷成了细条。
    ///
    /// 由内容决定——它取决于指针在哪——再镜像到这里，因为窗口需要知道它自己有多少
    /// 可以被抓住，而它从外面看不到这个状态。
    var isRailExpanded = true

    init(
        dock: RailDock = .edge(.right),
        horizontalRatio: Double = 1,
        verticalRatio: Double = 0.5,
        display: String? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.dock = dock
        self.horizontalRatio = horizontalRatio.clampedToUnitRange
        self.verticalRatio = verticalRatio.clampedToUnitRange
        self.display = display
        self.defaults = defaults
    }

    /// 卡片往哪边开。贴边时是融进的那条边；悬浮时是条所在的那半屏。
    var edge: RailEdge {
        dock.edge ?? (horizontalRatio < 0.5 ? .left : .right)
    }

    var isDocked: Bool { dock.isDocked }

    // MARK: - 持久化

    static func restored(defaults: UserDefaults = .standard) -> RailPlacement {
        let dock: RailDock = if defaults.object(forKey: Key.floating) as? Bool == true {
            .floating
        } else {
            .edge(defaults.string(forKey: Key.edge).flatMap(RailEdge.init(rawValue:)) ?? .right)
        }

        return RailPlacement(
            dock: dock,
            horizontalRatio: defaults.object(forKey: Key.horizontalRatio) as? Double ?? 1,
            verticalRatio: defaults.object(forKey: Key.verticalRatio) as? Double ?? 0.5,
            display: defaults.string(forKey: Key.display),
            defaults: defaults
        )
    }

    /// 放置因为「没有别的路径已经移动过窗口」而改变时调用——比如在设置里选位置。
    /// `RailWindowController` 用它来重新放置窗口。
    var onChange: (() -> Void)?

    /// 条变长或变短了，而没有任何设置变化。
    ///
    /// 订阅增删就会这样。条在窗口里坐哪儿是按条的长度算出来的，这个和在条短一项时
    /// 算过之后就不再重算——最后一个环会挂在窗口边缘之外，画在一个点不到的地方。
    ///
    /// **条被握着时不重放**，那是在移动窗口本身、会为同一个 frame 打架——
    /// 而且不只是「拖动中不算」：按下到第一次移动之间抓取偏移已经量好了，
    /// 那时重新放置会让指针一动条就跳。
    func railLengthChanged() {
        guard !isDragging, !isPressed else { return }
        onChange?()
    }

    /// 把条带到另一块显示器上，保持它在一块屏上的相对位置。
    ///
    /// 两个比例是某一块屏可用区的比例，所以不需要调整：无论两块屏尺寸差多少，
    /// 条都会落在新屏上与旧屏相同的位置。变的只有显示器的名字。
    ///
    /// 与其它移动一样存下来，这样把「跟随指针所在显示器」关掉之后，
    /// 条会留在它最后被带到的那块屏上，而不是被扔回桌子另一头。
    @discardableResult
    func move(toDisplay identifier: String) -> Bool {
        guard !isDragging, !isPressed else { return false }
        guard display != identifier else { return true }

        record(
            dock: dock,
            horizontalRatio: horizontalRatio,
            verticalRatio: verticalRatio,
            display: identifier
        )
        onChange?()
        return true
    }

    /// 改变条应该停在哪儿，并请求把它移过去。
    func update(dock: RailDock, horizontalRatio: Double? = nil, verticalRatio: Double? = nil) {
        record(
            dock: dock,
            horizontalRatio: horizontalRatio ?? self.horizontalRatio,
            verticalRatio: verticalRatio ?? self.verticalRatio,
            display: display
        )
        onChange?()
    }

    /// 存下一个条**已经在**的放置位置。
    ///
    /// 由拖动使用：拖动过程中窗口跟着指针走，再请求移一次就是为同一个 frame 打架。
    func record(dock: RailDock, horizontalRatio: Double, verticalRatio: Double, display: String?) {
        self.dock = dock
        self.horizontalRatio = horizontalRatio.clampedToUnitRange
        self.verticalRatio = verticalRatio.clampedToUnitRange
        self.display = display

        let defaults = self.defaults
        defaults.set(!dock.isDocked, forKey: Key.floating)
        if let edge = dock.edge { defaults.set(edge.rawValue, forKey: Key.edge) }
        defaults.set(self.horizontalRatio, forKey: Key.horizontalRatio)
        defaults.set(self.verticalRatio, forKey: Key.verticalRatio)
        defaults.set(display, forKey: Key.display)
    }

    func setRailOffset(top: CGFloat, leading: CGFloat) {
        if abs(railTop - top) > 0.5 { railTop = top }
        if abs(railLeading - leading) > 0.5 { railLeading = leading }
    }

    /// 存储用的 defaults 域；测试可注入。
    private let defaults: UserDefaults

    enum Key {
        static let edge = "rail.edge"
        static let floating = "rail.floating"
        static let horizontalRatio = "rail.horizontalRatio"
        static let verticalRatio = "rail.verticalRatio"
        static let display = "rail.display"
    }
}

extension Double {
    var clampedToUnitRange: Double { min(max(self, 0), 1) }
}
