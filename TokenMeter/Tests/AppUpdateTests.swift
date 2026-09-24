import Testing
@testable import TokenMeter

/// 测试宿主里的更新检查：一律不启动。
///
/// 这个宿主是 App target 本体，Sparkle 在这里会去读 feed、排期检查，
/// 严重的时候还会在真机上弹窗——`TokenMeterAppDelegate` 给生产用的东西装的那道闸
/// 对更新检查同样要成立。
@MainActor
struct AppUpdateTests {
    @Test
    func updateStaysOffInTheTestHost() {
        #expect(TokenMeterAppDelegate.isRunningTests)
        #expect(!AppUpdate().canCheck)
    }
}
