import SwiftUI

/// 悬浮条右键菜单的动作目标。
///
/// `NSMenuItem` 需要 target/action 对，而这些动作要调用的东西（切设置页、改设置）
/// 属于 app 委托与设置存储，不属于悬浮条自己。用一个薄目标对象把闭包接过去，
/// 悬浮条就只需要知道「菜单上有什么」，不必知道菜单背后是谁。
@MainActor
final class RailMenuActions: NSObject {
    var onOpenSettings: (() -> Void)?
    var onMove: ((RailDock) -> Void)?
    /// 勾上「常显示」：对应设置里关掉「离开时自动收起」。
    var onToggleAlwaysVisible: (() -> Void)?
    var onQuit: (() -> Void)?

    @objc func openSettings() { onOpenSettings?() }
    @objc func quit() { onQuit?() }
    @objc func toggleAlwaysVisible() { onToggleAlwaysVisible?() }

    @objc func dockLeft() { onMove?(.edge(.left)) }
    @objc func dockRight() { onMove?(.edge(.right)) }
    @objc func dockTop() { onMove?(.edge(.top)) }
    @objc func float() { onMove?(.floating) }
}
