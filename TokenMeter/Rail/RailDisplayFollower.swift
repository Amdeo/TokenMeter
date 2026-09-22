import AppKit

/// 盯着指针在哪块显示器上，好把条移过去。
///
/// 移植自 Pulse 的 `ActiveDisplayFollower`。
///
/// **「活跃」在这里完全由指针定义。** 不是 key window、不是最前面 app 的 frame：
/// 一个 app 可以在一块屏上聚焦，而人在另一块屏上干活；去读窗口位置不但要辅助功能权限，
/// 还会以更贵的方式错掉。指针在哪，手就在哪。
///
/// 用定时器采样而不是靠事件驱动，理由和 `RailPointerWatcher` 一样：全局鼠标移动监听
/// 在本 app 自己的窗口上就不再触发，而指针跨到另一块屏然后停在那里之后，
/// 不会再发出任何东西让你察觉。位置是可以随时问的，而且永远不过期。
///
/// 自始至终只有一条悬浮条。这里不创建第二条。
@MainActor
final class RailDisplayFollower {
    /// 指针停在了一块与上次上报不同的显示器上，按 `RailScreen` 的命名。
    ///
    /// 返回 `false` 表示此刻做不了这个移动——比如条正在那只手底下——
    /// 那么下一次 tick 会把同一块显示器再报一次，而不是被记成已经处理过。
    var onEnter: ((String) -> Bool)?

    /// 慢到不花钱，快到指针跨过边框、够到任何值得点的东西之前条就已经到位了。
    /// 条不是跟着指针做动画：这是每次跨界触发一次，不是每帧一次。
    private static let interval: TimeInterval = 0.25

    private var timer: Timer?
    private var lastIdentifier: String?

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        // 菜单或别的模态循环起来时继续采样：菜单开着的时候跨到另一块屏也是跨过去。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastIdentifier = nil
    }

    /// 忘掉上次看到的指针位置，这样下一次 tick 即使指针没动也会再报一次。
    ///
    /// 用在显示器本身发生变化时：把条所在的那块屏拔掉之后指针一点没动，
    /// 于是这里会读成「无事可做」，而条停在一块谁也没选的兜底屏上。
    func forgetLastDisplay() {
        lastIdentifier = nil
    }

    private func sample() {
        // 一块屏是没法离开的。比问指针在哪更便宜，而且这是常见情况。
        guard NSScreen.screens.count > 1 else { return }

        guard
            let screen = RailScreen.containing(NSEvent.mouseLocation),
            let identifier = RailScreen.identifier(of: screen),
            identifier != lastIdentifier
        else { return }

        if onEnter?(identifier) == false { return }
        lastIdentifier = identifier
    }
}
