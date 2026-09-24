import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import TokenMeter

/// 悬浮条几何回归：放置、贴边判定、细条包含关系与跨启动记忆。
@MainActor
struct RailPlacementTests {
    /// 一块 1440×900 的屏，菜单栏 25pt、Dock 60pt。
    private static let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private static let visibleFrame = CGRect(x: 0, y: 60, width: 1440, height: 815)

    private static func panelSize(_ edge: RailEdge, entries: Int = 3, notch: CGSize? = nil) -> CGSize {
        let metrics = RailMetrics()
        let rail = metrics.size(for: entries, on: edge.axis, docked: true)
        return RailHitArea.panelSize(
            for: edge,
            railLength: max(rail.width, rail.height),
            notchSize: notch,
            metrics: metrics
        )
    }

    // MARK: - 细条的包含关系

    @Test
    func collapsedStripStaysInsideTheRailOnEveryEdge() {
        // 上限取到 12：条是按订阅数变的，而订阅数没有编译期上界。
        #expect(RailHitArea.stripIsContainedInRail(maxEntries: 12))
    }

    // MARK: - 贴边判定

    @Test
    func throwingThePointerAtTheTopDocksTheRailToTheTop() {
        let rail = RailMetrics().size(for: 3, on: .vertical, docked: true)
        let dock = RailGeometry.dockedEdge(
            forPointer: CGPoint(x: 700, y: Self.visibleFrame.maxY - 4),
            railOrigin: CGPoint(x: 1376, y: 400),
            railSize: rail,
            visible: Self.visibleFrame
        )
        #expect(dock == .edge(.top))
    }

    @Test
    func theTopIsJudgedByThePointerNotByTheRail() {
        // 把条顶到屏幕上沿：它的上沿已经在屏幕顶端，但指针还在屏幕中间。
        // 按条判会让条一被拿起就翻倒，所以这里必须**不**贴顶。
        let rail = RailMetrics().size(for: 3, on: .vertical, docked: true)
        let origin = CGPoint(x: 700, y: Self.visibleFrame.maxY - rail.height)

        let dock = RailGeometry.dockedEdge(
            forPointer: CGPoint(x: 900, y: 400),
            railOrigin: origin,
            railSize: rail,
            visible: Self.visibleFrame
        )
        #expect(dock == .floating)
    }

    @Test
    func railNearTheLeftEdgeDocksLeftAndNearTheRightEdgeDocksRight() {
        let rail = RailMetrics().size(for: 3, on: .vertical, docked: true)

        #expect(
            RailGeometry.dockedEdge(
                forPointer: CGPoint(x: 100, y: 400),
                railOrigin: CGPoint(x: Self.visibleFrame.minX + 10, y: 300),
                railSize: rail,
                visible: Self.visibleFrame
            ) == .edge(.left)
        )
        #expect(
            RailGeometry.dockedEdge(
                forPointer: CGPoint(x: 1300, y: 400),
                railOrigin: CGPoint(x: Self.visibleFrame.maxX - rail.width - 10, y: 300),
                railSize: rail,
                visible: Self.visibleFrame
            ) == .edge(.right)
        )
    }

    @Test
    func aRailParkedNearButNotAtAnEdgeKeepsFloating() {
        let rail = RailMetrics().size(for: 3, on: .vertical, docked: true)
        let dock = RailGeometry.dockedEdge(
            forPointer: CGPoint(x: 900, y: 400),
            railOrigin: CGPoint(x: Self.visibleFrame.minX + RailGeometry.dockDistance + 40, y: 300),
            railSize: rail,
            visible: Self.visibleFrame
        )
        #expect(dock == .floating)
    }

    @Test
    func railOriginIsClampedInsideTheUsableArea() {
        let rail = RailMetrics().size(for: 3, on: .vertical, docked: true)
        let clamped = RailGeometry.clampedRailOrigin(
            CGPoint(x: 5000, y: -500),
            railSize: rail,
            visible: Self.visibleFrame
        )
        #expect(clamped.x == Self.visibleFrame.maxX - rail.width)
        #expect(clamped.y == Self.visibleFrame.minY)
    }

    // MARK: - 放置

    @Test
    func aRightDockedRailSitsFlushAgainstTheVisibleEdge() {
        let rail = RailMetrics().size(for: 3, on: .vertical, docked: true)
        let panel = Self.panelSize(.right)
        let layout = RailGeometry.layout(
            dock: .edge(.right),
            horizontalRatio: 1,
            verticalRatio: 0.5,
            notch: nil,
            visible: Self.visibleFrame,
            topEdge: Self.screenFrame.maxY,
            panel: panel,
            rail: rail
        )
        #expect(layout.railOrigin.x == Self.visibleFrame.maxX - rail.width)
    }

    @Test
    func aFloatingRailNeverTouchesTheEdge() {
        let rail = RailMetrics().size(for: 3, on: .vertical, docked: false)
        let panel = Self.panelSize(.right)

        // 存储的比例仍然是贴边时的 1，切到悬浮不能因此让条贴着屏幕边站。
        let atRatioOne = RailGeometry.layout(
            dock: .floating,
            horizontalRatio: 1,
            verticalRatio: 0.5,
            notch: nil,
            visible: Self.visibleFrame,
            topEdge: Self.screenFrame.maxY,
            panel: panel,
            rail: rail
        )
        #expect(atRatioOne.railOrigin.x <= Self.visibleFrame.maxX - rail.width - RailGeometry.dockDistance)

        let atRatioZero = RailGeometry.layout(
            dock: .floating,
            horizontalRatio: 0,
            verticalRatio: 0.5,
            notch: nil,
            visible: Self.visibleFrame,
            topEdge: Self.screenFrame.maxY,
            panel: panel,
            rail: rail
        )
        #expect(atRatioZero.railOrigin.x >= Self.visibleFrame.minX + RailGeometry.dockDistance)
    }

    @Test
    func aTopDockedRailStopsAtTheNotchLineRatherThanUnderTheMenuBar() {
        let notchHeight: CGFloat = 38
        let notch = CGRect(x: 640, y: Self.screenFrame.maxY - notchHeight, width: 160, height: notchHeight)
        let rail = RailMetrics().size(for: 3, on: .horizontal, docked: true)
        let panel = Self.panelSize(.top, notch: notch.size)

        let layout = RailGeometry.layout(
            dock: .edge(.top),
            horizontalRatio: 0.5,
            verticalRatio: 0.5,
            notch: notch,
            visible: Self.visibleFrame,
            topEdge: RailGeometry.topEdge(
                screenFrame: Self.screenFrame,
                visibleFrame: Self.visibleFrame,
                topInset: notchHeight
            ),
            panel: panel,
            rail: rail
        )
        // 条的上沿停在刘海自己那条线上，不是菜单栏下沿。
        #expect(layout.railOrigin.y == notch.minY)
        // 居中在刘海下：条比刘海宽，压在刘海后面的大半是画不出来的。
        #expect(layout.railOrigin.x == notch.midX - rail.width / 2)
    }

    @Test
    func topEdgeIsThePhysicalScreenTopOnlyWithoutANotch() {
        #expect(
            RailGeometry.topEdge(screenFrame: Self.screenFrame, visibleFrame: Self.visibleFrame, topInset: 0)
                == Self.screenFrame.maxY
        )
        #expect(
            RailGeometry.topEdge(screenFrame: Self.screenFrame, visibleFrame: Self.visibleFrame, topInset: 38)
                == min(Self.screenFrame.maxY - 38, Self.visibleFrame.maxY)
        )
    }

    @Test
    func offsetsAreMeasuredAgainstTheFrameTheWindowActuallyGot() {
        let rail = RailMetrics().size(for: 3, on: .vertical, docked: true)
        // AppKit 把一个放不下的窗口往下拉：请求 1133pt，拿到的是可用区那么高。
        let granted = CGRect(x: 100, y: 60, width: 342, height: 815)
        // 条的上沿在屏幕上 700 处，横向贴着屏幕右边。
        let railTopLeft = CGPoint(x: 1440 - rail.width, y: 700)

        let offsets = RailGeometry.offsets(forRailTopLeft: railTopLeft, in: granted, rail: rail)
        // 条的上沿仍在屏幕上同一个位置，只是它在窗口里的偏移变了。
        #expect(granted.maxY - offsets.top == railTopLeft.y)
        // 偏移被钳制在窗口之内：条绝不会被要求坐到自己所在窗口的外面去。
        #expect(offsets.top >= 0)
        #expect(offsets.top <= granted.height - rail.height)
    }

    @Test
    func offsetsClampRatherThanPlacingTheRailOutsideItsWindow() {
        let rail = RailMetrics().size(for: 3, on: .vertical, docked: true)
        let granted = CGRect(x: 100, y: 60, width: 342, height: 815)

        // 条在窗口右侧之外，横向偏移量必须被钳到窗口右沿。
        let far = RailGeometry.offsets(
            forRailTopLeft: CGPoint(x: 1376, y: 700),
            in: granted,
            rail: rail
        )
        #expect(far.leading == granted.width - rail.width)

        // 条在窗口上方之外，纵向偏移量必须被钳到窗口顶沿。
        let high = RailGeometry.offsets(
            forRailTopLeft: CGPoint(x: 120, y: 5000),
            in: granted,
            rail: rail
        )
        #expect(high.top == 0)

        // 够得着的时候不钳，位置原样保留。
        let reachable = RailGeometry.offsets(
            forRailTopLeft: CGPoint(x: granted.minX + 40, y: granted.maxY - 300),
            in: granted,
            rail: rail
        )
        #expect(granted.minX + reachable.leading == granted.minX + 40)
        #expect(granted.maxY - reachable.top == granted.maxY - 300)
    }

    // MARK: - 比例往返

    /// `ratios(forRailAt:)` 收的是条的**左下角**（屏幕坐标自下而上），
    /// 而 `layout` 给的是条的**左上角**——Pulse 的拖动路径也是这么用的，
    /// 两套约定都保留，这里做一次换算把话说清楚。
    private static func bottomLeft(of layout: RailGeometry.Layout, rail: CGSize) -> CGPoint {
        CGPoint(x: layout.railOrigin.x, y: layout.railOrigin.y - rail.height)
    }

    @Test
    func ratiosRoundTripThroughTheRailOrigin() {
        let rail = RailMetrics().size(for: 3, on: .vertical, docked: true)
        // 悬浮时条被要求离屏幕边至少 dockDistance，所以贴边的比例会被钳掉一点；
        // 往返只在这条带子之内是恒等的。
        for h in [0.1, 0.5, 0.9] {
            for v in [0.0, 0.5, 1.0] {
                let layout = RailGeometry.layout(
                    dock: .floating,
                    horizontalRatio: h,
                    verticalRatio: v,
                    notch: nil,
                    visible: Self.visibleFrame,
                    topEdge: Self.screenFrame.maxY,
                    panel: Self.panelSize(.right),
                    rail: rail
                )
                let back = RailGeometry.ratios(
                    forRailAt: Self.bottomLeft(of: layout, rail: rail),
                    in: Self.visibleFrame,
                    rail: rail
                )
                #expect(abs(back.h - h) < 0.001, "横向比例 \(h) 往返后是 \(back.h)")
                #expect(abs(back.v - v) < 0.001, "纵向比例 \(v) 往返后是 \(back.v)")
            }
        }
    }

    @Test
    func aRatioAtTheVeryEdgeIsPushedBackByTheDockDistanceWhenFloating() {
        let rail = RailMetrics().size(for: 3, on: .vertical, docked: true)
        let layout = RailGeometry.layout(
            dock: .floating,
            horizontalRatio: 1,
            verticalRatio: 0.5,
            notch: nil,
            visible: Self.visibleFrame,
            topEdge: Self.screenFrame.maxY,
            panel: Self.panelSize(.right),
            rail: rail
        )
        // 存储的比例仍是 1（贴边时留下的），但悬浮必须离边一个 dockDistance。
        let back = RailGeometry.ratios(
            forRailAt: Self.bottomLeft(of: layout, rail: rail),
            in: Self.visibleFrame,
            rail: rail
        )
        #expect(back.h < 1)
        #expect(layout.railOrigin.x == Self.visibleFrame.maxX - rail.width - RailGeometry.dockDistance)
    }

    // MARK: - 显示器身份

    @Test
    func aStoredDisplayThatIsGoneFallsBackRatherThanFailing() {
        // nil 与「没接」都是正常答案：人是要拔显示器的。
        #expect(RailScreen.screen(withIdentifier: nil) == nil)
        #expect(RailScreen.screen(withIdentifier: "00000000-0000-0000-0000-000000000000") == nil)
    }

    @Test
    func everyAttachedDisplayHasAStableIdentifier() throws {
        for screen in NSScreen.screens {
            #expect(RailScreen.identifier(of: screen) != nil)
        }
        // 同一块屏连问两次必须给同一个名字，否则记忆显示器这件事本身就不成立。
        let main = try #require(NSScreen.screens.first)
        #expect(RailScreen.identifier(of: main) == RailScreen.identifier(of: main))
    }

    @Test
    func notchIsAbsentWhenTheInsetIsZero() {
        #expect(
            RailScreen.notch(in: Self.screenFrame, topInset: 0, left: nil, right: nil) == nil
        )
    }

    @Test
    func notchIsTheGapBetweenTheTwoAuxiliaryAreas() {
        let left = CGRect(x: 0, y: 862, width: 640, height: 38)
        let right = CGRect(x: 800, y: 862, width: 640, height: 38)
        let notch = RailScreen.notch(in: Self.screenFrame, topInset: 38, left: left, right: right)
        #expect(notch == CGRect(x: 640, y: 862, width: 160, height: 38))
    }

    // MARK: - 记忆

    @Test
    func placementSurvivesARestart() throws {
        let suite = try #require(UserDefaults(suiteName: "rail-placement-tests"))
        defer { suite.removePersistentDomain(forName: "rail-placement-tests") }

        let placement = RailPlacement(dock: .edge(.right), defaults: suite)
        placement.record(
            dock: .floating,
            horizontalRatio: 0.3,
            verticalRatio: 0.75,
            display: "display-uuid"
        )

        let restored = RailPlacement.restored(defaults: suite)
        #expect(restored.dock == .floating)
        #expect(abs(restored.horizontalRatio - 0.3) < 0.0001)
        #expect(abs(restored.verticalRatio - 0.75) < 0.0001)
        #expect(restored.display == "display-uuid")
    }

    @Test
    func aDockedEdgeSurvivesARestart() throws {
        let suite = try #require(UserDefaults(suiteName: "rail-placement-edge-tests"))
        defer { suite.removePersistentDomain(forName: "rail-placement-edge-tests") }

        let placement = RailPlacement(defaults: suite)
        placement.record(dock: .edge(.left), horizontalRatio: 0, verticalRatio: 0.5, display: nil)

        let restored = RailPlacement.restored(defaults: suite)
        #expect(restored.dock == .edge(.left))
        #expect(restored.edge == .left)
        #expect(restored.isDocked)
    }

    @Test
    func ratiosAreClampedToTheUnitRange() {
        let placement = RailPlacement(horizontalRatio: 5, verticalRatio: -3)
        #expect(placement.horizontalRatio == 1)
        #expect(placement.verticalRatio == 0)
    }

    @Test
    func aFloatingRailPicksItsSideFromTheHalfItStandsIn() {
        // 只有悬浮时才由比例决定朝向：贴边时朝向就是融进的那条边。
        #expect(RailPlacement(dock: .floating, horizontalRatio: 0.2).edge == .left)
        #expect(RailPlacement(dock: .floating, horizontalRatio: 0.8).edge == .right)
        #expect(RailPlacement(dock: .edge(.right), horizontalRatio: 0.2).edge == .right)
    }

    @Test
    func movingToAnotherDisplayIsRefusedWhileTheRailIsHeld() throws {
        // 必须注入独立的 defaults 域：用 `.standard` 会往用户真实的偏好里写。
        let suite = try #require(UserDefaults(suiteName: "rail-display-follow-tests"))
        defer { suite.removePersistentDomain(forName: "rail-display-follow-tests") }

        let placement = RailPlacement(dock: .edge(.right), defaults: suite)
        placement.isPressed = true
        #expect(placement.move(toDisplay: "some-display") == false)

        placement.isPressed = false
        #expect(placement.move(toDisplay: "some-display") == true)
        #expect(placement.display == "some-display")
    }

    // MARK: - 尺寸

    @Test
    func theRailGrowsWithTheEntryCountAndKeepsItsThickness() {
        let metrics = RailMetrics()
        let one = metrics.size(for: 1, on: .vertical, docked: true)
        let three = metrics.size(for: 3, on: .vertical, docked: true)

        #expect(one.width == three.width)
        #expect(three.height > one.height)
        #expect(three.height - one.height == 2 * metrics.ringStep(on: .vertical))
    }

    @Test
    func aFloatingRailIsShorterThanADockedOneByItsFlares() {
        let docked = RailMetrics().length(for: 3, on: .vertical, docked: true)
        let floating = RailMetrics().length(for: 3, on: .vertical, docked: false)
        // 外扩在两端各啃掉一个 flareHeight，悬浮时整段留白都看得见。
        #expect(docked - floating == RailMetrics().flareHeight * 2)
    }

    @Test
    func theWindowIsAlwaysWideEnoughForTheCard() {
        let rail = RailMetrics().size(for: 3, on: .vertical, docked: true)
        let panel = RailPanelLayout.size(for: .right, railLength: rail.height, metrics: RailMetrics())
        // 窗口比条宽得多：多出来的部分是卡片展开的空间，它是透明的。
        #expect(panel.width == RailLayout.width + RailPanelLayout.cardReach)
        #expect(panel.height >= RailCardLayout.maximumHeight)
    }

    @Test
    func theRailRunsTheOtherWayWhenItIsDockedToTheTop() {
        let vertical = RailMetrics().size(for: 3, on: .vertical, docked: true)
        let horizontal = RailMetrics().size(for: 3, on: .horizontal, docked: true)

        // 横跨方向的尺寸不变，只是换了轴。
        #expect(vertical.width == horizontal.height)
        #expect(vertical.width == RailLayout.width)

        // 沿条方向的长度不同，而且是有原因的：贴顶的条不画百分比文字，
        // 所以它的一项只有环那么长——菜单栏底下多一行字会把胶囊变成横幅。
        #expect(RailMetrics().showsPercentages(on: .vertical))
        #expect(!RailMetrics().showsPercentages(on: .horizontal))
        #expect(horizontal.width < vertical.height)
    }

    // MARK: - 环的命中判定

    /// 悬停选环走的就是这套几何，所以它必须能被钉住，而不是只能靠真实鼠标观察。
    @Test
    func theRingUnderThePointerIsFoundOnEveryEdge() {
        for edge in RailEdge.allCases {
            for entries in [1, 3, 8] {
                let placed = Self.placedRail(edge: edge, entries: entries, docked: true)
                for index in 0..<entries {
                    let point = Self.pointOnRing(index, edge: edge, placed: placed)
                    let hit = RailHitArea.slot(
                        at: point,
                        edge: edge,
                        entryCount: entries,
                        railSize: placed.railSize,
                        panelSize: placed.panelSize,
                        railTop: placed.railTop,
                        railLeading: placed.railLeading,
                        docked: true
                    ,
                    metrics: RailMetrics())
                    #expect(hit == index, "\(edge) 上第 \(index) 个环心没被认出来")
                }
            }
        }
    }

    @Test
    func theGapBetweenTwoRingsBelongsToNeither() {
        let placed = Self.placedRail(edge: .right, entries: 4, docked: true)
        let axis = RailEdge.Axis.vertical
        let first = RailGeometry.ringCentre(forIndex: 0, on: axis, docked: true,
                                                                               metrics: RailMetrics())
        let second = RailGeometry.ringCentre(forIndex: 1, on: axis, docked: true,
                                                                                metrics: RailMetrics())
        let between = (first + second) / 2

        let point = CGPoint(
            x: placed.railLeading + RailMetrics().ringCentreAcross(on: axis),
            y: placed.railTop + between
        )
        #expect(
            RailHitArea.slot(
                at: point,
                edge: .right,
                entryCount: 4,
                railSize: placed.railSize,
                panelSize: placed.panelSize,
                railTop: placed.railTop,
                railLeading: placed.railLeading,
                docked: true
            ,
            metrics: RailMetrics()) == nil
        )
    }

    @Test
    func aPointOffTheRailHitsNothing() {
        let placed = Self.placedRail(edge: .right, entries: 3, docked: true)
        // 卡片那一侧的空处：窗口大部分是透明的，那里不该选中任何环。
        let point = CGPoint(x: 4, y: placed.railTop + 100)
        #expect(
            RailHitArea.slot(
                at: point,
                edge: .right,
                entryCount: 3,
                railSize: placed.railSize,
                panelSize: placed.panelSize,
                railTop: placed.railTop,
                railLeading: placed.railLeading,
                docked: true
            ,
            metrics: RailMetrics()) == nil
        )
    }

    @Test
    func theRingHitAreaIsTheRingAndNotTheWholeItem() {
        // 环的命中半径只比环大一点：够得到环本身与它的一点宽容，
        // 但不至于够到它下面的百分比文字——那样点击会落在数字上而不是环上。
        let placed = Self.placedRail(edge: .right, entries: 3, docked: true)
        let axis = RailEdge.Axis.vertical
        let centre = RailGeometry.ringCentre(forIndex: 0, on: axis, docked: true,
                                                                                metrics: RailMetrics())

        // 标签的中心在环心下方 `ringDiameter/2 + ringToTextSpacing + textHeight/2`。
        let labelCentre = centre + RailLayout.ringDiameter / 2
            + RailLayout.ringToTextSpacing + RailLayout.percentTextHeight / 2
        let point = CGPoint(
            x: placed.railLeading + RailMetrics().ringCentreAcross(on: axis),
            y: placed.railTop + labelCentre
        )
        #expect(
            RailHitArea.slot(
                at: point,
                edge: .right,
                entryCount: 3,
                railSize: placed.railSize,
                panelSize: placed.panelSize,
                railTop: placed.railTop,
                railLeading: placed.railLeading,
                docked: true
            ,
            metrics: RailMetrics()) == nil
        )
    }

    // MARK: - 卡片摆放

    @Test
    func theCardIsAlwaysPlacedInsideTheWindow() {
        let edge = RailEdge.right
        let placed = Self.placedRail(edge: edge, entries: 8, docked: true)
        let railAlong = placed.railTop
        let panelAlong = placed.panelSize.height

        for index in 0..<8 {
            for cardHeight in [RailCardLayout.estimatedHeight, RailCardLayout.maximumHeight] {
                let padding = RailGeometry.cardPadding(
                    ringCentre: RailGeometry.ringCentre(forIndex: index, on: edge.axis, docked: true,
                                                                                                    metrics: RailMetrics()),
                    cardAlong: cardHeight,
                    railAlong: railAlong,
                    panelAlong: panelAlong
                )
                // 卡片在窗口之内：上不越过窗口上沿，下不越过窗口下沿。
                #expect(railAlong + padding >= -0.001, "第 \(index) 个环的卡片顶到了窗口上沿之外")
                #expect(
                    railAlong + padding + cardHeight <= panelAlong + 0.001,
                    "第 \(index) 个环的卡片顶到了窗口下沿之外"
                )
            }
        }
    }

    @Test
    func thePointerAimsAtItsOwnRingWhenTheCardIsNotClamped() {
        let edge = RailEdge.right
        let placed = Self.placedRail(edge: edge, entries: 8, docked: true)
        let cardHeight = RailCardLayout.estimatedHeight

        // 中间的环不会被钳制，所以指针应当正好指着环心。
        let index = 4
        let centre = RailGeometry.ringCentre(forIndex: index, on: edge.axis, docked: true,
                                                                                         metrics: RailMetrics())
        let padding = RailGeometry.cardPadding(
            ringCentre: centre,
            cardAlong: cardHeight,
            railAlong: placed.railTop,
            panelAlong: placed.panelSize.height
        )
        let pointer = RailGeometry.pointerCentre(
            ringCentre: centre,
            cardPadding: padding,
            cardAlong: cardHeight
        )
        #expect(abs(padding + pointer - centre) < 0.001)
    }

    @Test
    func thePointerStaysClearOfTheCardsCornersWhenClamped() {
        let edge = RailEdge.right
        let placed = Self.placedRail(edge: edge, entries: 8, docked: true)
        let cardHeight = RailCardLayout.estimatedHeight

        // 第一个环的卡片会被钳到窗口上沿，此时指针不能跟着跑到圆角上。
        let centre = RailGeometry.ringCentre(forIndex: 0, on: edge.axis, docked: true,
                                                                                     metrics: RailMetrics())
        let padding = RailGeometry.cardPadding(
            ringCentre: centre,
            cardAlong: cardHeight,
            railAlong: placed.railTop,
            panelAlong: placed.panelSize.height
        )
        let pointer = RailGeometry.pointerCentre(
            ringCentre: centre,
            cardPadding: padding,
            cardAlong: cardHeight
        )
        let inset = RailCardLayout.cornerRadius + RailCardLayout.pointerHeight / 2
        #expect(pointer >= inset - 0.001)
        #expect(pointer <= cardHeight - inset + 0.001)
    }

    @Test
    func theCardSitsClearOfTheRailByItsOwnWidthAndGap() {
        let rail = RailMetrics().size(for: 3, on: .vertical, docked: true)
        for edge in [RailEdge.right, .left] {
            let offset = RailGeometry.cardOffset(edge: edge, railSize: rail, notchSize: nil)
            // 卡片要退开「自己的宽 + 指针 + 间隙」，否则会压在条上。
            #expect(abs(offset.width) == RailPanelLayout.cardReach)
            #expect(offset.height == 0)
            // 方向朝着背离条背的那一侧。
            #expect(offset.width == RailPanelLayout.cardReach * edge.cardDirection)
        }
    }

    @Test
    func aTopDockedCardHangsBelowTheNotch() {
        let rail = RailMetrics().size(for: 3, on: .horizontal, docked: true)
        let notch = CGSize(width: 160, height: 38)
        let offset = RailGeometry.cardOffset(edge: .top, railSize: rail, notchSize: notch)

        // 指针已经算在卡片自己的 frame 里，所以这里只退开「条的厚度 + 间隙」。
        #expect(offset.width == 0)
        #expect(offset.height == rail.height + RailCardLayout.horizontalGap)

        // 刘海不改变卡片挂在哪儿：它让条的**表面**从条上方开始（`notchSurface` 的 y 是负的），
        // 条的底沿仍然是卡片要退开的那条线。所以有没有刘海，这个偏移量一样。
        let withoutNotch = RailGeometry.cardOffset(edge: .top, railSize: rail, notchSize: nil)
        #expect(offset.height == withoutNotch.height)
    }

    // MARK: - 测试夹具

    private struct PlacedRail {
        let railSize: CGSize
        let panelSize: CGSize
        let railTop: CGFloat
        let railLeading: CGFloat
    }

    /// 走与控制器完全相同的那条路径摆一次条：先算 frame，再按**实际拿到的** frame
    /// 求条在窗口里的偏移量。命中判定与绘制都吃这两个偏移量。
    private static func placedRail(edge: RailEdge, entries: Int, docked: Bool) -> PlacedRail {
        let rail = RailMetrics().size(for: entries, on: edge.axis, docked: docked)
        let panel = RailHitArea.panelSize(
            for: edge,
            railLength: max(rail.width, rail.height),
            metrics: RailMetrics()
        )
        let layout = RailGeometry.layout(
            dock: .edge(edge),
            horizontalRatio: 1,
            verticalRatio: 0.5,
            notch: nil,
            visible: visibleFrame,
            topEdge: screenFrame.maxY,
            panel: panel,
            rail: rail
        )
        let offsets = RailGeometry.offsets(forRailTopLeft: layout.railOrigin, in: layout.frame, rail: rail)
        return PlacedRail(
            railSize: rail,
            panelSize: panel,
            railTop: offsets.top,
            railLeading: offsets.leading
        )
    }

    private static func pointOnRing(_ index: Int, edge: RailEdge, placed: PlacedRail) -> CGPoint {
        let along = RailGeometry.ringCentre(forIndex: index, on: edge.axis, docked: true,
                                                                                        metrics: RailMetrics())
        let across = RailMetrics().ringCentreAcross(on: edge.axis)
        return edge.isVertical
            ? CGPoint(x: placed.railLeading + across, y: placed.railTop + along)
            : CGPoint(x: placed.railLeading + along, y: placed.railTop + across)
    }
}
