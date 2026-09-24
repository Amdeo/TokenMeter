import AppKit
import CoreGraphics

/// 条在哪块显示器上，以及怎么给一块显示器起个能再找到的名字。
///
/// 移植自 Pulse 的 `PanelScreen`。
///
/// **`CGDirectDisplayID` 不是身份。** 它是屏幕接入时新发的，所以换一次会话、
/// 拔插一次显示器、接一次扩展坞就会变。UUID 不会——那是同一块物理屏的同一个值——
/// 所以存的是 UUID。
enum RailScreen {
    /// 摄像头外壳在 AppKit 全局屏幕坐标里的矩形。
    /// 单看安全内边距只是一个高度，不是外壳宽度的证据。
    static func notch(of screen: NSScreen) -> CGRect? {
        notch(
            in: screen.frame,
            topInset: screen.safeAreaInsets.top,
            left: screen.auxiliaryTopLeftArea,
            right: screen.auxiliaryTopRightArea
        )
    }

    static func notch(in frame: CGRect, topInset: CGFloat, left: CGRect?, right: CGRect?) -> CGRect? {
        guard topInset > 0, let left, let right,
              left.width > 0, right.width > 0, right.minX > left.maxX
        else { return nil }
        return CGRect(
            x: left.maxX,
            y: frame.maxY - topInset,
            width: right.minX - left.maxX,
            height: topInset
        )
    }

    /// 重启与重新接入之后仍然有效的显示器名字。
    static func identifier(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))
        else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }

    /// 这个名字指向的显示器，当前没接就返回 nil。
    ///
    /// nil 是正常答案而不是错误：人是要拔显示器的。调用方回落到一块真实存在的屏，
    /// 而不是把条停在一个谁也看不见的地方。
    static func screen(withIdentifier identifier: String?) -> NSScreen? {
        guard let identifier else { return nil }
        return NSScreen.screens.first { self.identifier(of: $0) == identifier }
    }

    /// 某个点在哪块屏上。
    ///
    /// 用 `frame` 而不是 `visibleFrame`：判断「指针在哪块屏」时菜单栏和 Dock 也是屏幕的一部分，
    /// 指针跑到菜单栏上不该读成「不在任何屏上」。
    static func containing(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}
