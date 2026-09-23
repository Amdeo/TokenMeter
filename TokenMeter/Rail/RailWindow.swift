import AppKit
import SwiftUI

/// 悬浮条的窗口，它也负责把自己拖来拖去。
///
/// 移植自 Pulse 的 `FloatingPanel`。
///
/// **拖动为什么在窗口里而不是在 SwiftUI 里**：一次按下只有先被 `NSHostingView`
/// 里的某个视图认领才会送到视图手上，而条身平直那一段是没有任何视图认领的空白——
/// 结果就是只能抓住环、别处都抓不动。`sendEvent` 看到窗口服务器交给这个窗口的每一个
/// 事件，早于 SwiftUI 的任何命中测试，谁也拿不走这个拖动。
///
/// 被拖动的是**条**，不是窗口。窗口比条宽得多（它带着卡片展开的空间），
/// 而条在窗口的哪一侧会随它跨过屏幕中线而翻转；跟着指针移动窗口会让条在那个瞬间横向甩出去。
@MainActor
final class RailWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 什么可以被抓住，用窗口自己的左上角坐标：条画出来时是条，没画出来时是它的细条。
    /// 由控制器提供——只有它知道现在有几个订阅。
    var grabArea: (() -> CGRect)?
    /// 条自己的矩形，不论当前在屏幕上是什么状态。
    ///
    /// 与 `grabArea` 分开是刻意的：卷起来时抓到的是细条，但被**放置**的仍然是条——
    /// 存下来的位置是条的位置，把一个 20pt 的细条交给期待 64pt 条的放置逻辑，
    /// 第一次拖动就会把窗口甩到屏幕另一头。
    var railFrame: (() -> CGRect)?
    /// 条在某条边上的尺寸。拖动需要它来算条还没到的那条边。
    var railSize: ((RailEdge, Bool) -> CGSize)?
    /// 条在某条边上时窗口该多大。与 `railSize` 同源：只有控制器知道当前的尺寸预算，
    /// 这里再算一遍就会算出另一个数。
    var panelSize: ((RailEdge, CGSize, CGSize?) -> CGSize)?

    /// 一次没有移动的短按。控制器把它映射到某个环上；条身上的空白仍然只用于拖动。
    var onClick: ((CGPoint) -> Void)?
    /// 右键弹的菜单。每次点击现做，这样它能带上此刻才成立的东西。
    var contextMenu: (() -> NSMenu)?
    var placement: RailPlacement?

    /// 指针是在条的哪个位置抓住它的，这样拖动开始时条不会跳到指针正下方居中。
    /// 没有拖动在进行时为 nil。
    private var grab: CGSize?
    private var pressedAt: CGPoint?
    private var didDrag = false

    /// 贴顶时条要画在菜单栏**之上**，也只有贴顶时如此。
    ///
    /// `.floating` 在菜单栏自己的层级**之下**，放在屏幕边缘的条会直接被菜单栏盖住。
    /// `.statusBar` 比菜单栏高一级，也是菜单栏自己的那些附加项用的层级——够得着屏幕边缘，
    /// 又没高到盖住系统弹窗。别的地方条不因为这个改变，离开顶边就回到 `.floating`，
    /// 免得它平白无故压在菜单栏上。
    func applyLevel(for dock: RailDock) {
        level = dock.edge == .top ? .statusBar : .floating
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        // 拖动之前：control-左击在 macOS 上**就是**右键，
        // 把它当成按下会变成拖着条走。
        case .rightMouseDown where showMenu(event): return
        case .leftMouseDown where event.modifierFlags.contains(.control) && showMenu(event): return
        case .leftMouseDown where begin(event): return
        case .leftMouseDragged where carry(): return
        case .leftMouseUp where finish(): return
        default: super.sendEvent(event)
        }
    }

    /// 把条自己的菜单弹出来，如果这一下点在了可以抓的地方。
    ///
    /// 与拖动用的是同一套几何，所以能抓起来的地方就能右键——包括细条，那正是关键：
    /// 条大部分时间卷成 6pt，一个只能靠先悬停才够得到的菜单就是又一件要记的事。
    private func showMenu(_ event: NSEvent) -> Bool {
        guard
            let area = grabArea?(),
            let menu = contextMenu?(),
            let view = contentView,
            area.contains(local(event))
        else { return false }

        // `popUp` 跑自己的跟踪循环，所以标志位要等菜单关掉才清——
        // 那正好是条必须保持展开的整个区间。
        placement?.isMenuOpen = true
        menu.popUp(positioning: nil, at: view.convert(event.locationInWindow, from: nil), in: view)
        placement?.isMenuOpen = false
        return true
    }

    private func begin(_ event: NSEvent) -> Bool {
        let location = local(event)
        guard
            let area = grabArea?(),
            let rail = railFrame?(),
            area.contains(location)
        else { return false }

        // 即使抓到的是细条，也按**条**来量，这样指针保持握在条上，
        // 而不是握在屏幕上恰好出现的某个替身上。
        //
        // 屏幕坐标自下而上，所以条的下沿是「窗口上沿减去它到窗口上沿的距离」。
        let origin = CGPoint(x: frame.minX + rail.minX, y: frame.maxY - rail.maxY)
        let pointer = NSEvent.mouseLocation
        grab = CGSize(width: pointer.x - origin.x, height: pointer.y - origin.y)
        pressedAt = location
        didDrag = false
        // 抓取偏移从这里起就固定了，所以在按钮抬起之前什么都不能移动窗口——
        // 此刻重新放置就是指针第一次移动时的一跳。
        placement?.isPressed = true
        return true
    }

    private func carry() -> Bool {
        guard
            let grab,
            let placement,
            let railFrame = railFrame?()
        else { return false }

        let pointer = NSEvent.mouseLocation

        // **用指针所在的那块屏，不是窗口所在的那块。** 条每一帧都被钳在可用区以内，
        // 拿窗口自己的屏去量这件事正是把条钉死在一块显示器上的原因：
        // 往第二块屏拖的每一帧都被放回原处，永远跨不过去。
        guard let screen = RailScreen.containing(pointer) ?? self.screen ?? NSScreen.main
        else { return false }

        let visible = screen.visibleFrame
        let rail = railFrame.size

        if !didDrag {
            didDrag = true
            placement.isDragging = true
        }

        let wanted = RailGeometry.clampedRailOrigin(
            CGPoint(x: pointer.x - grab.width, y: pointer.y - grab.height),
            railSize: rail,
            visible: visible
        )
        let dock = RailGeometry.dockedEdge(
            forPointer: pointer,
            railOrigin: wanted,
            railSize: rail,
            visible: visible
        )

        // 条在跨到另一根轴时会转过来，所以从这里开始一切都按它**即将**处于的朝向量，
        // 不是它正在离开的那个。按旧的量会在轴改变的那一帧把窗口甩过屏幕。
        //
        // 从顶边下来时 `placement.edge` 慢一帧——它还是 `.top`，于是会按横向轴给窗口
        // 定尺寸，而内容已经重画成竖向的条了。所以悬浮落地时按它所在的半屏选边，
        // 与放置逻辑选边的方式一致。
        let landing: RailEdge = if let docked = dock.edge {
            docked
        } else if placement.edge.axis == .horizontal {
            pointer.x < visible.midX ? .left : .right
        } else {
            placement.edge
        }
        let landingRail = railSize?(landing, dock.isDocked) ?? rail
        let landingNotch = dock.edge == .top ? RailScreen.notch(of: screen) : nil
        let landingPanel = panelSize?(landing, landingRail, landingNotch?.size)
            ?? RailHitArea.panelSize(
                for: landing,
                railLength: max(landingRail.width, landingRail.height),
                notchSize: landingNotch?.size,
                metrics: RailMetrics()
            )

        // 换到新朝向后，位置要在指针底下。
        //
        // 转向是**轴**的改变，不能从条的长度推出来：离开边时两端会少掉外扩的那段留白，
        // 同一条悬浮着就短 48pt——那会让每一次贴边↔悬浮的切换都有一帧在指针底下重新居中、
        // 下一帧又弹回去。所以抓取偏移在真的转向时要重新量，否则转向后的那一帧会把它抵消掉。
        let turned = landing.axis != placement.edge.axis

        let origin: CGPoint
        if turned {
            origin = CGPoint(x: pointer.x - landingRail.width / 2, y: pointer.y - landingRail.height / 2)
            self.grab = CGSize(width: landingRail.width / 2, height: landingRail.height / 2)
        } else if landingRail != rail {
            // 同轴、不同长度：条离开边时两端各少掉外扩的那段留白，悬浮时就短 48pt。
            // 一半从每端拿掉，意味着只要条的**中心**不动，环就不会动。
            // 保持抓取偏移则会钉住远端，让所有环从握着它的那只手底下滑过去 48pt。
            let shrink = CGSize(
                width: (rail.width - landingRail.width) / 2,
                height: (rail.height - landingRail.height) / 2
            )
            let recentred = CGSize(width: grab.width - shrink.width, height: grab.height - shrink.height)
            self.grab = recentred
            origin = RailGeometry.clampedRailOrigin(
                CGPoint(x: pointer.x - recentred.width, y: pointer.y - recentred.height),
                railSize: landingRail,
                visible: visible
            )
        } else {
            origin = wanted
        }

        let ratios = RailGeometry.ratios(forRailAt: origin, in: visible, rail: landingRail)
        placement.record(
            dock: dock,
            horizontalRatio: ratios.h,
            verticalRatio: ratios.v,
            display: RailScreen.identifier(of: screen)
        )

        placement.notch = landingNotch

        // 几何只有一个来源：问放置逻辑它把东西放在哪儿，而不是在这里再算一遍。
        let layout = RailGeometry.layout(
            dock: dock,
            horizontalRatio: ratios.h,
            verticalRatio: ratios.v,
            notch: landingNotch,
            visible: visible,
            topEdge: RailGeometry.topEdge(
                screenFrame: screen.frame,
                visibleFrame: visible,
                topInset: screen.safeAreaInsets.top
            ),
            panel: landingPanel,
            rail: landingRail
        )
        applyLevel(for: dock)
        setFrame(layout.frame, display: true)
        // 与 `placePanel` 同一条规则：frame 是请求值，在放不下的屏幕上条必须按窗口
        // **实际拿到**的 frame 来量，否则它会从指针底下滑走恰好那个差值。
        let offsets = RailGeometry.offsets(forRailTopLeft: layout.railOrigin, in: frame, rail: landingRail)
        placement.setRailOffset(top: offsets.top, leading: offsets.leading)
        return true
    }

    private func finish() -> Bool {
        guard grab != nil else { return false }
        let click = didDrag ? nil : pressedAt
        grab = nil
        pressedAt = nil
        didDrag = false
        placement?.isDragging = false
        placement?.isPressed = false
        if let click { onClick?(click) }
        return true
    }

    /// 事件在窗口自己的坐标里的位置，原点是左上角，与 SwiftUI 对齐——
    /// 命中区就是用那个空间给的。
    private func local(_ event: NSEvent) -> CGPoint {
        CGPoint(x: event.locationInWindow.x, y: frame.height - event.locationInWindow.y)
    }
}
