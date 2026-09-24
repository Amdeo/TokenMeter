import AppKit
import SwiftUI

/// 设置窗口：左边一个 source list，右边一次一页，每页是一叠分组卡片。
///
/// 移植自 Pulse 的 `SettingsView`。与它的关键差别在侧边栏的「订阅」分组：
/// Pulse 把枚举里每个供应商都列成一行，TokenMeter **只列用户真的添加了的订阅**，
/// 一条订阅一行、按用户自己的排序。
struct SettingsWindowView: View {
    let store: UsageStore
    @Bindable var settings: SettingsStore
    let railPlacement: RailPlacement
    @Bindable var navigation: SettingsNavigation

    /// 「显示顺序」里被拖放悬停的那一行，用来高亮它。
    @State private var dropTargetID: UUID?

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            paneSurface
        }
        // 不设 `navigationTitle`：每一页自己打印标题，工具栏再重复一遍没有意义。
        .frame(minWidth: 720, minHeight: 460)
        // 订阅在别处被删掉时，选中的那一页要退回通用页，而不是留一个空子页。
        .onChange(of: store.subscriptions.map(\.id)) { _, _ in
            navigation.finishEditingIfMissing(subscriptions: store.subscriptions)
        }
    }

    // MARK: - 侧边栏

    /// 详情区的两种外壳。
    ///
    /// 订阅编辑器自带滚动，底栏钉在它自己底部：外面再套一层 ScrollView 会让那条底栏
    /// 跟着内容一起滚走——两层 ScrollView 里层拿不到高度约束，索性不滚，整页变成一长条。
    /// 其余页面是一叠卡片，交给外层滚动，标题也跟着滚。
    @ViewBuilder
    private var paneSurface: some View {
        if paneScrollsItself {
            paneContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
                .background(.windowBackground)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // 订阅子页与新增页自带页头（`PageHeader` / 供应商选择的标题行），
                    // 不再叠一个通用标题。
                    if navigation.pane.subscriptionID == nil, navigation.pane != .addSubscription,
                       !navigation.showsMigration {
                        heading
                    }
                    paneContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .background(.windowBackground)
        }
    }

    /// 这一页自己滚：订阅编辑器，也就是编辑已有订阅、以及选完供应商之后的新建页。
    private var paneScrollsItself: Bool {
        navigation.pane.subscriptionID != nil
            || (navigation.pane == .addSubscription && navigation.newSubscriptionDraft != nil)
    }

    private var sidebar: some View {
        List(selection: paneSelection) {
            Section("应用") {
                row(.general)
                row(.rail)
                row(.notifications)
            }

            Section("订阅") {
                row(.addSubscription)
                ForEach(store.subscriptions) { subscription in
                    subscriptionRow(subscription)
                }
            }

            Section("其他") {
                row(.data)
                row(.about)
            }
        }
        .listStyle(.sidebar)
        // **下限写在内容上，不是 `navigationSplitViewColumnWidth`。**
        // 后者的 `ideal` 只在列第一次布局时读一次，列被重建之后就找不回来了。
        // `minWidth` 是布局约束，每次重建都会重新施加，这才是这里需要的性质。
        .frame(minWidth: 200)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
    }

    private var paneSelection: Binding<SettingsPane?> {
        Binding(
            get: { navigation.pane },
            set: { if let pane = $0 { navigation.select(pane, subscriptions: store.subscriptions) } }
        )
    }

    private func row(_ pane: SettingsPane) -> some View {
        Label {
            Text(pane.title)
        } icon: {
            Image(systemName: pane.symbol)
                .foregroundStyle(pane == .addSubscription ? TM.accent : Color.primary)
        }
        .tag(pane)
    }

    private func subscriptionRow(_ subscription: Subscription) -> some View {
        let metadata = ProviderRegistry.definition(for: subscription.providerID)?.metadata
        return Label {
            Text(subscription.name)
        } icon: {
            ProviderMarkView(
                resource: metadata?.railMarkResource,
                fallbackSystemImage: metadata?.fallbackSystemImage ?? "questionmark",
                size: 15
            )
        }
        .tag(SettingsPane.subscription(subscription.id))
    }

    // MARK: - 右侧

    private var heading: some View {
        Text(navigation.pane.title)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(TM.textPrimary)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch navigation.pane {
        case .general: general
        case .rail: rail
        case .notifications: notifications
        case .data: data
        case .about: about
        case .addSubscription: addSubscription
        case .subscription: subscription
        }
    }

    private func toggle(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        SettingsRow(title, subtitle: subtitle) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private func picker<Value: Hashable>(
        _ title: String,
        subtitle: String? = nil,
        selection: Binding<Value>,
        @ViewBuilder options: () -> some View
    ) -> some View {
        SettingsRow(title, subtitle: subtitle) {
            Picker(title, selection: selection) { options() }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: SettingsLayout.controlWidth, alignment: .trailing)
        }
    }

    // MARK: - 通用

    private var general: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup("启动与刷新") {
                toggle("登录时启动", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                SettingsRowDivider()
                toggle("打开时刷新", isOn: $settings.refreshOnOpen)
                SettingsRowDivider()
                toggle("后台自动刷新", isOn: $settings.autoRefreshEnabled)
                SettingsRowDivider()
                picker(
                    "刷新间隔",
                    selection: $settings.refreshInterval
                ) {
                    ForEach(SettingsStore.refreshIntervalPresets, id: \.self) { seconds in
                        Text("\(Int(seconds / 60)) 分钟").tag(seconds)
                    }
                }
                .disabled(!settings.autoRefreshEnabled)
            }

            SettingsGroup("外观") {
                picker("主题", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                SettingsRowDivider()
                toggle(
                    "浅色玻璃特效",
                    subtitle: "浅色主题下面板使用磨砂玻璃背景；关闭时为纯白。深色主题始终用深色渐变。",
                    isOn: $settings.glassEffectEnabled
                )
            }

            SettingsGroup("菜单栏") {
                toggle(
                    "点击图标弹出面板",
                    subtitle: "关掉之后图标还在，只是左键改弹右键那个菜单；面板从此只有这个图标能打开。",
                    isOn: $settings.menuBarItemOpensPanel
                )
            }

            SettingsGroup {
                HStack(spacing: 6) {
                    Text(settings.loginItemStatus.label)
                        .font(.system(size: 11))
                        .foregroundStyle(TM.textTertiary)
                    Spacer()
                    Button("刷新状态") { settings.refreshLoginItemStatus() }
                        .font(.system(size: 11))
                        .foregroundStyle(TM.accent)
                        .buttonStyle(.plain)
                }
                if let error = settings.loginItemError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(TM.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 悬浮条

    private var rail: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup("显示") {
                toggle("显示悬浮条", isOn: $settings.railEnabled)
                SettingsRowDivider()
                picker(
                    "条的配色",
                    subtitle: "环与详情卡片跟着它走。开着玻璃特效时由玻璃材质决定。",
                    selection: $settings.railColorScheme
                ) {
                    ForEach(RailColorScheme.allCases) { scheme in
                        Text(scheme.title).tag(scheme)
                    }
                }
                SettingsRowDivider()
                toggle("离开时自动收起", isOn: $settings.railAutoCollapse)
                SettingsRowDivider()
                toggle("跟随鼠标所在显示器", isOn: $settings.railFollowsActiveDisplay)
                SettingsRowDivider()
                toggle("全屏应用时隐藏", isOn: $settings.railHidesInFullScreen)
            }

            SettingsGroup("位置") {
                picker(
                    "贴边位置",
                    subtitle: "也可以直接拖动悬浮条：拖到屏幕边缘会吸附上去。",
                    selection: Binding(
                        get: { railPlacement.dock },
                        set: { railPlacement.update(dock: $0) }
                    )
                ) {
                    Text("贴到屏幕左侧").tag(RailDock.edge(.left))
                    Text("贴到屏幕右侧").tag(RailDock.edge(.right))
                    Text("贴到屏幕顶部").tag(RailDock.edge(.top))
                    Text("自由悬浮").tag(RailDock.floating)
                }
            }

            SettingsGroup("形状") {
                picker(
                    "环间距",
                    subtitle: "环本身大小不变，只是摆得更开或更紧。",
                    selection: $settings.railSpacing
                ) {
                    ForEach(RailSpacing.allCases) { spacing in
                        Text(spacing.title).tag(spacing)
                    }
                }
                SettingsRowDivider()
                toggle(
                    "圆角端",
                    subtitle: "条的端头用整圆，与它包住的环同一条中心线，跟着那个环绕过去。",
                    isOn: $settings.railUsesRoundEnds
                )
            }

            SettingsGroup("环上画什么") {
                toggle(
                    "显示剩余",
                    subtitle: "弧与数字一起倒数。颜色照旧按已用比例取——还剩多少不改变离用尽还有多远。",
                    isOn: $settings.railShowsRemaining
                )
                SettingsRowDivider()
                toggle(
                    "数字在环上方",
                    subtitle: "把环与数字换个位置，贴哪条边都一样。",
                    isOn: $settings.railLabelAboveRing
                )
                SettingsRowDivider()
                toggle(
                    "侧边显示百分比",
                    subtitle: "贴左右边时，环下方那行数字。",
                    isOn: $settings.railSideShowsPercentages
                )
                SettingsRowDivider()
                toggle(
                    "顶部显示百分比",
                    subtitle: "贴顶时也画那行数字；条会因此变粗一些。",
                    isOn: $settings.railTopShowsPercentages
                )
                SettingsRowDivider()
                toggle(
                    "环内第二圈",
                    subtitle: "再画一圈细弧，给次满的那个额度。只有一个额度时不画。",
                    isOn: $settings.railShowsSecondRing
                )
                SettingsRowDivider()
                toggle(
                    "距重置时间的外弧",
                    subtitle: "环外一道细弧，表示这个额度窗口已经过去了多少。只有 5 小时与每周额度算得出长度。",
                    isOn: $settings.railShowsWindowClock
                )
                SettingsRowDivider()
                toggle(
                    "取数时环上跑一段弧",
                    subtitle: "刷新期间环上有一段弧在转。",
                    isOn: $settings.railAnimatesActivity
                )
                SettingsRowDivider()
                toggle(
                    "收起时给细条染色",
                    subtitle: "某个额度快到临界时，卷起来的那道细条染上它的颜色。关掉则细条始终中性。",
                    isOn: $settings.railDockShowsAlertColor
                )
            }

            orderGroup

            SettingsGroup {
                Text("悬浮条一整天停在屏幕边上：鼠标划过展开，悬停某个图标看详情，点击刷新该订阅，右键切换位置。每条订阅自己那一份（是否上条、环追哪个额度、环什么颜色）在它的订阅设置里。")
                    .font(.system(size: 11))
                    .foregroundStyle(TM.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 「显示顺序」：悬浮条上环的顺序、面板里卡片的顺序、侧边栏的顺序，都是这一个。
    ///
    /// 箭头与拖放都给（移植自 Pulse 的 Order 组）：箭头是一格一格的精确做法，
    /// 也是键盘与辅助功能唯一能走的路；拖放一次跨很多格。悬停中的目标行高亮一下，
    /// 不然放手前不知道会落在谁身上。
    @ViewBuilder
    private var orderGroup: some View {
        if !store.subscriptions.isEmpty {
            SettingsGroup("显示顺序") {
                ForEach(Array(store.subscriptions.enumerated()), id: \.element.id) { index, subscription in
                    if index > 0 { SettingsRowDivider() }
                    orderRow(subscription, index: index)
                }
            }
        }
    }

    private func orderRow(_ subscription: Subscription, index: Int) -> some View {
        let metadata = ProviderRegistry.definition(for: subscription.providerID)?.metadata
        return SettingsRow(
            subscription.name,
            // 排一个悬浮条上没有的东西，看起来像是箭头没生效。
            subtitle: subscription.rail.showsInRail ? nil : "未显示在悬浮条上",
            icon: metadata?.railMarkResource,
            iconFallback: metadata?.fallbackSystemImage ?? "questionmark"
        ) {
            HStack(spacing: 4) {
                Button { store.moveSubscription(subscription.id, by: -1) } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(index == 0)
                .accessibilityLabel("将「\(subscription.name)」上移一格")

                Button { store.moveSubscription(subscription.id, by: 1) } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(index == store.subscriptions.count - 1)
                .accessibilityLabel("将「\(subscription.name)」下移一格")
            }
            .buttonStyle(.borderless)
        }
        // 整行都能被拖：只有文字能起拖的话，多数人试不出来有拖放。
        .contentShape(.rect)
        .background(dropTargetID == subscription.id ? TM.accent.opacity(0.12) : Color.clear)
        .draggable(subscription.id.uuidString) {
            // 系统默认的拖拽图是整行——整个窗口宽的一坨。拖拽图只需要标记与名字。
            HStack(spacing: 8) {
                ProviderMarkView(
                    resource: metadata?.railMarkResource,
                    fallbackSystemImage: metadata?.fallbackSystemImage ?? "questionmark",
                    size: 15
                )
                Text(subscription.name)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .dropDestination(for: String.self) { ids, _ in
            dropTargetID = nil
            guard let dragged = ids.first.flatMap(UUID.init(uuidString:)),
                  store.subscriptions.contains(where: { $0.id == dragged })
            else { return false }
            store.moveSubscription(dragged, onto: subscription.id)
            return true
        } isTargeted: { isTargeted in
            // 进出两行的报告顺序没人保证，所以清掉要按身份来，
            // 不能在离开时无条件清——会把下一行刚设上的高亮抹掉。
            if isTargeted {
                dropTargetID = subscription.id
            } else if dropTargetID == subscription.id {
                dropTargetID = nil
            }
        }
    }

    // MARK: - 通知

    private var notifications: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup("提醒") {
                toggle("余额偏低提醒", isOn: $settings.lowBalanceAlerts)
                SettingsRowDivider()
                toggle("认证过期提醒", isOn: $settings.authenticationAlerts)
                SettingsRowDivider()
                toggle("服务错误提醒", isOn: $settings.serviceErrorAlerts)
            }

            SettingsGroup("余额阈值") {
                SettingsRow("低于 CNY") {
                    TextField("0", value: $settings.cnyBalanceThreshold, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
                SettingsRowDivider()
                SettingsRow("低于 USD") {
                    TextField("0", value: $settings.usdBalanceThreshold, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
            }

            SettingsGroup {
                HStack(spacing: 5) {
                    Circle()
                        .fill(settings.notificationStatus == .authorized ? TM.ok : TM.warn)
                        .frame(width: 6, height: 6)
                    Text(settings.notificationStatusLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(TM.textSecondary)
                    Spacer()
                    if settings.notificationStatus == .notDetermined {
                        Button("允许通知") { settings.requestNotificationsIfNeeded() }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(TM.accent)
                            .buttonStyle(.plain)
                    } else if settings.notificationStatus == .denied {
                        Button("前往系统设置") { settings.openNotificationSettings() }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(TM.accent)
                            .buttonStyle(.plain)
                    }
                }
                if settings.notificationStatus == .denied {
                    Text("请在 系统设置 → 通知 → TokenMeter 中开启。")
                        .font(.system(size: 11))
                        .foregroundStyle(TM.textTertiary)
                }
                if let error = settings.notificationRequestError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(TM.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 数据迁移

    /// 数据迁移：一张卡片加迁移子页。
    ///
    /// 迁移页原来住在菜单面板里，由这里的「打开…」把面板叫出来；面板的二级页删掉之后，
    /// 它成了这一页的子页，和外观是订阅的子页一样。
    @ViewBuilder
    private var data: some View {
        if navigation.showsMigration {
            MigrationPanel(store: store) { navigation.closeMigration() }
        } else {
            VStack(alignment: .leading, spacing: 22) {
                SettingsGroup("凭据迁移") {
                    SettingsRow(
                        "导入或导出凭据迁移包",
                        subtitle: "把订阅配置与私有凭据打包迁移到另一台 Mac。"
                    ) {
                        Button("打开…") { navigation.openMigration() }
                    }
                }

                if let persistenceError = store.lastPersistenceError {
                    errorNote(persistenceError)
                }
                if let recoveryError = store.lastMigrationRecoveryError {
                    errorNote(recoveryError)
                }
            }
        }
    }

    private func errorNote(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(TM.danger)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 关于

    private var about: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup("TokenMeter") {
                SettingsRow("版本") {
                    Text(version)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(TM.textSecondary)
                }
                SettingsRowDivider()
                SettingsRow("反馈问题", subtitle: "在 GitHub 上提 issue。") {
                    Link("打开", destination: URL(string: "https://github.com/Amdeo/TokenMeter/issues/new/choose")!)
                }
            }

            SettingsGroup {
                Label("凭据以本地明文文件保存，受文件权限保护", systemImage: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(TM.textTertiary)
            }
        }
    }

    // MARK: - 订阅子页

    @ViewBuilder
    private var subscription: some View {
        if let draft = navigation.subscriptionDraft {
            if navigation.showsAppearance {
                SubscriptionAppearanceContent(
                    draft: draft,
                    onDone: { navigation.showsAppearance = false }
                )
            } else {
                SubscriptionEditorContent(
                    draft: draft,
                    subscription: draft.original,
                    onFinish: { navigation.finishEditing(subscriptions: store.subscriptions) },
                    onAppearance: { navigation.showsAppearance = true }
                )
            }
        } else {
            Text("这条订阅已经不存在了。")
                .font(.system(size: 12))
                .foregroundStyle(TM.textSecondary)
        }
    }

    // MARK: - 新增订阅

    /// 先选供应商，再配置。
    ///
    /// 与面板里的 TM-03 → TM-04 是同一条流程，只是宿主换成了窗口：
    /// 供应商选择与配置正文都是两边共用的视图。
    @ViewBuilder
    private var addSubscription: some View {
        if let draft = navigation.newSubscriptionDraft {
            if navigation.showsAppearance {
                SubscriptionAppearanceContent(
                    draft: draft,
                    onDone: { navigation.showsAppearance = false }
                )
            } else {
                SubscriptionEditorContent(
                    draft: draft,
                    onFinish: { navigation.select(.general, subscriptions: store.subscriptions) },
                    onAppearance: { navigation.showsAppearance = true },
                    onCreated: { id in
                        navigation.didCreate(id, subscriptions: store.subscriptions)
                    }
                )
            }
        } else {
            ProviderSelectionContent(
                onSelect: { navigation.chooseProvider($0) }
            )
        }
    }
}
