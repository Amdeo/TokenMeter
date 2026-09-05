import SwiftUI
import AppKit

// 订阅的添加/编辑窗口内容：编辑模式用分段切换「用量」与「设置」，
// 用量页复用 SubscriptionUsageView 与菜单栏面板相同的数据展示。
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
    let subscription: Subscription?
    let onClose: () -> Void

    @State private var segment = 0
    @State private var platform: Platform = .deepSeek
    @State private var authMethod: Subscription.AuthMethod = .manualAPIKey
    @State private var name = ""
    @State private var apiKey = ""
    @State private var oauthCredential: OAuthCredential?
    @State private var browserCredential: KimiBrowserCredential?
    @State private var oauthDevice: KimiDeviceAuthorization?
    @State private var oauthStatus: String?
    @State private var oauthTask: Task<Void, Never>?
    @State private var browserImportTask: Task<Void, Never>?
    @State private var browserImportSessionID = UUID()
    @State private var oauthSessionID = UUID()
    @State private var message: String?
    @State private var showDeleteConfirmation = false

    init(subscription: Subscription? = nil, onClose: @escaping () -> Void = {}) {
        self.subscription = subscription
        self.onClose = onClose
        _platform = State(initialValue: subscription?.platform ?? .deepSeek)
        _authMethod = State(initialValue: subscription?.authMethod ?? .manualAPIKey)
        _name = State(initialValue: subscription?.name ?? "")
    }

    private var isEditing: Bool { subscription != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Rectangle().fill(TM.divider).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if segment == 0, let subscription {
                        usagePane(subscription)
                    } else {
                        settingsPane
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
            .scrollIndicators(.hidden)

            Rectangle().fill(TM.divider).frame(height: 1)
            footer
        }
        .frame(width: 600)
        .background(TM.editorBackground)
        .foregroundStyle(TM.textPrimary)
        .onChange(of: platform) { _, newValue in
            resetCredentialState()
            message = nil
            if newValue != .kimi {
                authMethod = .manualAPIKey
            }
        }
        .onChange(of: authMethod) { _, newValue in
            if newValue != .kimiOAuth { oauthStatus = nil }
            if newValue != .kimiBrowserSession { browserCredential = nil }
            if newValue != .kimiOAuth { resetOAuthState() }
        }
        .onDisappear {
            resetCredentialState()
        }
        .alert("删除订阅", isPresented: $showDeleteConfirmation) {
            Button("删除", role: .destructive) { deleteSubscription() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除「\(subscription?.name ?? "")」的订阅与本地凭证，此操作不可撤销。")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            if let subscription {
                PlatformLogo(platform: subscription.platform, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(subscription.name)
                        .font(.system(size: 16, weight: .semibold))
                        .tracking(-0.3)
                        .lineLimit(1)
                    Text("\(subscription.platform.rawValue) · \(subscription.authMethod.label)")
                        .font(.system(size: 11))
                        .foregroundStyle(TM.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 10)
                Picker("", selection: $segment) {
                    Text("用量").tag(0)
                    Text("设置").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                .accessibilityLabel("切换用量与设置")
            } else {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TM.accent)
                    .frame(width: 36, height: 36)
                    .background(TM.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(TM.accent.opacity(0.28), lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    Text("添加订阅")
                        .font(.system(size: 16, weight: .semibold))
                        .tracking(-0.3)
                    Text("连接账户，集中查看额度使用情况")
                        .font(.system(size: 11))
                        .foregroundStyle(TM.textSecondary)
                }
                Spacer(minLength: 10)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.018))
    }

    // MARK: - 用量页

    private func usagePane(_ subscription: Subscription) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let snapshot = store.snapshots[subscription.id] {
                if let error = snapshot.errorMessage {
                    SnapshotStatePanel(snapshot: snapshot, message: error)
                } else {
                    SubscriptionUsageView(subscription: subscription, snapshot: snapshot, style: .full)
                }
                HStack {
                    HStack(spacing: 5) {
                        Circle().fill(snapshot.state == .realtime ? TM.ok : TM.warn).frame(width: 6, height: 6)
                        Text("最近更新：\(snapshot.updatedAt.tokenMeterTimeText)")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(TM.textSecondary)
                    Spacer()
                    EditorSoftButton(title: "刷新", systemImage: "arrow.clockwise") {
                        Task { await store.refresh(subscription) }
                    }
                    .disabled(store.isRefreshing)
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.regular)
                    Text("等待首次刷新…")
                        .font(.system(size: 11))
                        .foregroundStyle(TM.textSecondary)
                    EditorSoftButton(title: "立即刷新", systemImage: "arrow.clockwise") {
                        Task { await store.refresh(subscription) }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            }
        }
    }

    // MARK: - 设置页

    private var settingsPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetSection(title: "选择平台", subtitle: "不同平台的额度接口与认证方式不同。") {
                PlatformSelection(platform: $platform)
                    .disabled(isEditing)
                    .opacity(isEditing ? 0.55 : 1)
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                    Text(platform.capabilityDescription)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 10))
                .foregroundStyle(TM.textSecondary)
            }

            SheetSection(title: "订阅信息", subtitle: "名称仅用于本地识别，可稍后重命名。") {
                FormField("名称（可选）", text: $name)
            }

            SheetSection(title: "认证方式", subtitle: "凭证只会写入 TokenMeter 本地私有文件，不会保存到订阅元数据。") {
                AuthMethodSelection(
                    authMethod: $authMethod,
                    platform: platform,
                    apiKey: $apiKey,
                    oauthDevice: oauthDevice,
                    oauthStatus: oauthStatus,
                    isAuthorizing: oauthTask != nil,
                    onStartOAuth: startOAuth,
                    onCancelOAuth: cancelOAuth,
                    isImportingBrowser: browserImportTask != nil,
                    onImportBrowser: importBrowserSession,
                    onOpenURL: { openURL($0) },
                    onCopy: copy
                )
            }

            if let message {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11))
                .foregroundStyle(TM.warn)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TM.warn.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(TM.warn.opacity(0.22), lineWidth: 1))
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if isEditing {
                Button(role: .destructive) { showDeleteConfirmation = true } label: {
                    Text("删除订阅")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TM.danger)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("删除订阅与本地凭证")
            }
            Spacer()
            Button("取消") { onClose() }
                .font(.system(size: 12))
                .keyboardShortcut(.cancelAction)
            Button(isEditing ? "保存修改" : "添加订阅") { save() }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave || oauthTask != nil || browserImportTask != nil)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
        .background(Color.black.opacity(0.08))
    }

    // MARK: - 保存 / 删除 / 认证逻辑（保持不变）

    private var canSave: Bool {
        SubscriptionCredentialRequirement.canSave(
            original: subscription?.authMethod,
            selected: authMethod,
            apiKey: apiKey,
            hasOAuthCredential: oauthCredential != nil,
            hasBrowserCredential: browserCredential != nil,
            isImportingBrowser: browserImportTask != nil
        )
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let subscription {
            saveEditing(subscription, trimmedName: trimmedName)
        } else {
            saveNew(trimmedName: trimmedName)
        }
    }

    private func saveNew(trimmedName: String) {
        let subscription = Subscription(
            id: UUID(),
            platform: platform,
            name: trimmedName.isEmpty ? platform.rawValue : trimmedName,
            authMethod: authMethod
        )
        do {
            switch authMethod {
            case .manualAPIKey:
                try CredentialStore().save(apiKey: apiKey, for: subscription.id)
            case .kimiOAuth:
                guard let oauthCredential else { return }
                try CredentialStore().save(oauthCredential: oauthCredential, for: subscription.id)
            case .kimiBrowserSession:
                guard let browserCredential else { return }
                try CredentialStore().save(browserCredential: browserCredential, for: subscription.id)
            }
            store.add(subscription)
            onClose()
            Task { await store.refresh(subscription) }
        } catch {
            message = error.localizedDescription
        }
    }

    private func saveEditing(_ subscription: Subscription, trimmedName: String) {
        guard canSave else {
            message = browserImportTask != nil
                ? "正在从 Chrome 导入登录态，请完成后再保存。"
                : "切换认证方式后，请先提供对应的新凭证。"
            return
        }
        do {
            switch authMethod {
            case .manualAPIKey:
                let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty {
                    try CredentialStore().save(apiKey: key, for: subscription.id)
                }
            case .kimiOAuth:
                if let oauthCredential {
                    try CredentialStore().save(oauthCredential: oauthCredential, for: subscription.id)
                }
            case .kimiBrowserSession:
                if let browserCredential {
                    try CredentialStore().save(browserCredential: browserCredential, for: subscription.id)
                }
            }
            var updated = subscription
            if subscription.authMethod != authMethod {
                store.updateAuthMethod(subscription, to: authMethod)
                updated.authMethod = authMethod
            }
            if subscription.name != trimmedName, !trimmedName.isEmpty {
                store.rename(subscription, to: trimmedName)
                updated.name = trimmedName
            }
            onClose()
            Task { await store.refresh(updated) }
        } catch {
            message = error.localizedDescription
        }
    }

    private func deleteSubscription() {
        guard let subscription else { return }
        store.remove(subscription)
        onClose()
    }

    private func resetCredentialState() {
        resetOAuthState()
        invalidateBrowserImport()
        browserCredential = nil
    }

    private func invalidateBrowserImport() {
        browserImportSessionID = UUID()
        browserImportTask?.cancel()
        browserImportTask = nil
    }

    private func resetOAuthState() {
        oauthSessionID = UUID()
        oauthTask?.cancel()
        oauthTask = nil
        oauthCredential = nil
        oauthDevice = nil
        oauthStatus = nil
    }

    private func startOAuth() {
        resetOAuthState()
        let sessionID = oauthSessionID
        oauthStatus = "正在请求设备授权…"
        message = nil
        oauthTask = Task { @MainActor in
            do {
                let credential = try await KimiOAuthService().authorize { device in
                    await MainActor.run {
                        guard sessionID == oauthSessionID else { return }
                        oauthDevice = device
                        oauthStatus = "请在浏览器中完成授权，TokenMeter 会自动等待结果。"
                    }
                }
                guard sessionID == oauthSessionID else { return }
                oauthCredential = credential
                oauthStatus = "已完成官方授权"
            } catch is CancellationError {
            } catch {
                guard sessionID == oauthSessionID else { return }
                oauthStatus = nil
                message = error.localizedDescription
            }
            guard sessionID == oauthSessionID else { return }
            oauthTask = nil
        }
    }

    private func cancelOAuth() {
        resetOAuthState()
    }

    private func importBrowserSession() {
        resetOAuthState()
        invalidateBrowserImport()
        let sessionID = browserImportSessionID
        message = nil
        browserImportTask = Task { @MainActor in
            do {
                let credential = try await Task.detached {
                    try await ChromeSessionImporter().importCredential()
                }.value
                guard sessionID == browserImportSessionID, authMethod == .kimiBrowserSession else { return }
                browserCredential = credential
                oauthStatus = "已从 Chrome 导入 Kimi 网页登录态"
            } catch is CancellationError {
            } catch {
                guard sessionID == browserImportSessionID, authMethod == .kimiBrowserSession else { return }
                message = error.localizedDescription
            }
            guard sessionID == browserImportSessionID, authMethod == .kimiBrowserSession else { return }
            browserImportTask = nil
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(TM.fieldFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(focused ? TM.accent.opacity(0.6) : TM.border, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// 编辑窗口的次级按钮：低透明填充 + 细描边。
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
                    : Color.white.opacity(hovering ? 0.11 : 0.07),
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

// MARK: - 平台选择

private struct PlatformSelection: View {
    @Binding var platform: Platform
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(Platform.allCases) { item in
                PlatformCard(item: item, isSelected: item == platform) {
                    withAnimation(reduceMotion ? .none : .easeOut(duration: 0.15)) { platform = item }
                }
            }
        }
    }
}

private struct PlatformCard: View {
    let item: Platform
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                PlatformLogo(platform: item, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TM.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(item.tint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                isSelected ? item.tint.opacity(0.09) : (hovering ? TM.cardFillHover : TM.cardFill),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(isSelected ? item.tint.opacity(0.45) : (hovering ? TM.borderStrong : TM.border), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(item.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
    let onImportBrowser: () -> Void
    let onOpenURL: (URL) -> Void
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                AuthOption(
                    title: "手动 API Key",
                    detail: "适用于所有平台",
                    icon: "key.fill",
                    tint: TM.accent,
                    isSelected: authMethod == .manualAPIKey
                ) { authMethod = .manualAPIKey }

                if platform == .kimi {
                    AuthOption(
                        title: "Kimi Code OAuth",
                        detail: "实验性设备授权",
                        icon: "lock.shield.fill",
                        tint: .indigo,
                        isSelected: authMethod == .kimiOAuth
                    ) { authMethod = .kimiOAuth }
                    AuthOption(
                        title: "网页登录态",
                        detail: "从 Chrome 导入",
                        icon: "globe",
                        tint: .green,
                        isSelected: authMethod == .kimiBrowserSession
                    ) { authMethod = .kimiBrowserSession }
                }
            }

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
                        .padding(14)
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
                        title: isImportingBrowser ? "正在从 Chrome 导入…" : "从 Chrome 导入 Kimi 登录态",
                        systemImage: "globe",
                        prominent: true
                    ) { onImportBrowser() }
                    .disabled(isImportingBrowser)
                    if isImportingBrowser {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("请保持 Kimi 页面处于打开状态")
                                .font(.system(size: 10))
                                .foregroundStyle(TM.textSecondary)
                        }
                    }
                    if let oauthStatus, !isImportingBrowser {
                        Label(oauthStatus, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(TM.ok)
                    }
                    Text("TokenMeter 只读取当前 Kimi 页面 localStorage 中的登录态，不读取 Cookies 或系统钥匙串。首次使用需要允许 TokenMeter 控制 Chrome。")
                        .font(.system(size: 10))
                        .foregroundStyle(TM.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var oauthCredentialDone: Bool {
        oauthStatus?.contains("完成") == true || oauthStatus?.contains("导入") == true
    }
}

private struct AuthOption: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? tint : TM.textSecondary)
                    .frame(width: 30, height: 30)
                    .background((isSelected ? tint : Color.white).opacity(isSelected ? 0.13 : 0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TM.textPrimary)
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(TM.textTertiary)
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(tint)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? tint.opacity(0.08) : (hovering ? TM.cardFillHover : TM.cardFill),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(isSelected ? tint.opacity(0.4) : (hovering ? TM.borderStrong : TM.border), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
