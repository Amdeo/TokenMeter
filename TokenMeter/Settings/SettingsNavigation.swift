import Foundation
import Observation
import SwiftUI

/// 设置窗口侧边栏的一页。
enum SettingsPane: Hashable {
    case general
    case rail
    case notifications
    case data
    case about
    /// 新增订阅：先选供应商，再配置。
    ///
    /// 不是一条订阅——它还没有 id——所以不能复用 `.subscription`。
    case addSubscription
    /// 一条**已添加的**订阅。
    ///
    /// 按订阅 id 而不是按供应商：同一个供应商可以有两条订阅（两个 Kimi 账号），
    /// 它们在侧边栏里是两行。这与 Pulse 不同——Pulse 的
    /// `allAccounts = Provider.allCases.flatMap { ... }` 把枚举里每个供应商都列出来，
    /// 跟有没有登录无关；TokenMeter 只列用户真的添加了的。
    case subscription(UUID)
}

extension SettingsPane {
    /// 应用级页面的名字。订阅页的名字来自订阅本身，由视图解析。
    var title: String {
        switch self {
        case .general: "通用"
        case .rail: "悬浮条"
        case .notifications: "通知"
        case .data: "数据迁移"
        case .about: "关于"
        case .addSubscription: "添加订阅"
        case .subscription: "订阅"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .rail: "rectangle.righthalf.inset.filled"
        case .notifications: "bell"
        case .data: "arrow.left.arrow.right"
        case .about: "info.circle"
        case .addSubscription: "plus"
        case .subscription: "person.crop.square"
        }
    }

    var subscriptionID: UUID? {
        if case .subscription(let id) = self { return id }
        return nil
    }
}

/// 设置窗口的导航状态。
///
/// 移植自 Pulse 的 `SettingsNavigation`，多了一件东西：**订阅子页的草稿**。
/// 它放在这里而不是视图的 `@State` 里，因为窗口的视图会被重建，而草稿要活得更久。
@MainActor
@Observable
final class SettingsNavigation {
    private(set) var pane: SettingsPane = .general
    var isWindowVisible = false

    /// 每次从外部请求跳页都换一个新值，视图据此滚回顶部（Pulse 用同一招）。
    private(set) var requestID = UUID()

    /// 订阅子页的草稿。
    private(set) var subscriptionDraft: SubscriptionEditorDraft?

    /// 新增流程的草稿：选完供应商之后为它建一条**还没有保存**的订阅。
    private(set) var newSubscriptionDraft: SubscriptionEditorDraft?

    /// 订阅子页里正停在外观子页上。外观是订阅的子页，不占侧边栏一行。
    var showsAppearance = false

    /// 数据迁移页里正停在迁移子页上。与外观同理：迁移是数据迁移的子页，不占侧边栏一行。
    var showsMigration = false

    /// 选中一页。
    ///
    /// 订阅页要顺带准备草稿；选中的订阅已经不存在（在别处被删掉）时退回通用页，
    /// 而不是留一个空子页。
    func select(_ pane: SettingsPane, subscriptions: [Subscription]) {
        guard pane != self.pane else { return }

        // 离开新增流程就丢掉它的草稿：那是一条还没保存的订阅，留着没有意义。
        if self.pane == .addSubscription { discardNewDraft() }

        showsAppearance = false
        showsMigration = false
        requestID = UUID()

        switch pane {
        case .addSubscription:
            self.pane = pane
        case .subscription(let id):
            guard let subscription = subscriptions.first(where: { $0.id == id }) else {
                self.pane = .general
                return
            }
            self.pane = pane
            edit(subscription)
        default:
            self.pane = pane
        }
    }

    /// 从数据迁移页进入迁移子页。
    func openMigration() {
        guard pane == .data else { return }
        showsMigration = true
    }

    /// 从迁移子页返回数据迁移页。
    func closeMigration() {
        showsMigration = false
    }

    /// 新增流程里选定了供应商：为它建一条新订阅的草稿。
    func chooseProvider(_ providerID: ProviderID) {
        newSubscriptionDraft?.cancelTasks()
        newSubscriptionDraft = SubscriptionEditorDraft(providerID: providerID)
        showsAppearance = false
        showsMigration = false
    }

    /// 新订阅保存成功：把选中切到刚建出来的那条上。
    ///
    /// 停在「添加订阅」页会让人以为没生效——侧边栏多了一行、右边也应当跟着过去。
    func didCreate(_ id: UUID, subscriptions: [Subscription]) {
        discardNewDraft()
        select(.subscription(id), subscriptions: subscriptions)
    }

    private func discardNewDraft() {
        newSubscriptionDraft?.cancelTasks()
        newSubscriptionDraft = nil
    }

    /// 为一条订阅准备草稿。
    ///
    /// **同一条订阅不重建草稿**：未保存的改动要留住，这样在侧边栏来回切换不会丢东西。
    /// 面板那边也是这个约定——`SubscriptionEditorDraft` 在面板收起时保留未保存的配置。
    func edit(_ subscription: Subscription) {
        if subscriptionDraft?.original?.id == subscription.id { return }
        subscriptionDraft?.cancelTasks()
        subscriptionDraft = SubscriptionEditorDraft(subscription: subscription)
        showsAppearance = false
    }

    /// 编辑结束（保存成功 / 删除 / 放弃更改）之后把界面收拾干净。
    ///
    /// 订阅还在就按保存后的样子重建草稿——`isDirty` 随之归零，子页停在原地显示已保存的状态；
    /// 订阅被删掉了就退回通用页。
    func finishEditing(subscriptions: [Subscription]) {
        guard let id = pane.subscriptionID else { return }
        subscriptionDraft?.cancelTasks()
        showsAppearance = false

        guard let subscription = subscriptions.first(where: { $0.id == id }) else {
            subscriptionDraft = nil
            pane = .general
            return
        }
        subscriptionDraft = SubscriptionEditorDraft(subscription: subscription)
    }

    /// 窗口打开时跳到某一页（从别处的入口进来）。
    func open(_ pane: SettingsPane, subscriptions: [Subscription]) {
        select(pane, subscriptions: subscriptions)
    }

    /// 订阅列表变了之后收拾状态：选中的那条被删掉就退回通用页，不留一个空子页。
    ///
    /// 与 `finishEditing` 分开：那个是「这一页的编辑动作结束了」，这个是「列表本身变了」，
    /// 可能发生在别处删掉当前订阅的时候。
    func finishEditingIfMissing(subscriptions: [Subscription]) {
        guard let id = pane.subscriptionID else { return }
        guard !subscriptions.contains(where: { $0.id == id }) else { return }

        subscriptionDraft?.cancelTasks()
        subscriptionDraft = nil
        showsAppearance = false
        pane = .general
    }
}
