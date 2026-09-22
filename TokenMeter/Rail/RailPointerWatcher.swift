import AppKit
import SwiftUI

/// 上报指针在条窗口里的位置，靠**采样**它的位置而不是监听进入/离开事件。
///
/// 移植自 Pulse 的 `PanelPointerWatcher`。
///
/// 位置用被跟踪视图自己的坐标给出，原点是它的左上角以对齐 SwiftUI；
/// 指针完全不在窗口里时是 `nil`。什么叫「还在条上」由调用方决定——
/// 窗口的 frame 回答不了这个问题，因为这个窗口大部分是内容并不占据的透明空间。
///
/// 进入/离开事件在这里被证明不可用：视图在静止的指针底下出现、消失、做动画都会
/// 发出虚假的离开；响应其中一个就会收起卡片，而收起卡片又把指针放回某个环上，
/// 于是又打开它——一个无休止的开/关循环。采样指针的真实位置不会被动画、
/// 不会被从底下滑过的视图、也不会被一个永远不来的事件弄乱。
///
/// 挂在一个铺满窗口的视图的 background 上。
struct RailPointerWatcher: NSViewRepresentable {
    let onChange: (CGPoint?) -> Void

    func makeNSView(context: Context) -> WatcherView {
        let view = WatcherView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: WatcherView, context: Context) {
        view.onChange = onChange
    }

    static func dismantleNSView(_ view: WatcherView, coordinator: ()) {
        view.stop()
    }

    @MainActor
    final class WatcherView: NSView {
        var onChange: ((CGPoint?) -> Void)?

        /// 与 SwiftUI 的左上角原点一致，所以报出去的点可以直接和 SwiftUI 的 frame 比较，
        /// 不必先翻转。
        override var isFlipped: Bool { true }

        /// 指针离开时立刻有感，同时又不花钱。
        private static let interval: TimeInterval = 0.15

        private var timer: Timer?
        private var lastReported: CGPoint??

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window == nil ? stop() : start()
        }

        func stop() {
            timer?.invalidate()
            timer = nil
            lastReported = nil
        }

        private func start() {
            guard timer == nil else { return }

            let timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            // 菜单或别的模态循环起来时继续采样。
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func sample() {
            guard let window else { return }

            let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let local = convert(inWindow, from: nil)
            let point = bounds.contains(local) ? local : nil

            // 只在真的变了的时候说话，免得一个静止的指针每秒六次搅动 SwiftUI 状态。
            if let lastReported, Self.isSame(lastReported, point) { return }

            lastReported = point
            onChange?(point)
        }

        private static func isSame(_ a: CGPoint?, _ b: CGPoint?) -> Bool {
            switch (a, b) {
            case (nil, nil): true
            case let (a?, b?): abs(a.x - b.x) < 1 && abs(a.y - b.y) < 1
            default: false
            }
        }
    }
}
