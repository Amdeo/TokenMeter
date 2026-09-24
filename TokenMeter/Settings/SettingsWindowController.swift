import AppKit
import SwiftUI

/// 设置窗口。
///
/// 移植自 Pulse 的 `SettingsWindowController`。
///
/// **必须是普通 `NSWindowController`，不是 SwiftUI 的 `Settings` 场景。**
/// TokenMeter 的 `Info.plist` 里 `LSUIElement = true`——它是 accessory app，
/// 没有 Dock 图标、通常也不是最活跃的那个，所以窗口必须**显式激活** app，
/// 否则它会开在用户正在看的东西后面。这也正是这里不用 SwiftUI 场景的原因：
/// 窗口的激活与生命周期都要直接管。
@MainActor
final class SettingsWindowController {
    private let store: UsageStore
    private let settings: SettingsStore
    private let railPlacement: RailPlacement
    private let update: AppUpdate
    private let navigation = SettingsNavigation()
    private var window: NSWindow?
    private var hasBeenPlaced = false

    init(store: UsageStore, settings: SettingsStore, railPlacement: RailPlacement, update: AppUpdate) {
        self.store = store
        self.settings = settings
        self.railPlacement = railPlacement
        self.update = update
        observeAppearance()
    }

    func show(pane: SettingsPane = .general) {
        navigation.isWindowVisible = true
        navigation.open(pane, subscriptions: store.subscriptions)

        let window = window ?? makeWindow()
        self.window = window
        applyAppearance(to: window)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // 只在第一次摆放。Pulse 每次 `show()` 都 `center()`，那会把用户拖到别处的窗口
        // 拉回屏幕中间——开一次设置就要重新摆一次位置，是没人要的。
        if !hasBeenPlaced {
            hasBeenPlaced = true
            window.center()
        }
    }

    /// 订阅增删之后侧边栏要跟着变；选中的那条没了就退回通用页——
    /// 由视图观察 `store.subscriptions` 触发（窗口的视图本来就在读它）。
    /// 窗口外观跟着 app 的「主题」设置走。
    ///
    /// 不这么做的话，一个把 app 设成浅色的人打开设置会看到一个深色窗口——
    /// 而那条设置说的是「这个 app 长什么样」，设置窗口也是这个 app 的一部分。
    private func applyAppearance(to window: NSWindow) {
        let target: NSAppearance? = switch settings.appearanceMode {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        // 幂等：只在目标外观变化时更新，避免外观切换递归触发布局。
        if window.appearance != target { window.appearance = target }
    }

    /// 主题在窗口开着的时候被改掉，窗口要立刻跟上。
    ///
    /// `withObservationTracking` 的 onChange 只报一次，所以每次回调都要重新注册。
    private func observeAppearance() {
        withObservationTracking {
            _ = settings.appearanceMode
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let window = self.window { self.applyAppearance(to: window) }
                self.observeAppearance()
            }
        }
    }

    private func makeWindow() -> NSWindow {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // 这两条要一起用，配对才是重点。
        //
        // `.fullSizeContentView` 让滚动内容跑到标题栏下面，于是它是被**糊掉**的，
        // 而不是被一条硬边切掉。静止时什么都不会被遮住：AppKit 会把标题栏报成
        // 52pt 的上安全区，滚动视图自己已经按它内缩了。
        //
        // 但这只有在上面**真的画了东西**时才成立。透明的标题栏什么都不画，
        // 滚上来的内容就直接印在窗口标题上——这一对正是为了修那个。
        // 不透明意味着由 AppKit 自己的材质去做模糊。
        window.titlebarAppearsTransparent = false
        // 文档里那个「内容滚到下面之后出现细线」的开关。
        window.titlebarSeparatorStyle = .automatic
        window.isReleasedWhenClosed = false
        window.title = "TokenMeter 设置"
        window.onClose = { [weak navigation] in navigation?.isWindowVisible = false }

        window.contentView = NSHostingView(
            rootView: SettingsWindowView(
                store: store,
                settings: settings,
                railPlacement: railPlacement,
                update: update,
                navigation: navigation
            )
            // 订阅子页复用的 `SubscriptionEditorContent` / `SubscriptionAppearanceContent`
            // 是通过环境拿 `UsageStore` 的（面板那边也是这么给它的），窗口这一侧必须同样注入，
            // 否则渲染订阅页时会因为取不到而中止。
            .environment(store)
        )
        return window
    }
}

/// 点空白处必须结束正在编辑的文本框，而 macOS 自己不会做这件事：一个文本框会一直占着
/// first responder，直到别的视图来要；而这个窗口里没有别的视图会要。于是光标框会留在原地，
/// 只有换页（把文本框拆掉）才会松开它。
///
/// 放在窗口这一层是因为它比任何东西都先看到那次按下，和悬浮条在 `sendEvent` 里接拖动是同一个理由。
/// 判据是**几何**而不是 hit test：hit test 是在问一棵被宿主托管的 SwiftUI 树一个它答不准的问题，
/// 而这里只需要知道「那一下是不是落在框里」。
final class SettingsWindow: NSWindow {
    var onClose: (() -> Void)?

    override func close() {
        onClose?()
        super.close()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let field = fieldBeingEdited() {
            let box = field.convert(field.bounds, to: nil)
            if !box.contains(event.locationInWindow) { makeFirstResponder(nil) }
        }
        super.sendEvent(event)
    }

    /// 窗口的 field editor 当前在为哪个文本框工作；没有在编辑时为 nil。
    private func fieldBeingEdited() -> NSView? {
        guard let editor = firstResponder as? NSText, editor.isFieldEditor else { return nil }

        // field editor 是共享的，被装进当前活跃的那个文本框里，而它把这个文本框当作 delegate 留着。
        if let field = (editor as? NSTextView)?.delegate as? NSView { return field }
        return editor.superview?.superview
    }
}
