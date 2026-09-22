import SwiftUI

/// 悬浮条右键菜单的动作目标。
///
/// `NSMenuItem` 需要 target/action 对，而这些动作要调用的东西（打开面板、切设置页）
/// 属于 app 委托与面板控制器，不属于悬浮条自己。用一个薄目标对象把闭包接过去，
/// 悬浮条就只需要知道「菜单上有什么」，不必知道菜单背后是谁。
@MainActor
final class RailMenuActions: NSObject {
    var onOpenPanel: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onMove: ((RailDock) -> Void)?
    var onQuit: (() -> Void)?

    @objc func openPanel() { onOpenPanel?() }
    @objc func openSettings() { onOpenSettings?() }
    @objc func quit() { onQuit?() }

    @objc func dockLeft() { onMove?(.edge(.left)) }
    @objc func dockRight() { onMove?(.edge(.right)) }
    @objc func dockTop() { onMove?(.edge(.top)) }
    @objc func float() { onMove?(.floating) }
}
