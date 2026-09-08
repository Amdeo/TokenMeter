import SwiftUI
import Observation

/// 订阅卡片拖拽排序的自动滚动方向。
enum ReorderAutoScrollDirection: Equatable {
    case none
    case up
    case down
}

/// 订阅卡片拖拽排序的状态机与算法：拖动期间只操作视觉序列，
/// 不直接改动 store 数组，松手时一次性写回（见 `finish`）。
@Observable
@MainActor
final class SubscriptionReorderController {
    static let viewportCoordinateSpace = "subscriptionListViewport"
    static let contentCoordinateSpace = "subscriptionListContent"
    static let spacing: CGFloat = 8
    static let edgeActivation: CGFloat = 48
    static let autoScrollInterval: UInt64 = 80_000_000

    /// 拖动中的视觉序列（含拖行当前槽），仅驱动让位 offset。
    var sequence: [UUID] = []
    var draggingID: UUID?
    var translation: CGFloat = 0
    var originMidY: CGFloat = 0
    var frames: [UUID: CGRect] = [:]
    var baseFrames: [UUID: CGRect] = [:]
    var pointerY: CGFloat = 0
    var contentFrame: CGRect = .zero
    var autoScrollDirection: ReorderAutoScrollDirection = .none
    var autoScrollTick = 0

    var isDragging: Bool { draggingID != nil }

    var activeFrames: [UUID: CGRect] {
        baseFrames.isEmpty ? frames : baseFrames
    }

    func reset() {
        draggingID = nil
        translation = 0
        originMidY = 0
        sequence = []
        baseFrames = [:]
        pointerY = 0
        contentFrame = .zero
        autoScrollDirection = .none
    }

    /// 行在视觉序列 sequence（目标布局，内容坐标）下的顶部 y。
    func visualTop(for id: UUID) -> CGFloat? {
        let frames = activeFrames
        guard let listTop = frames.values.map(\.minY).min() else { return nil }
        var top = listTop
        for seqID in sequence {
            guard let frame = frames[seqID] else { return nil }
            if seqID == id { return top }
            top += frame.height + Self.spacing
        }
        return nil
    }

    /// 排序行的纵向 offset：
    /// - 拖动行：布局槽静止，offset = 跟手位移（视觉中心 = 起始中线 + translation）。
    /// - 让位行：从 store 布局槽让位到视觉序列槽（拖动期间 store 数组不变，布局静止）。
    func offsetY(for id: UUID) -> CGFloat {
        guard isDragging else { return 0 }
        if draggingID == id {
            if let frame = activeFrames[id], !contentFrame.isEmpty {
                return pointerY - (contentFrame.minY + frame.midY)
            }
            return translation
        }
        guard let visualTop = visualTop(for: id), let layoutTop = activeFrames[id]?.minY else { return 0 }
        return visualTop - layoutTop
    }

    /// 排序拖拽手势：跟手更新视觉序列，松手时通过 onCommit 一次性写回 store。
    func dragGesture(
        for id: UUID,
        subscriptions: [Subscription],
        viewportHeight: CGFloat,
        onCommit: @escaping (UUID, Int, Int) -> Void
    ) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.viewportCoordinateSpace))
            .onChanged { value in
                guard self.draggingID == nil || self.draggingID == id else { return }
                if self.draggingID == nil {
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        // 有基准 frame 时按卡片中线换位；测量稍晚时退回 startLocation，
                        // 先保证手势可以开始，后续 frame 到位后再参与换位。
                        self.draggingID = id
                        self.originMidY = self.frames[id]?.midY ?? value.startLocation.y
                        self.sequence = subscriptions.map(\.id)
                        self.baseFrames = self.frames
                    }
                }
                self.pointerY = value.location.y
                self.translation = value.translation.height
                let centerY = self.contentFrame.isEmpty
                    ? self.originMidY + value.translation.height
                    : value.location.y - self.contentFrame.minY
                self.adjustSequence(centerY: centerY)
                self.updateAutoScrollDirection(pointerY: value.location.y, viewportHeight: viewportHeight)
            }
            .onEnded { _ in
                self.finish(subscriptions: subscriptions, onCommit: onCommit)
            }
    }

    func updateAutoScrollDirection(pointerY: CGFloat, viewportHeight: CGFloat) {
        guard contentFrame.isEmpty || contentFrame.height > viewportHeight + 1 else {
            autoScrollDirection = .none
            return
        }
        let top = Self.edgeActivation
        let bottom = viewportHeight - Self.edgeActivation
        let direction: ReorderAutoScrollDirection
        if pointerY < top {
            direction = .up
        } else if pointerY > bottom {
            direction = .down
        } else {
            direction = .none
        }
        if direction != autoScrollDirection {
            autoScrollDirection = direction
        }
    }

    func advanceAutoScroll(using proxy: ScrollViewProxy, viewportHeight: CGFloat, reduceMotion: Bool) {
        guard autoScrollDirection != .none,
              let dragID = draggingID,
              var index = sequence.firstIndex(of: dragID)
        else { return }

        let step: Int = autoScrollDirection == .down ? 1 : -1
        let nextIndex = index + step
        guard sequence.indices.contains(nextIndex) else {
            autoScrollDirection = .none
            return
        }

        let previousSequence = sequence
        let centerY = contentFrame.isEmpty
            ? originMidY + translation
            : pointerY - contentFrame.minY
        adjustSequence(centerY: centerY)
        index = sequence.firstIndex(of: dragID) ?? index

        let targetIndex = index + step
        guard sequence.indices.contains(targetIndex) else {
            autoScrollDirection = .none
            return
        }
        if sequence == previousSequence {
            sequence.swapAt(index, targetIndex)
        }

        let revealIndex = autoScrollDirection == .down
            ? min(targetIndex + 1, sequence.count - 1)
            : max(targetIndex - 1, 0)
        let revealID = sequence[revealIndex]
        let animation: Animation? = reduceMotion ? nil : .easeOut(duration: 0.12)
        withAnimation(animation) {
            proxy.scrollTo(revealID, anchor: autoScrollDirection == .down ? .bottom : .top)
        }
    }

    /// 拖动中视觉让位：只调整 sequence（不动 store），使拖行在序列中的槽位贴近鼠标中心。
    /// 比较对象是各行在目标序列中的中线（静态几何），不受让位动画瞬时位置影响，判定稳定。
    func adjustSequence(centerY: CGFloat) {
        guard let dragID = draggingID else { return }
        var seq = sequence
        guard var currentIndex = seq.firstIndex(of: dragID) else { return }
        let frames = activeFrames
        guard frames.count == seq.count, seq.allSatisfy({ frames[$0] != nil }) else { return }
        func centerYInSequence(_ id: UUID, in sequence: [UUID]) -> CGFloat {
            var top = frames.values.map(\.minY).min() ?? 0
            for sid in sequence {
                guard let frame = frames[sid] else { return top }
                if sid == id { return top + frame.height / 2 }
                top += frame.height + Self.spacing
            }
            return top
        }
        while currentIndex > 0, centerY < centerYInSequence(seq[currentIndex - 1], in: seq) {
            seq.swapAt(currentIndex, currentIndex - 1)
            currentIndex -= 1
        }
        while currentIndex < seq.count - 1, centerY > centerYInSequence(seq[currentIndex + 1], in: seq) {
            seq.swapAt(currentIndex, currentIndex + 1)
            currentIndex += 1
        }
        if seq != sequence { sequence = seq }
    }

    /// 松手落位：通过 onCommit 把视觉序列一次性写回 store（数组 move + 持久化）并复位拖行状态。
    /// 拖动期间让位 offset 恰把各行显示在最终槽位，落位动画只是拖行从跟手处平滑归槽，
    /// 无「系统重排动画 + offset」双通道，不抖。
    func finish(subscriptions: [Subscription], onCommit: (UUID, Int, Int) -> Void) {
        guard let dragID = draggingID else { return }
        let sourceIndex = subscriptions.firstIndex(where: { $0.id == dragID })
        let targetIndex = sequence.firstIndex(of: dragID)
        if let sourceIndex, let targetIndex, sourceIndex != targetIndex {
            onCommit(dragID, sourceIndex, targetIndex)
        }
        draggingID = nil
        translation = 0
        originMidY = 0
        sequence = subscriptions.map(\.id)
        baseFrames = [:]
        pointerY = 0
        contentFrame = .zero
        autoScrollDirection = .none
    }
}
