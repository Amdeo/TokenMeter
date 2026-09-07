import SwiftUI
import AppKit

enum SubscriptionCredentialRequirement {
    static func canSave(
        original: Subscription.AuthMethod?,
        selected: Subscription.AuthMethod,
        apiKey: String,
        hasOAuthCredential: Bool,
        hasBrowserCredential: Bool,
        isImportingBrowser: Bool
    ) -> Bool {
        guard !isImportingBrowser else { return false }
        guard original != selected else { return true }
        return switch selected {
        case .manualAPIKey: !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .kimiOAuth: hasOAuthCredential
        case .kimiBrowserSession: hasBrowserCredential
        }
    }
}

struct SubscriptionEditorSheet: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let subscription: Subscription?
    let onClose: () -> Void
    @Bindable var draft: SubscriptionEditorDraft
    @State private var showDeleteConfirmation = false
    @State private var showDiscardConfirmation = false

    init(draft: SubscriptionEditorDraft, subscription: Subscription? = nil, onClose: @escaping () -> Void = {}) {
        self.subscription = subscription
        self.onClose = onClose
        self.draft = draft
    }

    private var isEditing: Bool { subscription != nil }

    private var quotaColorTargets: [QuotaColorTarget] {
        let snapshot = subscription.flatMap { store.snapshots[$0.id] }
        return QuotaColorTarget.targets(platform: draft.platform, quotas: snapshot?.quotas ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                platform: draft.platform,
                title: draft.platform.rawValue,
                subtitle: "配置订阅",
                onBack: attemptClose
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SheetSection(title: "订阅信息", subtitle: "名称仅用于本地识别，可稍后修改。") {
                        FormField("名称（可选）", text: $draft.name)
                    }
                    SheetSection(title: "认证方式", subtitle: "凭证只会写入 TokenMeter 本地私有文件，不会保存到订阅元数据。") {
                        AuthMethodSelection(
                            authMethod: $draft.authMethod,
                            platform: draft.platform,
                            apiKey: $draft.apiKey,
                            oauthDevice: draft.oauthDevice,
                            oauthStatus: draft.oauthStatus,
                            isAuthorizing: draft.oauthTask != nil,
                            onStartOAuth: startOAuth,
                            onCancelOAuth: cancelOAuth,
                            isImportingBrowser: draft.browserImportTask != nil,
                            onStartEmbeddedLogin: startEmbeddedLogin,
                            onOpenURL: { openURL($0) },
                            onCopy: copy
                        )
                    }
                    SheetSection(title: "进度条颜色", subtitle: "每个额度窗口可单独设置；未配置的额度使用默认颜色。") {
                        QuotaColorEditor(colors: $draft.quotaColors, targets: quotaColorTargets)
                    }
                    if let message = draft.message {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(TM.warn)
                            .padding(.horizontal, TM.cardContentHorizontal).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(TM.warn.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding(.vertical, 18)
                .reportsIntrinsicPanelHeight(
                    route: subscription.map { .editConfiguration($0.id) } ?? .addConfiguration,
                    chrome: PanelLayoutMetrics.pageChrome
                )
            }
            HStack(spacing: 10) {
                if isEditing {
                    Button("删除订阅", role: .destructive) { showDeleteConfirmation = true }
                        .buttonStyle(.plain).foregroundStyle(TM.danger)
                }
                Spacer()
                Button("取消", action: attemptClose).keyboardShortcut(.cancelAction)
                Button(isEditing ? "保存修改" : "添加订阅", action: save)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!canSave || draft.isAuthenticating)
            }
            .font(.system(size: 12)).padding(.top, 10).padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: draft.authMethod) { _, method in
            if method != .kimiOAuth { resetOAuthState() }
            if method != .kimiBrowserSession { draft.leaveBrowserAuthentication() }
        }
        .overlay {
            if showDiscardConfirmation {
                ConfirmDialog(
                    title: "放弃更改？",
                    message: "未保存的内容将丢失，正在进行的认证流程也会被取消。",
                    confirmTitle: "放弃更改",
                    onConfirm: {
                        showDiscardConfirmation = false
                        onClose()
                    },
                    onCancel: {
                        withAnimation(reduceMotion ? .none : .easeOut(duration: 0.15)) { showDiscardConfirmation = false }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else if showDeleteConfirmation {
                ConfirmDialog(
                    title: "删除订阅",
                    message: "将删除「\(subscription?.name ?? "")」的订阅与本地凭证，此操作不可撤销。",
                    confirmTitle: "删除",
                    onConfirm: {
                        showDeleteConfirmation = false
                        deleteSubscription()
                    },
                    onCancel: {
                        withAnimation(reduceMotion ? .none : .easeOut(duration: 0.15)) { showDeleteConfirmation = false }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
    }

    private var canSave: Bool {
        SubscriptionCredentialRequirement.canSave(
            original: subscription?.authMethod,
            selected: draft.authMethod,
            apiKey: draft.apiKey,
            hasOAuthCredential: draft.oauthCredential != nil,
            hasBrowserCredential: draft.browserCredential != nil,
            isImportingBrowser: draft.browserImportTask != nil
        )
    }

    private func attemptClose() { if draft.isDirty { showDiscardConfirmation = true } else { onClose() } }
    private func save() { subscription.map { saveEditing($0) } ?? saveNew() }

    private func saveNew() {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let subscription = Subscription(
            platform: draft.platform,
            name: trimmedName.isEmpty ? draft.platform.rawValue : trimmedName,
            authMethod: draft.authMethod,
            quotaColors: draft.quotaColors
        )
        do {
            try saveCredential(for: subscription.id)
            store.add(subscription)
            onClose()
            Task { await store.refresh(subscription) }
        } catch { draft.message = error.localizedDescription }
    }

    private func saveEditing(_ subscription: Subscription) {
        guard canSave else { draft.message = "切换认证方式后，请先提供对应的新凭证。"; return }
        do {
            try saveCredential(for: subscription.id)
            var updated = subscription
            if subscription.authMethod != draft.authMethod { store.updateAuthMethod(subscription, to: draft.authMethod); updated.authMethod = draft.authMethod }
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, name != subscription.name { store.rename(subscription, to: name); updated.name = name }
            if draft.quotaColors != subscription.quotaColors {
                store.updateQuotaColors(draft.quotaColors, for: subscription)
                updated.quotaColors = draft.quotaColors
            }
            onClose()
            Task { await store.refresh(updated) }
        } catch { draft.message = error.localizedDescription }
    }

    private func saveCredential(for id: UUID) throws {
        switch draft.authMethod {
        case .manualAPIKey:
            guard !draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            try CredentialStore().save(apiKey: draft.apiKey, for: id)
        case .kimiOAuth:
            guard let credential = draft.oauthCredential else { return }
            try CredentialStore().save(oauthCredential: credential, for: id)
        case .kimiBrowserSession:
            guard let credential = draft.browserCredential else { return }
            try CredentialStore().save(browserCredential: credential, for: id)
        }
    }

    private func deleteSubscription() { guard let subscription else { return }; store.remove(subscription); onClose() }
    private func resetOAuthState() { draft.oauthSessionID = UUID(); draft.oauthTask?.cancel(); draft.oauthTask = nil; draft.oauthCredential = nil; draft.oauthDevice = nil; draft.oauthStatus = nil }
    private func cancelOAuth() { resetOAuthState() }

    private func startOAuth() {
        resetOAuthState(); let sessionID = draft.oauthSessionID; draft.oauthStatus = "正在请求设备授权…"; draft.message = nil
        draft.oauthTask = Task { @MainActor in
            do {
                let credential = try await KimiOAuthService().authorize { device in
                    await MainActor.run {
                        guard sessionID == draft.oauthSessionID else { return }
                        draft.oauthDevice = device
                        draft.oauthStatus = "请在浏览器中完成授权，TokenMeter 会自动等待结果。"
                    }
                }
                guard sessionID == draft.oauthSessionID else { return }
                draft.oauthCredential = credential; draft.oauthStatus = "已完成官方授权"
            } catch is CancellationError {} catch { guard sessionID == draft.oauthSessionID else { return }; draft.oauthStatus = nil; draft.message = error.localizedDescription }
            guard sessionID == draft.oauthSessionID else { return }; draft.oauthTask = nil
        }
    }

    private func startEmbeddedLogin() {
        resetOAuthState(); draft.leaveBrowserAuthentication(); let sessionID = draft.browserImportSessionID; draft.message = nil
        draft.browserImportTask = Task { @MainActor in
            do {
                let credential = try await EmbeddedKimiLoginController().login()
                guard sessionID == draft.browserImportSessionID, draft.authMethod == .kimiBrowserSession else { return }
                draft.browserCredential = credential; draft.oauthStatus = "已通过内置登录导入 Kimi 网页登录态"
            } catch is CancellationError {} catch { guard sessionID == draft.browserImportSessionID else { return }; draft.message = error.localizedDescription }
            guard sessionID == draft.browserImportSessionID else { return }; draft.browserImportTask = nil
        }
    }

    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
}

private struct PageHeader: View {
    let platform: Platform
    let title: String
    let subtitle: String
    let onBack: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            HeaderIconButton(systemName: "chevron.left", label: "返回概览", action: onBack)
            PlatformLogo(platform: platform, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.5)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(TM.textSecondary)
            }
            Spacer()
        }
        .padding(.bottom, 10)
    }
}

// MARK: - 通用组件

private struct SheetSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(TM.textTertiary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(TM.textSecondary)
            }
            content()
        }
    }
}

private struct FormField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure = false

    init(_ placeholder: String, text: Binding<String>, isSecure: Bool = false) {
        self.placeholder = placeholder
        self._text = text
        self.isSecure = isSecure
    }

    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(TM.textPrimary)
        .focused($focused)
        .padding(.horizontal, TM.cardContentHorizontal)
        .padding(.vertical, 10)
        .background(TM.fieldFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(focused ? TM.accent.opacity(0.6) : TM.border, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// 编辑页面的次级按钮：低透明填充 + 细描边。
private struct EditorSoftButton: View {
    let title: String
    var systemImage: String? = nil
    var prominent = false
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(prominent ? Color(hex: 0x191A1A) : (isEnabled ? TM.textPrimary : TM.textTertiary))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                prominent
                    ? Color(hex: 0xE9EBE8).opacity(isEnabled ? 1 : 0.5)
                    : (hovering ? TM.cardFillHover : TM.hoverFill),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(prominent ? .clear : (hovering ? TM.borderStrong : TM.border), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 认证方式

private struct AuthMethodSelection: View {
    @Binding var authMethod: Subscription.AuthMethod
    let platform: Platform
    @Binding var apiKey: String
    let oauthDevice: KimiDeviceAuthorization?
    let oauthStatus: String?
    let isAuthorizing: Bool
    let onStartOAuth: () -> Void
    let onCancelOAuth: () -> Void
    let isImportingBrowser: Bool
    let onStartEmbeddedLogin: () -> Void
    let onOpenURL: (URL) -> Void
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FlowLayout(spacing: 8) {
                AuthMethodChip(
                    title: "手动 API Key", icon: "key.fill", tint: TM.accent,
                    isSelected: authMethod == .manualAPIKey
                ) { authMethod = .manualAPIKey }

                if platform == .kimi {
                    AuthMethodChip(
                        title: "Kimi Code OAuth", icon: "lock.shield.fill", tint: .indigo,
                        isSelected: authMethod == .kimiOAuth
                    ) { authMethod = .kimiOAuth }
                    AuthMethodChip(
                        title: "网页登录态", icon: "globe", tint: .green,
                        isSelected: authMethod == .kimiBrowserSession
                    ) { authMethod = .kimiBrowserSession }
                }
            }

            Text(selectedMethodDetail)
                .font(.system(size: 11))
                .foregroundStyle(TM.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            switch authMethod {
            case .manualAPIKey:
                VStack(alignment: .leading, spacing: 7) {
                    FormField("API Key", text: $apiKey, isSecure: true)
                    Label("仅存储在本机的 TokenMeter 私有凭证文件中，并受文件权限保护", systemImage: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(TM.textTertiary)
                }
            case .kimiOAuth:
                VStack(alignment: .leading, spacing: 12) {
                    if let oauthDevice {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("用户码")
                                        .font(.system(size: 10, weight: .bold))
                                        .tracking(0.6)
                                        .foregroundStyle(TM.textTertiary)
                                    Text(oauthDevice.userCode)
                                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(TM.textPrimary)
                                }
                                Spacer()
                                EditorSoftButton(title: "复制用户码", systemImage: "doc.on.doc") {
                                    onCopy(oauthDevice.userCode)
                                }
                            }
                            Rectangle().fill(TM.divider).frame(height: 1)
                            HStack(spacing: 8) {
                                Text(oauthDevice.verificationURL.absoluteString)
                                    .font(.system(size: 10))
                                    .foregroundStyle(TM.textSecondary)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                                Spacer(minLength: 6)
                                EditorSoftButton(title: "复制链接", systemImage: "doc.on.doc") {
                                    onCopy(oauthDevice.verificationURL.absoluteString)
                                }
                                EditorSoftButton(title: "打开浏览器", systemImage: "safari", prominent: true) {
                                    onOpenURL(oauthDevice.verificationURL)
                                }
                            }
                        }
                        .padding(.horizontal, TM.cardContentHorizontal)
            .padding(.vertical, 14)
            .tmCard()
                    }
                    if let oauthStatus {
                        HStack(spacing: 8) {
                            if isAuthorizing {
                                ProgressView().controlSize(.small)
                            } else if oauthCredentialDone {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(TM.ok)
                                    .font(.system(size: 11))
                            }
                            Text(oauthStatus)
                                .font(.system(size: 11))
                                .foregroundStyle(TM.textSecondary)
                        }
                    }
                    EditorSoftButton(
                        title: isAuthorizing ? "取消授权" : "开始 Kimi Code OAuth 授权",
                        systemImage: isAuthorizing ? "xmark" : "lock.shield",
                        prominent: !isAuthorizing
                    ) {
                        if isAuthorizing { onCancelOAuth() } else { onStartOAuth() }
                    }
                    Text("实验性 Device OAuth，令牌不会显示在界面，只保存到 TokenMeter 本地私有文件。")
                        .font(.system(size: 10))
                        .foregroundStyle(TM.textTertiary)
                }
            case .kimiBrowserSession:
                VStack(alignment: .leading, spacing: 10) {
                    EditorSoftButton(
                        title: isImportingBrowser ? "正在登录…" : "登录 Kimi 账号",
                        systemImage: "person.crop.circle",
                        prominent: true
                    ) { onStartEmbeddedLogin() }
                    .disabled(isImportingBrowser)
                    if isImportingBrowser {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在获取 Kimi 登录态…")
                                .font(.system(size: 10))
                                .foregroundStyle(TM.textSecondary)
                        }
                    }
                    if let oauthStatus, !isImportingBrowser {
                        Label(oauthStatus, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(TM.ok)
                    }
                    Text("在内置窗口的 Kimi 官方页面完成登录，TokenMeter 只读取登录态。")
                        .font(.system(size: 10))
                        .foregroundStyle(TM.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var selectedMethodDetail: String {
        switch authMethod {
        case .manualAPIKey: "适用于所有平台"
        case .kimiOAuth: "实验性设备授权"
        case .kimiBrowserSession: "登录 Kimi 账号（内置）"
        }
    }

    private var oauthCredentialDone: Bool {
        oauthStatus?.contains("完成") == true || oauthStatus?.contains("导入") == true
    }
}

/// 认证方式选项 chip：图标 + 名称，选中态用平台色背景与对勾标记；副标题在 chips 下方统一展示。
private struct AuthMethodChip: View {
    let title: String
    let icon: String
    let tint: Color
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(tint)
                }
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? tint : TM.textSecondary)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? TM.textPrimary : TM.textSecondary)
            }
            .padding(.horizontal, TM.cardContentHorizontal)
            .padding(.vertical, 8)
            .background(
                isSelected ? tint.opacity(0.09) : (hovering ? TM.cardFillHover : TM.cardFill),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? tint.opacity(0.45) : (hovering ? TM.borderStrong : TM.border), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 流式布局：子视图按内容宽度依次排列，一行放不下时自动换行（类 Flex wrap）。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursorX > 0, cursorX + size.width > maxWidth {
                cursorX = 0
                cursorY += rowHeight + spacing
                rowHeight = 0
            }
            cursorX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let width = maxWidth.isFinite ? maxWidth : max(0, cursorX - spacing)
        return CGSize(width: width, height: max(0, cursorY + rowHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var cursorX = bounds.minX
        var cursorY = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursorX > bounds.minX, cursorX + size.width > bounds.maxX {
                cursorX = bounds.minX
                cursorY += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: cursorX, y: cursorY), anchor: .topLeading, proposal: .unspecified)
            cursorX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - 进度条颜色配置

/// 颜色目标：编辑页里每个可配置额度的稳定键、展示名与内置默认色。
/// `name` 与 `kind` 用于沿完整解析链（name → kind → generic → 内置默认）计算显示色，
/// 与概览页保持一致；overall 目标通过 `isOverall` 走 `resolveOverall`。
private struct QuotaColorTarget: Identifiable {
    let key: String
    let label: String
    let defaultColor: Color
    let name: String?
    let kind: Quota.Kind?
    let isOverall: Bool
    var id: String { key }

    init(
        key: String,
        label: String,
        defaultColor: Color,
        name: String? = nil,
        kind: Quota.Kind? = nil,
        isOverall: Bool = false
    ) {
        self.key = key
        self.label = label
        self.defaultColor = defaultColor
        self.name = name
        self.kind = kind
        self.isOverall = isOverall
    }

    /// 按平台与当前快照额度生成颜色目标列表；余额没有进度条，不参与配置。
    static func targets(platform: Platform, quotas: [Quota]) -> [QuotaColorTarget] {
        var result: [QuotaColorTarget] = []
        if platform == .kimi {
            result.append(QuotaColorTarget(
                key: SubscriptionQuotaColors.overallKey,
                label: "总使用量",
                defaultColor: SubscriptionQuotaColors.overallDefault,
                isOverall: true
            ))
        }
        let progressQuotas = quotas.filter { $0.kind != .balance }
        if progressQuotas.isEmpty {
            if platform == .kimi {
                result.append(QuotaColorTarget(
                    key: SubscriptionQuotaColors.fiveHourKey,
                    label: "5 小时额度",
                    defaultColor: SubscriptionQuotaColors.defaultColor(forKind: .fiveHour),
                    name: "5 小时额度",
                    kind: .fiveHour
                ))
                result.append(QuotaColorTarget(
                    key: SubscriptionQuotaColors.weeklyKey,
                    label: "每周额度",
                    defaultColor: SubscriptionQuotaColors.defaultColor(forKind: .weekly),
                    name: "每周额度",
                    kind: .weekly
                ))
            }
        } else {
            for quota in progressQuotas {
                result.append(QuotaColorTarget(
                    key: SubscriptionQuotaColors.nameKey(quota.name),
                    label: quota.name,
                    defaultColor: SubscriptionQuotaColors.defaultColor(forKind: quota.kind),
                    name: quota.name,
                    kind: quota.kind
                ))
            }
        }
        // 批量默认色：作用于所有未单独配置的额度窗口。
        result.append(QuotaColorTarget(
            key: SubscriptionQuotaColors.genericKey,
            label: "默认颜色",
            defaultColor: SubscriptionQuotaColors.defaultColor(forKind: .generic)
        ))
        return result
    }
}

/// 进度条颜色编辑列表：把 draft 的颜色字典绑定到每个颜色目标。
private struct QuotaColorEditor: View {
    @Binding var colors: [String: UInt32]
    let targets: [QuotaColorTarget]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(targets) { target in
                QuotaColorRow(
                    target: target,
                    colors: colors,
                    onSelect: { colors[target.key] = $0 },
                    onReset: { colors[target.key] = nil }
                )
            }
        }
    }
}

/// 单个颜色目标的紧凑配置行：名称、当前色样本、预设色、自定义选择器与实时预览。
private struct QuotaColorRow: View {
    let target: QuotaColorTarget
    let colors: [String: UInt32]
    let onSelect: (UInt32) -> Void
    let onReset: () -> Void

    private var rgb: UInt32? { colors[target.key] }

    /// 显示色沿完整解析链（name → kind → generic → 内置默认）计算，与概览页一致；
    /// generic 目标没有 name/kind，直接显示自身值或默认色。
    private var resolvedColor: Color {
        if target.isOverall {
            return SubscriptionQuotaColors.resolveOverall(colors)
        }
        if let name = target.name, let kind = target.kind {
            return SubscriptionQuotaColors.resolve(colors, name: name, kind: kind)
        }
        return rgb.map { Color(hex: $0) } ?? target.defaultColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Text(target.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TM.textPrimary)
                    .lineLimit(1)
                Circle()
                    .fill(resolvedColor)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(TM.borderStrong, lineWidth: 1))
                Spacer(minLength: 6)
                if rgb != nil {
                    Button("恢复默认", action: onReset)
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(TM.textSecondary)
                }
            }
            HStack(spacing: 6) {
                ForEach(SubscriptionQuotaColors.presets, id: \.self) { preset in
                    Button { onSelect(preset) } label: {
                        Circle()
                            .fill(Color(hex: preset))
                            .frame(width: 14, height: 14)
                            .overlay(
                                Circle().strokeBorder(
                                    rgb == preset ? TM.textPrimary : TM.border,
                                    lineWidth: rgb == preset ? 2 : 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("预设颜色")
                }
                ColorPicker("", selection: Binding(
                    get: { resolvedColor },
                    set: { onSelect($0.tokenMeterRGB) }
                ), supportsOpacity: false)
                .labelsHidden()
                .controlSize(.mini)
            }
            preview
        }
    }

    /// 小型实时预览：约 60% 的细轨道与同色百分比，直观展示进度条与百分比严格同色。
    private var preview: some View {
        HStack(spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(TM.meterTrack)
                    Capsule()
                        .fill(resolvedColor)
                        .frame(width: proxy.size.width * 0.6)
                }
            }
            .frame(height: 4)
            Text("60%")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(resolvedColor)
        }
    }
}
