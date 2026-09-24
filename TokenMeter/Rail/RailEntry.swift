import SwiftUI

/// 悬浮条上一个环的全部呈现数据。
///
/// 移植自 Pulse 的 `RailEntry`，去掉它的账号拆分、活动标记与预算预测：
/// TokenMeter 一条订阅就是一个环。
struct RailEntry: Identifiable, Equatable {
    /// 订阅 id。环的顺序就是订阅顺序，用户拖过的排序直接生效。
    let id: UUID
    let title: String

    /// 单色矢量标记的资源名；没有对应标记时用 `fallbackSystemImage`。
    let markResource: String?
    let fallbackSystemImage: String

    /// 弧画多少。nil 表示没有可画的比例——只有余额的供应商，或者还没拿到读数。
    let fraction: Double?
    /// 没有比例时环里画什么。
    ///
    /// 只卖预付费额度的供应商不上报额度窗口，所以「只显示余额」时故意没有比例——
    /// 但**有**一个数字。一个环里画个破折号、旁边是一个好端端的余额，读起来像是
    /// 这个供应商挂了。
    let figure: String?

    let status: QuotaStatus
    let state: UsageState
    let errorMessage: String?
    let updatedAt: Date?

    /// 用户为这个环选的颜色；nil 表示按用量状态取色。
    let chosenTint: Color?

    /// 次满的那个额度的比例，画成环里那圈细弧。nil 表示没有第二个额度可画。
    let secondFraction: Double?
    /// 次满额度的状态：那圈细弧按它自己取色，而不是跟着主弧。
    let secondStatus: QuotaStatus?
    /// 环画的这个额度，它的窗口已经过去了多少。nil 表示推不出窗口长度。
    let windowElapsed: Double?

    /// 详情卡片里逐条列出的额度。
    let rows: [Row]

    struct Row: Identifiable, Equatable {
        /// 额度行的 id；「总使用量」不是额度行，用 `SubscriptionQuotaColors.overallKey`。
        let id: String
        let name: String
        let fraction: Double
        /// 已用 / 上限。没有数字可写时（总使用量只有比例）为 nil。
        let usedText: String?
        let limitText: String?
        let resetAt: Date?
        let kind: Quota.Kind
        let status: QuotaStatus
        /// 用户在编辑页为该额度选的颜色；nil 表示按语义类型取默认色。
        let colorRGB: UInt32?
    }

    /// 按用量状态取的语义色，与面板卡片同一套阈值（绿 <80% / 橙 ≥80% / 红 =100%）。
    ///
    /// 刻意不用编辑页里那套进度条配色：环在一瞥之间要回答的是「还够不够用」，
    /// 不是「这是哪个窗口」。逐条的颜色留给卡片里的进度条。
    ///
    /// 与 `tint` 分开是因为它还要供**条在收起时的染色**使用——那也是状态，不是身份。
    var statusTint: Color { Self.tint(for: status) }

    /// 次满额度那圈细弧的颜色。它按自己的状态取色：主弧还剩得很多、
    /// 次弧已经用尽时，那圈细弧仍然该是红的。
    var secondTint: Color? {
        secondStatus.map(Self.tint(for:))
    }

    /// 某个用量状态对应的语义色。环、细弧与细条染色都从这一处取。
    static func tint(for status: QuotaStatus) -> Color {
        switch status {
        case .normal: TM.ok
        case .warning: TM.warn
        case .exhausted, .error: TM.danger
        }
    }

    /// 环、环里的标记与下方数字画什么颜色。
    ///
    /// 用户选的颜色是**身份**（这是哪条订阅），状态是**读数**（还够不够用），
    /// 两者不是一回事——所以额度真的用尽时仍然是红的：被挡住不是口味问题，
    /// 那是这个 app 存在的意义。Pulse 的 `UsageRingView.chosenTint` 同一条规则。
    var tint: Color {
        status == .exhausted ? TM.danger : (chosenTint ?? statusTint)
    }
}

/// 把订阅与快照组装成环。
enum RailEntryBuilder {
    /// 悬浮条上出现哪些订阅：用户没有关掉「在悬浮条中显示」的那些，顺序即订阅顺序。
    ///
    /// **条的长度、点击落在哪个环上、窗口尺寸全都由它决定**，所以「谁在条上」
    /// 只能有这一个判断处——`RailView` 与 `RailWindowController` 都读它，
    /// 否则索引与绘制会各算各的。
    @MainActor
    static func railSubscriptions(from subscriptions: [Subscription]) -> [Subscription] {
        subscriptions.filter(\.rail.showsInRail)
    }

    /// 一条订阅一个环，顺序即订阅顺序。
    ///
    /// 还没拿到读数的订阅也进条里：环画成空弧，而不是让它在条上凭空消失又出现。
    @MainActor
    static func entries(
        subscriptions: [Subscription],
        snapshots: [UUID: UsageSnapshot]
    ) -> [RailEntry] {
        railSubscriptions(from: subscriptions).map { subscription in
            entry(for: subscription, snapshot: snapshots[subscription.id])
        }
    }

    @MainActor
    static func entry(for subscription: Subscription, snapshot: UsageSnapshot?) -> RailEntry {
        let metadata = ProviderRegistry.definition(for: subscription.providerID)?.metadata
        let quotaRows = snapshot.map { rows(for: $0, subscription: subscription) } ?? []
        let reading = snapshot.flatMap { headlineReading(of: $0, tracked: subscription.rail.trackedWindow) }
        let fraction = reading?.fraction
        let second = snapshot.flatMap { secondQuota(of: $0, after: reading?.quota) }
        let status = snapshot.map { snapshot in
            // 拿不到读数时状态由快照自己的错误/状态决定，而不是由「比例是 0」决定。
            snapshot.state == .realtime
                ? SubscriptionCardPresentation.ratioStatus(for: fraction ?? 0)
                : snapshot.overallStatus
        } ?? .normal

        return RailEntry(
            id: subscription.id,
            title: subscription.name,
            markResource: metadata?.railMarkResource,
            fallbackSystemImage: metadata?.fallbackSystemImage ?? "questionmark",
            fraction: fraction,
            figure: fraction == nil ? balanceFigure(of: snapshot) : nil,
            status: status,
            state: snapshot?.state ?? .notConfigured,
            errorMessage: snapshot?.errorMessage,
            updatedAt: snapshot?.updatedAt,
            chosenTint: subscription.rail.tintRGB.map { Color(hex: $0) },
            secondFraction: second?.fraction,
            secondStatus: second?.status,
            windowElapsed: reading?.quota.flatMap { windowElapsed(of: $0) },
            rows: quotaRows
        )
    }

    /// 环画哪个数：默认**最接近用尽的那一个窗口**。
    ///
    /// 额度窗口（5 小时 / 每周 / 通用）比余额更值得占住环——它们是会到期的速率限制，
    /// 而余额只是花掉多少。一个窗口都没有时才回落到「总使用量」聚合比例。
    ///
    /// 用户在编辑页钉住某个额度时画它。钉住的那个在这次读数里不存在——供应商换了窗口名、
    /// 或者钉的是「总使用量」而这次没上报——就退回上面那条规则，而不是画一个空环。
    ///
    /// 额度本身也返回：窗口时钟那圈弧要知道它属于哪个额度。
    private static func headlineReading(
        of snapshot: UsageSnapshot,
        tracked: String?
    ) -> (quota: Quota?, fraction: Double?)? {
        guard snapshot.state == .realtime else { return nil }
        if let tracked {
            if tracked == SubscriptionRailSettings.overallKey, let overall = snapshot.overallUsageRatio {
                // 「总使用量」不是额度窗口，没有窗口长度可算，所以额度是 nil。
                return (nil, overall)
            }
            // 余额不是比例，钉不住它：它画的是数字，不是弧。
            if let pinned = snapshot.quotas.first(where: { $0.kind != .balance && $0.name == tracked }) {
                return (pinned, pinned.fraction)
            }
        }
        let windows = snapshot.quotas.filter { $0.kind != .balance }
        if let worst = windows.max(by: { $0.fraction < $1.fraction }) {
            return (worst, worst.fraction)
        }
        return (nil, snapshot.overallUsageRatio)
    }

    /// 次满的那个额度：环里那圈细弧画它。
    ///
    /// 与主弧同一个池子里挑，余额不算——它没有比例可画。只有一个额度时返回 nil，
    /// 空着一圈细弧读起来像一个坏掉的读数，而不是「只有一个额度」。
    private static func secondQuota(of snapshot: UsageSnapshot, after headline: Quota?) -> Quota? {
        guard snapshot.state == .realtime else { return nil }
        let rest = snapshot.quotas.filter { $0.kind != .balance && $0.id != headline?.id }
        return rest.max { $0.fraction < $1.fraction }
    }

    /// 这个额度的窗口已经过去了多少。
    ///
    /// 只知道**什么时候重置**和窗口的**类型**，所以长度由类型推：5 小时 / 每周。
    /// 通用额度没有可推的长度，返回 nil——画一个长度靠猜的弧比不画更糟。
    static func windowElapsed(of quota: Quota, now: Date = .now) -> Double? {
        guard let resetAt = quota.resetAt, let length = windowLength(of: quota.kind) else { return nil }
        let remaining = resetAt.timeIntervalSince(now)
        guard remaining > 0 else { return 1 }
        return min(max(1 - remaining / length, 0), 1)
    }

    private static func windowLength(of kind: Quota.Kind) -> TimeInterval? {
        switch kind {
        case .fiveHour: 5 * 3600
        case .weekly: 7 * 24 * 3600
        case .generic, .balance: nil
        }
    }

    /// 一个窗口都没有时，环里画那个余额数字。
    ///
    /// **只取数值，不带币种**：条宽 64pt、标签预算 38pt，「CNY 28.17」会把预算撑破，
    /// 而币种在详情卡片里有的是地方写。
    private static func balanceFigure(of snapshot: UsageSnapshot?) -> String? {
        guard let snapshot, snapshot.state == .realtime else { return nil }
        guard let balance = snapshot.quotas.first(where: { $0.kind == .balance }) else { return nil }
        return railText(for: balance.remaining, unit: balance.unit)
    }

    /// 余额在环里的短格式。移植自 Pulse 的 `CreditAmount.railText`。
    ///
    /// 一个余额可以任意长，而标签的宽度是**预算**——它在 AppKit 那边的窗口尺寸里
    /// 已经被算进去了，由文字内容决定宽度就等于让内容去改窗口。所以这里把数字本身
    /// 限制到最多「两位整数 + 小数点 + 两位小数」：超过一百丢掉小数，上千换成 k / M。
    ///
    /// **截断，绝不四舍五入。** 余额显示得比实际多，是错在错误的方向上；
    /// 顺带也把进位处理掉了——999,999 变成「999k」而不是「1000k」。
    static func railText(for value: Double, unit: QuotaUnit) -> String {
        let amount = value / unit.displayScale
        let magnitude = abs(amount)
        let (scaled, suffix): (Double, String) = if magnitude >= 1_000_000 {
            (amount / 1_000_000, "M")
        } else if magnitude >= 1_000 {
            (amount / 1_000, "k")
        } else {
            (amount, "")
        }

        let places = abs(scaled) >= 100 ? 0 : (suffix.isEmpty ? 2 : 1)
        let scale = pow(10, Double(places))
        let shown = (scaled * scale).rounded(.towardZero) / scale
        return String(format: "%.\(places)f", shown) + suffix
    }

    private static func rows(for snapshot: UsageSnapshot, subscription: Subscription) -> [RailEntry.Row] {
        let colors = subscription.quotaColors[subscription.cardStyle]
        var rows = snapshot.quotas.map { quota in
            RailEntry.Row(
                id: quota.id.uuidString,
                name: quota.name,
                fraction: quota.fraction,
                // 卡片那一行要同时放重置提示与两个金额，`USD 1761.00 / USD 2304.00` 放不下，
                // 所以这里用紧凑写法（`$1761.00 / $2304.00`）。
                usedText: Quota.compactText(value: quota.used, unit: quota.unit),
                limitText: Quota.compactText(value: quota.limit, unit: quota.unit),
                resetAt: quota.resetAt,
                kind: quota.kind,
                status: quota.status,
                colorRGB: colors[SubscriptionQuotaColors.nameKey(quota.name)]
                    ?? SubscriptionQuotaColors.kindKey(for: quota.kind).flatMap { colors[$0] }
                    ?? colors[SubscriptionQuotaColors.genericKey]
            )
        }

        // 「总使用量」不是额度行——它是面板卡片顶部那个锚点的数据。悬浮条卡片也把它列上，
        // 排在最前，与面板一样是头条。仅订阅制（非 API Key）模式有这个数字，与面板同一条规则。
        if let overall = snapshot.overallUsageRatio, subscription.authMethodID != .apiKey {
            rows.insert(RailEntry.Row(
                id: SubscriptionQuotaColors.overallKey,
                name: "总使用量",
                fraction: overall,
                usedText: nil,
                limitText: nil,
                resetAt: snapshot.overallResetAt,
                kind: .generic,
                status: SubscriptionCardPresentation.ratioStatus(for: overall),
                // 用户在编辑页给总使用量配过色就用它；没配过走 generic 默认色，
                // 与卡里其它行「没配置就按类型取默认」同一条规矩。
                colorRGB: SubscriptionQuotaColors.hasOverallConfiguration(colors)
                    ? SubscriptionQuotaColors.resolveOverall(colors).tokenMeterRGB
                    : nil
            ), at: 0)
        }

        return rows
    }
}
