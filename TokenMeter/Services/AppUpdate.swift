import Foundation
import Sparkle

/// 应用内更新，走 Sparkle。
///
/// **EdDSA 密钥是这里能在没有 Apple Developer ID 的前提下安全更新的原因。**
/// Sparkle 拒绝任何不是 `Info.plist` 里那把公钥签过的包，不管它是谁提供的；
/// app 自己只带 ad-hoc 签名，但更新路径仍然可验证。
///
/// **测试宿主与没有 bundle id 的进程里一律不启动。** 前者是 Swift Testing
/// 加载的 App target，那里的约定是生产用的东西一律不碰（见 `TokenMeterAppDelegate`）；
/// 后者意味着这不是一个 app bundle，Sparkle 会一直抱怨 Info.plist 里没有 feed 地址。
/// 引用计数方式：app 委托持有本对象，本对象持有 controller——放手就没人再排期检查了。
///
/// 检查的排期与窗口都归 Sparkle 自己：这里只把「能不能查」和「现在查一次」交给界面。
@MainActor
final class AppUpdate {
    private let controller: SPUStandardUpdaterController?

    /// 这个进程能不能做更新检查。为 false 时界面上该把「检查更新」关掉。
    var canCheck: Bool { controller != nil }

    init() {
        guard !TokenMeterAppDelegate.isRunningTests, Bundle.main.bundleIdentifier != nil else {
            controller = nil
            return
        }

        // `startingUpdater: true`：自动检查按 Info.plist 里的
        // `SUScheduledCheckInterval` 从这里开始排期，别处不需要再叫它。
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// 立刻检查一次。找到新版本时弹的是 Sparkle 自己的窗口，这里没有别的界面。
    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }
}
