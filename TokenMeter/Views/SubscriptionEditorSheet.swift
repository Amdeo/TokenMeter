import SwiftUI
import AppKit

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

    @MainActor
    private var providerDefinition: any ProviderDefinition {
        ProviderRegistry.definition(for: draft.providerID) ?? UnsupportedProviderDefinition(providerID: draft.providerID)
    }

    /// 当前选中的认证方式定义；缺失时退回 API Key 形态。
    @MainActor
    private var selectedAuthMethod: AuthMethodDefinition? {
        providerDefinition.authMethods.first { $0.id == draft.authMethodID }
    }

    @MainActor
    private var authFlowID: AuthFlowID {
        selectedAuthMethod?.flowID ?? .apiKey
    }

    private var quotaColorTargets: [QuotaColorTarget] {
        let snapshot = subscription.flatMap { store.snapshots[$0.id] }
        return QuotaColorTarget.targets(providerID: draft.providerID, quotas: snapshot?.quotas ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                definition: providerDefinition,
                title: providerDefinition.metadata.displayName,
                subtitle: "配置订阅",
                onBack: attemptClose
            )
            if let homepageURL = providerDefinition.metadata.homepageURL {
                OfficialSiteLink(host: homepageURL.host() ?? homepageURL.absoluteString) { openURL(homepageURL) }
                    .padding(.bottom, 8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SheetSection(title: "订阅信息", subtitle: "名称仅用于本地识别，可稍后修改。") {
                        FormField("名称（可选）", text: $draft.name)
                    }
                    SheetSection(title: "认证方式", subtitle: "凭证只会写入 TokenMeter 本地私有文件，不会保存到订阅元数据。") {
                        AuthMethodSelection(
                            authMethods: providerDefinition.authMethods,
                            authMethod: $draft.authMethodID,
                            providerID: draft.providerID,
                            apiKey: $draft.apiKey,
                            oauthDevice: draft.oauthDevice,
                            oauthStatus: draft.oauthStatus,
                            oauthCodeState: draft.oauthCodeAuthorizationState,
                            oauthCredential: draft.oauthCredential,
                            isAuthorizing: draft.oauthTask != nil,
                            onStartOAuth: startOAuth,
                            onCancelOAuth: cancelOAuth,
                            isImportingBrowser: draft.browserImportTask != nil,
                            onStartEmbeddedLogin: { startEmbeddedLogin() },
                            onSwitchBrowserAccount: { startEmbeddedLogin(switchingAccount: true) },
                            oauthCodeAuthorizeURL: draft.oauthCodeAuthorizeURL,
                            oauthCodeInput: $draft.oauthCodeInput,
                            onCompleteOAuthCode: completeOAuthCode,
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
            .scrollIndicators(.hidden)
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
        .onChange(of: draft.authMethodID) { _, _ in
            draft.clearAuthenticationState()
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
        AuthFlowRegistry.canSave(
            originalAuthMethodID: subscription?.authMethodID,
            selected: draft.authMethodID,
            flowID: authFlowID,
            draft: draft
        )
    }

    private func attemptClose() { if draft.isDirty { showDiscardConfirmation = true } else { onClose() } }
    private func save() { subscription.map { saveEditing($0) } ?? saveNew() }

    private func saveNew() {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let subscription = Subscription(
            providerID: draft.providerID,
            name: trimmedName.isEmpty ? providerDefinition.metadata.displayName : trimmedName,
            authMethodID: draft.authMethodID,
            quotaColors: draft.quotaColors
        )
        do {
            try saveCredential(for: subscription.id)
            store.add(subscription)
            guard let persistenceError = store.lastPersistenceError else {
                onClose()
                store.refresh(subscription)
                return
            }
            draft.message = persistenceError
        } catch { draft.message = error.localizedDescription }
    }

    /// 依次写入认证方式、名称与颜色；任一步落盘失败就停在原地并提示，不继续往下写。
    private func saveEditing(_ subscription: Subscription) {
        guard canSave else { draft.message = "切换认证方式后，请先提供对应的新凭证。"; return }
        do {
            store.invalidateRefresh(for: subscription)
            try saveCredential(for: subscription.id)
        } catch {
            draft.message = error.localizedDescription
            return
        }

        var updated = subscription
        if subscription.authMethodID != draft.authMethodID {
            store.updateAuthMethod(subscription, to: draft.authMethodID)
            if let persistenceError = store.lastPersistenceError {
                draft.message = persistenceError
                return
            }
            updated.authMethodID = draft.authMethodID
        }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != subscription.name {
            store.rename(subscription, to: name)
            if let persistenceError = store.lastPersistenceError {
                draft.message = persistenceError
                return
            }
            updated.name = name
        }
        if draft.quotaColors != subscription.quotaColors {
            store.updateQuotaColors(draft.quotaColors, for: subscription)
            if let persistenceError = store.lastPersistenceError {
                draft.message = persistenceError
                return
            }
            updated.quotaColors = draft.quotaColors
        }

        onClose()
        store.refresh(updated)
    }

    private func saveCredential(for id: UUID) throws {
        try AuthFlowRegistry.saveCredential(for: id, flowID: authFlowID, draft: draft)
    }

    private func deleteSubscription() { guard let subscription else { return }; store.remove(subscription); onClose() }
    private func resetOAuthState() { draft.clearOAuthAuthentication() }
    private func cancelOAuth() { resetOAuthState() }

    private func startOAuth() {
        if authFlowID == .oauthCode { startCodeOAuth(); return }
        guard let handler = selectedAuthMethod?.deviceAuthorization else {
            draft.message = "该认证方式未声明设备授权实现。"
            return
        }
        resetOAuthState(); let sessionID = draft.oauthSessionID; draft.oauthStatus = "正在请求设备授权…"; draft.message = nil
        draft.oauthTask = Task { @MainActor in
            do {
                let credential = try await handler.authorize { device in
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

    /// 授权码流程：复用尚未兑换的 PKCE（重复点击不会作废已完成的授权），否则新建。
    private func startCodeOAuth() {
        draft.message = nil
        guard draft.oauthCodeAuthorizationState != .exchanging else { return }
        if let url = draft.oauthCodeAuthorizeURL {
            openURL(url)
            return
        }
        guard let handler = selectedAuthMethod?.authorizationCode else {
            draft.message = "该认证方式未声明授权码实现。"
            return
        }
        let request = handler.begin()
        draft.oauthCodeVerifier = request.verifier
        draft.oauthCodeState = request.state
        draft.oauthCodeAuthorizeURL = request.url
        draft.oauthCredential = nil
        draft.oauthStatus = Self.codeOAuthPendingStatus
        openURL(request.url)
    }

    /// 把用户粘贴的授权码/回调地址兑换成令牌。
    private func completeOAuthCode() {
        guard draft.oauthCodeAuthorizationState == .awaitingCallback,
              let verifier = draft.oauthCodeVerifier,
              let state = draft.oauthCodeState
        else {
            draft.message = "请先点「打开授权页面」开始授权。"
            return
        }
        guard let handler = selectedAuthMethod?.authorizationCode else {
            draft.message = "该认证方式未声明授权码实现。"
            return
        }
        let input = draft.oauthCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        let sessionID = draft.oauthSessionID
        let providerName = providerDefinition.metadata.displayName
        draft.message = nil
        draft.oauthStatus = "正在用授权码换取令牌…"
        draft.oauthTask = Task { @MainActor in
            do {
                let credential = try await handler.complete(input, verifier, state)
                guard sessionID == draft.oauthSessionID else { return }
                draft.oauthCredential = credential
                draft.oauthCodeInput = ""
                draft.oauthStatus = "已完成 \(providerName) 授权"
            } catch is CancellationError {
            } catch {
                guard sessionID == draft.oauthSessionID else { return }
                draft.oauthStatus = Self.codeOAuthPendingStatus
                draft.message = error.localizedDescription
            }
            guard sessionID == draft.oauthSessionID else { return }
            draft.oauthTask = nil
        }
    }

    private static let codeOAuthPendingStatus = "已在浏览器打开授权页面；完成后把地址栏整段地址粘贴到下方。"

    private func startEmbeddedLogin(switchingAccount: Bool = false) {
        // 登录配置由认证方式自己声明。缺失时明确报错，不再静默退回 Kimi 的配置。
        guard let recipe = selectedAuthMethod?.loginRecipe else {
            draft.message = "该认证方式未声明网页登录配置，无法使用内置登录。"
            return
        }
        draft.clearOAuthAuthentication(); draft.leaveBrowserAuthentication(); let sessionID = draft.browserImportSessionID; draft.message = nil
        draft.browserImportTask = Task { @MainActor in
            do {
                let controller = EmbeddedWebLoginController(configuration: .browserLogin(recipe))
                // 切换账号：先清除该供应商域名的内置浏览器会话，登录页回到未登录态。
                if switchingAccount {
                    await BrowserSessionSiteData.clear(domains: controller.sessionDomains)
                }
                let credential = try await controller.login()
                // 以 Provider 定义驱动：凡是 flowID 为 browserSession 的认证方式
                // 都走内置浏览器登录，新增浏览器型供应商时无需改这里。
                let isBrowserFlow = authFlowID == .browserSession
                guard sessionID == draft.browserImportSessionID, isBrowserFlow else { return }
                switch credential {
                case .token(let tokenCredential): draft.browserCredential = tokenCredential
                case .cookie(let cookieCredential): draft.cookieCredential = cookieCredential
                }
                draft.oauthStatus = "已通过内置登录导入网页登录态"
            } catch is CancellationError {} catch { guard sessionID == draft.browserImportSessionID else { return }; draft.message = error.localizedDescription }
            guard sessionID == draft.browserImportSessionID else { return }; draft.browserImportTask = nil
        }
    }

    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
}

private struct PageHeader: View {
    let definition: any ProviderDefinition
    let title: String
    let subtitle: String
    let onBack: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            HeaderIconButton(systemName: "chevron.left", label: "返回概览", action: onBack)
            PlatformLogo(definition: definition, size: 34)
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

/// 官网链接行：点击用系统浏览器打开供应商官网首页（仅当 metadata.homepageURL 存在时展示）。
private struct OfficialSiteLink: View {
    let host: String
    let open: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                    .font(.system(size: 10, weight: .semibold))
                Text(host)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(hovering ? TM.accent : TM.textSecondary)
            .padding(.horizontal, TM.cardContentHorizontal)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? TM.cardFillHover : TM.hoverFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("打开官网 \(host)")
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
    let authMethods: [AuthMethodDefinition]
    @Binding var authMethod: AuthMethodID
    let providerID: ProviderID
    @Binding var apiKey: String
    let oauthDevice: DeviceOAuthAuthorization?
    let oauthStatus: String?
    let oauthCodeState: OAuthAuthorizationState
    let oauthCredential: OAuthCredential?
    let isAuthorizing: Bool
    let onStartOAuth: () -> Void
    let onCancelOAuth: () -> Void
    let isImportingBrowser: Bool
    let onStartEmbeddedLogin: () -> Void
    let onSwitchBrowserAccount: () -> Void
    let oauthCodeAuthorizeURL: URL?
    @Binding var oauthCodeInput: String
    let onCompleteOAuthCode: () -> Void
    let onOpenURL: (URL) -> Void
    let onCopy: (String) -> Void

    private var selectedFlowID: AuthFlowID {
        authMethods.first { $0.id == authMethod }?.flowID ?? .apiKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FlowLayout(spacing: 8) {
                ForEach(authMethods) { method in
                    AuthMethodChip(
                        title: method.title,
                        icon: method.systemImage,
                        tint: method.tintRGB.map { Color(hex: $0) } ?? TM.accent,
                        isSelected: authMethod == method.id
                    ) { authMethod = method.id }
                }
            }

            Text(selectedMethodDetail)
                .font(.system(size: 11))
                .foregroundStyle(TM.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            switch selectedFlowID {
            case .apiKey:
                VStack(alignment: .leading, spacing: 7) {
                    FormField("API Key", text: $apiKey, isSecure: true)
                    Label("仅存储在本机的 TokenMeter 私有凭证文件中，并受文件权限保护", systemImage: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(TM.textTertiary)
                }
            case .deviceOAuth:
                deviceOAuthForm
            case .oauthCode:
                oauthCodeForm
            case .browserSession:
                browserSessionForm
            }
        }
    }

    @ViewBuilder
    private var deviceOAuthForm: some View {
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
                title: isAuthorizing ? "取消授权" : "开始设备授权",
                systemImage: isAuthorizing ? "xmark" : "lock.shield",
                prominent: !isAuthorizing
            ) {
                if isAuthorizing { onCancelOAuth() } else { onStartOAuth() }
            }
            Text("实验性 Device OAuth，令牌不会显示在界面，只保存到 TokenMeter 本地私有文件。")
                .font(.system(size: 10))
                .foregroundStyle(TM.textTertiary)
        }
    }

    // ponytail: 无本地回调监听，授权码需手动粘贴一次。升级：粘贴体验被反馈麻烦时，加 54545 端口监听自动回填。
    @ViewBuilder
    private var oauthCodeForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                EditorSoftButton(
                    title: oauthCodeState == .idle ? "打开授权页面" : "重新打开授权页面",
                    systemImage: "safari",
                    prominent: true
                ) { onStartOAuth() }
                .disabled(oauthCodeState == .exchanging)
                if let url = oauthCodeAuthorizeURL {
                    EditorSoftButton(title: "复制链接", systemImage: "doc.on.doc") {
                        onCopy(url.absoluteString)
                    }
                }
            }
            if let oauthStatus {
                HStack(spacing: 8) {
                    if oauthCodeState == .exchanging {
                        ProgressView().controlSize(.small)
                    } else if oauthCodeState == .completed {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(TM.ok)
                            .font(.system(size: 11))
                    }
                    Text(oauthStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(TM.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if oauthCodeState == .awaitingCallback || oauthCodeState == .exchanging {
                VStack(alignment: .leading, spacing: 7) {
                    FormField("粘贴授权码或回调地址", text: $oauthCodeInput)
                        .disabled(oauthCodeState == .exchanging)
                    EditorSoftButton(title: "使用授权码完成", systemImage: "checkmark", prominent: true) {
                        onCompleteOAuthCode()
                    }
                    .disabled(oauthCodeState != .awaitingCallback || oauthCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Text("授权页会跳转到本机回调地址而无法打开，这是预期行为：请把浏览器地址栏里的整段地址复制回来。令牌只写入 TokenMeter 本地私有文件。")
                .font(.system(size: 10))
                .foregroundStyle(TM.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var browserSessionForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                EditorSoftButton(
                    title: isImportingBrowser ? "正在登录…" : "登录账号",
                    systemImage: "person.crop.circle",
                    prominent: true
                ) { onStartEmbeddedLogin() }
                .disabled(isImportingBrowser)
                EditorSoftButton(
                    title: "切换账号",
                    systemImage: "person.2"
                ) { onSwitchBrowserAccount() }
                .disabled(isImportingBrowser)
            }
            if isImportingBrowser {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在获取登录态…")
                        .font(.system(size: 10))
                        .foregroundStyle(TM.textSecondary)
                }
            }
            if let oauthStatus, !isImportingBrowser {
                Label(oauthStatus, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(TM.ok)
            }
            Text("在内置窗口的官方页面完成登录，TokenMeter 只读取登录态。已登录时窗口会自动完成；如需换号，点「切换账号」先清除已保存的网页登录。")
                .font(.system(size: 10))
                .foregroundStyle(TM.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selectedMethodDetail: String {
        authMethods.first { $0.id == authMethod }?.detail
            ?? "适用于所有平台"
    }

    private var oauthCredentialDone: Bool {
        oauthCredential != nil
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
