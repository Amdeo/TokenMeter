import SwiftUI

/// 悬浮条的根内容：指针监听、条、悬停展开的详情卡片，以及展开/收起状态。
///
/// 移植自 Pulse 的 `FloatingUsagePanelView`，去掉账号拆分、bot 标记与预算预测。
///
/// **窗口尺寸恒定，卡片展开时不变大。** 变大就会移动 SwiftUI 内容所在坐标空间的原点，
/// 条在其中看起来会横向弹开再滑回来。所以卡片是挂在条上的浮层，
/// 而窗口从一开始就留出了它展开所需的空间——多出来的部分是透明的。
struct RailView: View {
    let store: UsageStore
    let settings: SettingsStore
    let placement: RailPlacement
    /// 条的长度变了（订阅增删），窗口需要重新放置。
    let onRailLengthChange: () -> Void

    /// 卡片属于哪个**环**，也就是哪条订阅。
    @State private var selectedID: UUID?
    /// 卡片真实布局出来的高度。供应商报的额度行数不同，卡片高度不是事先能知道的，
    /// 而卡片的摆放与指针的瞄准都依赖它。
    @State private var cardHeight: CGFloat = RailCardLayout.estimatedHeight
    /// 指针是不是在条上。条只在指针在时展开，其余时间由细条代表它。
    @State private var isHovered = false
    /// 收起前的一刻宽限，免得路过时蹭到条的一个角就让它抖一下。
    @State private var hideAfterDelay: Task<Void, Never>?
    /// 指针在条窗口里的位置，供卡片与命中判定使用。
    @State private var pointerPoint: CGPoint?

    var body: some View {
        // 条钉在一个铺满窗口的占位视图的对应角上，而且是用 overlay 而不是 stack 子视图：
        // overlay 保持理想尺寸、不被可用空间挤压，所以无论周围怎样，条都焊在屏幕边上。
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                // 唯一会收起卡片的东西：指针离开了内容。跟踪位置而不是进入/离开事件，
                // 意味着从环移到卡片、或者在两个环之间穿行，都不会打断任何东西。
                RailPointerWatcher(onChange: pointerMoved)
            )
            .overlay(alignment: placement.edge.railAlignment) {
                RailDockView(
                    entries: entries,
                    edge: placement.edge,
                    isDocked: placement.isDocked,
                    isExpanded: isExpanded,
                    notchSize: placement.notch?.size,
                    alert: alertTint,
                    selectedID: selectedID,
                    glassEnabled: settings.glassEffectEnabled
                )
                .fixedSize()
                .overlay(alignment: placement.edge.cardAlignment) {
                    if let selected = selectedEntry, let index = selectedIndex {
                        RailDetailCard(
                            entry: selected,
                            edge: placement.edge,
                            glassEnabled: settings.glassEffectEnabled,
                            pointerCenter: pointerCentre(for: index)
                        )
                        .fixedSize()
                        .background(
                            GeometryReader { proxy in
                                Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                                    cardHeight = height
                                }
                            }
                        )
                        .padding(alongEdge, cardPadding(for: index))
                        .transition(cardReveal(for: index))
                        .offset(cardOffset)
                    }
                }
                // **在卡片动画之内、移动条之前。** `.animation(_:value:)` 会在那个值变化时
                // 给它子树里所有可动画的东西做动画——所以把下面的偏移放进来，
                // 收起卡片会连带把条的**位置**弹一下。那正是拖动第一帧发生的事：
                // 卡片收起，然后条追着指针弹过去，看起来像从手里滑走了。
                .animation(.spring(response: 0.34, dampingFraction: 0.82), value: selectedID)
                // 泊位从细条里长出来又收回去。**放在真正改变尺寸的那个东西上**——
                // 不是外面那个容器，那里还装着下面的偏移。`isExpanded` 在拖动中一定会翻转：
                // 条离开边（`isDocked`）或者指针跨过内容（`isHovered`）。
                // 从外面做动画会把条的**位置**一起带走，于是条一离开边就从指针底下弹开。
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isExpanded)
                // 把条移到用户在屏幕上拖到的地方。
                //
                // **在卡片挂上去之后，绝不在之前。** 卡片是对齐到它所在浮层的角上的，
                // 先加内边距会让它锚到**窗口**的角上，于是每张卡片都会画高 `railTop` 那么多、
                // 被窗口边缘齐边切掉。而且要在上面那些动画**外面**，绝不在里面：这跟的是指针。
                .padding(.top, placement.railTop)
                .padding(.leading, placement.railLeading)
            }
            // 窗口自己的矩形是按条的长度算出来的，而那个和只在有人要求时才重算。
            // 增删一条订阅就会改变长度，所以这里必须主动要求。
            .onChange(of: entries.count, initial: true) { _, _ in
                onRailLengthChange()
            }
            // 窗口负责拖动，所以内容是从这里知道那件事的：能抓多少取决于条有没有画出来，
            // 而那只有这一侧知道。
            .onChange(of: isExpanded, initial: true) { _, expanded in
                placement.isRailExpanded = expanded
            }
            // 条正被带着横穿屏幕时，一张开着的卡片是噪音：指针在扫过那些环，不是在读它们。
            .onChange(of: placement.isDragging) { _, dragging in
                if dragging { deselect() }
            }
            .onDisappear {
                hideAfterDelay?.cancel()
                hideAfterDelay = nil
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("TokenMeter 用量悬浮条")
    }

    // MARK: - 数据

    /// 一条订阅一个环，顺序即订阅顺序。
    private var entries: [RailEntry] {
        RailEntryBuilder.entries(subscriptions: store.subscriptions, snapshots: store.snapshots)
    }

    /// 条是否完整画出来。
    ///
    /// 收起只对**贴边**的条生效。贴着屏幕侧面时条挡着背后的东西，而把它找回来只需要
    /// 朝一条不可能错过的屏幕边甩一下指针；悬在桌面上时它是用户刻意放在那里的，
    /// 一个停在屏幕中间的药丸既不妨碍什么，也不容易再找到。所以离开屏幕边就让它保持展开。
    ///
    /// 派生而不是存下来的，所以它和设置里关掉自动收起都是立刻生效，
    /// 而不是等指针下一次路过。
    private var isExpanded: Bool {
        !settings.railAutoCollapse || !placement.isDocked || isHovered || isNotchHeld
    }

    /// 贴着刘海时，条被按住、拖动或菜单开着的时候要保持展开。
    private var isNotchHeld: Bool {
        placement.notch != nil && (placement.isPressed || placement.isDragging || placement.isMenuOpen)
    }

    /// 某个额度快到临界时，细条染上它的颜色。
    ///
    /// 收起条不该把值得看的东西一起收掉。全部正常时返回 nil，保持中性。
    /// 取的是**状态色**而不是环色：用户给某个环选的颜色是身份，细条的染色说的是状态，
    /// 一个被选中的颜色不该让一条一切都正常的条看起来像在报警。
    private var alertTint: Color? {
        let worst = entries
            .filter { $0.state == .realtime }
            .max { ($0.fraction ?? 0) < ($1.fraction ?? 0) }
        guard let worst, worst.status != .normal else { return nil }
        return worst.statusTint
    }

    private var selectedEntry: RailEntry? {
        entries.first { $0.id == selectedID }
    }

    private var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return entries.firstIndex { $0.id == selectedID }
    }

    // MARK: - 几何

    /// 条当前的尺寸。窗口一直按最大尺寸留着，所以卡片摆放与指针判定量的都是它，
    /// 不是窗口。
    private var railSize: CGSize {
        RailLayout.size(for: entries.count, on: placement.edge.axis, docked: placement.isDocked)
    }

    private var panelSize: CGSize {
        RailHitArea.panelSize(
            for: placement.edge,
            railLength: max(railSize.width, railSize.height),
            notchSize: placement.notch?.size
        )
    }

    /// 卡片沿哪个方向滑动才能与它所属的那个环保持齐平。
    private var alongEdge: Edge.Set {
        placement.edge.isVertical ? .top : .leading
    }

    /// 窗口沿那个方向的自身尺寸，卡片就是被钳在它里面。
    private var panelAlong: CGFloat {
        placement.edge.isVertical ? panelSize.height : panelSize.width
    }

    /// 条在自己的走向上被偏移了多少。
    private var railAlong: CGFloat {
        placement.edge.isVertical ? placement.railTop : placement.railLeading
    }

    /// 一个环心**沿**条的位置，用的是条与卡片共享的坐标空间。
    private func ringCentre(for index: Int) -> CGFloat {
        RailGeometry.ringCentre(forIndex: index, on: placement.edge.axis, docked: placement.isDocked)
    }

    /// 卡片自己在同一根轴上的尺寸：在条旁边是它的高，在条下面是它的宽。
    private var cardAlong: CGFloat {
        placement.edge.isVertical ? cardHeight : RailCardLayout.width
    }

    private func cardPadding(for index: Int) -> CGFloat {
        RailGeometry.cardPadding(
            ringCentre: ringCentre(for: index),
            cardAlong: cardAlong,
            railAlong: railAlong,
            panelAlong: panelAlong
        )
    }

    private func pointerCentre(for index: Int) -> CGFloat {
        RailGeometry.pointerCentre(
            ringCentre: ringCentre(for: index),
            cardPadding: cardPadding(for: index),
            cardAlong: cardAlong
        )
    }

    /// 卡片离条多远。
    private var cardOffset: CGSize {
        RailGeometry.cardOffset(
            edge: placement.edge,
            railSize: railSize,
            notchSize: placement.notch?.size
        )
    }

    /// 卡片怎么出现与消失：从条所在的那一侧长出来，像系统气泡从它的箭头展开一样。
    ///
    /// 锚点用的是**带内边距的那个盒子**的空间，不是卡片自己的。过渡作用于被插入或被移除的
    /// 整个视图——`.transition` 在 modifier 链上的位置不改变这一点——而这里被移除的是
    /// 卡片**加上**把它托在环旁边的那个间隙。因此按它自己的中心缩放会沿条把卡片拖走
    /// 间隙的一个比例。
    private func cardReveal(for index: Int) -> AnyTransition {
        let gap = cardPadding(for: index)
        let box = gap + cardAlong
        let along = box > 0 ? min(max((gap + cardAlong / 2) / box, 0), 1) : 0.5
        let across = placement.edge.cardRevealOrigin
        let anchor = placement.edge.isVertical
            ? UnitPoint(x: across, y: along)
            : UnitPoint(x: along, y: across)

        return .modifier(
            active: RailCardReveal(progress: 0, anchor: anchor, axis: placement.edge.axis, direction: placement.edge.cardDirection),
            identity: RailCardReveal(progress: 1, anchor: anchor, axis: placement.edge.axis, direction: placement.edge.cardDirection)
        )
    }

    // MARK: - 指针

    /// 指针到达某个环上时展开它的详情。
    private func select(_ entry: RailEntry) {
        guard !placement.isDragging, selectedID != entry.id else { return }
        selectedID = entry.id
    }

    /// 指针落在哪个环上就展开它的详情。
    ///
    /// **用采样的位置反推，不用跟踪区。** 位置是可以随时问的、永远不过期，
    /// 也不会因为布局 pass 在静止的指针底下发出虚假事件——`isOverContent` 用的已经是
    /// 同一条路径，这里只是把同一个点再问一次「它落在哪个环的圆里」。
    /// 命中判定本身是纯几何（`RailHitArea.slot`），所以它可以被单元测试钉住，
    /// 而不必依赖一个只能在真实鼠标下观察的机制。
    private func selectRing(at point: CGPoint) {
        guard !placement.isDragging else { return }
        guard let index = RailHitArea.slot(
            at: point,
            edge: placement.edge,
            entryCount: entries.count,
            railSize: railSize,
            panelSize: panelSize,
            railTop: placement.railTop,
            railLeading: placement.railLeading,
            docked: placement.isDocked
        ), index < entries.count else { return }

        select(entries[index])
    }

    /// 指针不再在两者之上时，收起详情，并最终收起条本身。
    private func pointerMoved(_ point: CGPoint?) {
        if pointerPoint != point { pointerPoint = point }

        if let point, isOverContent(point) {
            hideAfterDelay?.cancel()
            hideAfterDelay = nil

            // 指针在窗口上就是「悬停」，无论它是怎么到的。细条的跟踪区不能是唯一的入口，
            // 因为条悬浮着时**根本没有**细条——把一条悬浮的条拖到屏幕边上时，
            // `isHovered` 还是 false，它会在握着它的那只手里啪地合上。
            //
            // 这不会重启那个「只认进入」规则要防的开/关循环：收起只在同一个判定说指针
            // 不在窗口上时才发生，所以两者不可能互相矛盾。
            if !isHovered { isHovered = true }
            selectRing(at: point)
            return
        }

        deselect()
        scheduleHide()
    }

    private func scheduleHide() {
        guard isHovered, hideAfterDelay == nil else { return }

        hideAfterDelay = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            hideAfterDelay = nil
            // 绝不在拖动中：拖动时指针按设计离窗口很远。菜单开着时同理——
            // 指针在菜单上，而菜单不是窗口。两者都会重新触发：
            // 这里 `hideAfterDelay` 已经是 nil，观察器下一次 tick 会再问一次。
            guard !placement.isDragging, !placement.isMenuOpen, !isNotchHeld else { return }
            isHovered = false
        }
    }

    /// 窗口里的一个点是不是落在窗口真的画了东西的地方。
    ///
    /// 窗口大部分是空的、透明的空间——它一直被保持在整个尺寸上（见 `RailPanelLayout`），
    /// 所以只问「指针在不在窗口里」会让卡片在一个离它很远的巨大空白区上保持展开。
    private func isOverContent(_ point: CGPoint) -> Bool {
        if let notch = placement.notch, notchTarget(notch).contains(point) { return true }
        let edge = placement.edge

        // 卷起来时只认细条自己的目标。去量条的全部范围会让窗口在它并不绘制的那
        // 六十点空处上保持展开。
        if !isExpanded {
            if placement.notch != nil { return false }
            return RailHitArea.strip(
                edge: edge,
                railSize: railSize,
                panelSize: panelSize,
                railTop: placement.railTop,
                railLeading: placement.railLeading
            ).contains(point)
        }

        let rail = RailHitArea.rail(
            edge: edge,
            railSize: railSize,
            panelSize: panelSize,
            railTop: placement.railTop,
            railLeading: placement.railLeading
        )
        if let notch = placement.notch {
            let surface = RailHitArea.notchSurface(rail: rail, notchSize: notch.size)
            if RailNotchBerthShape(notchSize: notch.size)
                .path(in: surface.insetBy(dx: -RailLayout.flareWidth, dy: 0)).contains(point) { return true }
        }
        if rail.contains(point) { return true }

        guard let index = selectedIndex else { return false }

        // 沿卡片横跨窗口的整个范围，而不是停在卡片自己的边缘上，
        // 这样指针从条走到卡片之间跨过的那个间隙也被盖住了。
        // 沿条方向的宽容让边界不至于像一根绊线。
        let start = railAlong + cardPadding(for: index) - RailLayout.pointerSlack
        let length = cardAlong + RailLayout.pointerSlack * 2

        let band = placement.edge.isVertical
            ? CGRect(x: 0, y: start, width: panelSize.width, height: length)
            : CGRect(x: start, y: 0, width: length, height: panelSize.height)
        return band.contains(point)
    }

    /// 硬件刘海在监听器的翻转坐标里的目标。
    private func notchTarget(_ notch: CGRect) -> CGRect {
        CGRect(
            x: placement.railLeading + railSize.width / 2 - notch.width / 2,
            y: placement.railTop - notch.height,
            width: notch.width,
            height: notch.height
        )
    }

    /// 指针离开整个窗口之后收起详情。
    private func deselect() {
        guard selectedID != nil else { return }
        selectedID = nil
    }
}

/// 驱动 `RailView.cardReveal`。刻意克制：窗口只有几百点宽，
/// 大幅缩放或长距离滑动读起来是乱动，不是展开。
private struct RailCardReveal: ViewModifier {
    /// 卡片不在时是 0，完全出现后是 1。
    let progress: Double
    let anchor: UnitPoint
    let axis: RailEdge.Axis
    let direction: CGFloat

    func body(content: Content) -> some View {
        let slide = (1 - progress) * 10 * direction
        return content
            .scaleEffect(0.88 + 0.12 * progress, anchor: anchor)
            .offset(
                x: axis == .vertical ? slide : 0,
                y: axis == .vertical ? 0 : slide
            )
            .opacity(progress)
    }
}
