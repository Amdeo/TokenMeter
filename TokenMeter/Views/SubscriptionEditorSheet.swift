import SwiftUI
import AppKit

// 订阅的添加/编辑窗口内容：编辑模式用分段切换「用量」与「设置」，
// 用量页复用 SubscriptionUsageView 与菜单栏面板相同的数据展示。
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
            if let subscription {
                editorHeader(subscription)
            } else {
                Text("连接账户，集中查看额度使用情况")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 18)
            }

            if segment == 0, let subscription {
                usagePane(subscription)
            } else {
                settingsPane
            }

            Spacer(minLength: 12)

            Divider()
            footer
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 18)
        .frame(width: 560)
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

    private func editorHeader(_ subscription: Subscription) -> some View {
        HStack(spacing: 10) {
            PlatformLogo(platform: subscription.platform, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(subscription.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(subscription.platform.rawValue) · \(subscription.authMethod.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            Picker("", selection: $segment) {
                Text("用量").tag(0)
                Text("设置").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
        }
        .padding(.bottom, 16)
    }

    private func usagePane(_ subscription: Subscription) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            if let snapshot = store.snapshots[subscription.id] {
                if let error = snapshot.errorMessage {
                    SnapshotStatePanel(snapshot: snapshot, message: error)
                } else {
                    SubscriptionUsageView(subscription: subscription, snapshot: snapshot, style: .full)
                }
                HStack {
                    Text("最近更新：\(snapshot.updatedAt.tokenMeterTimeText)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await store.refresh(subscription) }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("等待首次刷新…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("立即刷新") {
                        Task { await store.refresh(subscription) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.vertical, 34)
            }
        }
    }

    private var settingsPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            SheetSection(title: "选择平台", subtitle: "不同平台的额度接口与认证方式不同。") {
                PlatformSelection(platform: $platform)
                    .disabled(isEditing)
                Label(platform.capabilityDescription, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private var footer: some View {
        HStack {
            if isEditing {
                Button("删除订阅", role: .destructive) { showDeleteConfirmation = true }
                    .buttonStyle(.borderless)
            }
            Spacer()
            Button("取消") { onClose() }
                .keyboardShortcut(.cancelAction)
            Button(isEditing ? "保存修改" : "添加订阅") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave || oauthTask != nil)
        }
        .padding(.top, 14)
    }

    private var canSave: Bool {
        switch authMethod {
        case .manualAPIKey:
            if isEditing { return true }
            return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .kimiOAuth:
            if isEditing, oauthCredential == nil { return true }
            return oauthCredential != nil
        case .kimiBrowserSession:
            if isEditing, browserCredential == nil { return true }
            return browserCredential != nil
        }
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
        browserImportTask?.cancel()
        browserImportTask = nil
        browserCredential = nil
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
        browserImportTask?.cancel()
        message = nil
        browserImportTask = Task { @MainActor in
            do {
                let credential = try await Task.detached {
                    try await ChromeSessionImporter().importCredential()
                }.value
                browserCredential = credential
                oauthStatus = "已从 Chrome 导入 Kimi 网页登录态"
            } catch is CancellationError {
            } catch {
                message = error.localizedDescription
            }
            browserImportTask = nil
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct SheetSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
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

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct PlatformSelection: View {
    @Binding var platform: Platform

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(Platform.allCases) { item in
                Button { platform = item } label: {
                    HStack(spacing: 10) {
                        PlatformLogo(platform: item, size: 26)
                        Text(item.rawValue)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        if item == platform {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(item == platform ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(item == platform ? Color.accentColor.opacity(0.45) : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

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
                    isSelected: authMethod == .manualAPIKey
                ) { authMethod = .manualAPIKey }

                if platform == .kimi {
                    AuthOption(
                        title: "Kimi Code OAuth",
                        detail: "实验性设备授权",
                        icon: "lock.shield",
                        isSelected: authMethod == .kimiOAuth
                    ) { authMethod = .kimiOAuth }
                    AuthOption(
                        title: "网页登录态",
                        detail: "从 Chrome 导入",
                        icon: "globe",
                        isSelected: authMethod == .kimiBrowserSession
                    ) { authMethod = .kimiBrowserSession }
                }
            }

            switch authMethod {
            case .manualAPIKey:
                FormField("API Key", text: $apiKey, isSecure: true)
            case .kimiOAuth:
                VStack(alignment: .leading, spacing: 10) {
                    if let oauthDevice {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("用户码").font(.caption).foregroundStyle(.secondary)
                                Text(oauthDevice.userCode).font(.title3.monospaced().weight(.semibold))
                            }
                            Spacer()
                            Button("复制用户码") { onCopy(oauthDevice.userCode) }
                                .buttonStyle(.bordered)
                        }
                        HStack {
                            Text(oauthDevice.verificationURL.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Spacer()
                            Button("复制链接") { onCopy(oauthDevice.verificationURL.absoluteString) }
                                .buttonStyle(.bordered)
                            Button("打开") { onOpenURL(oauthDevice.verificationURL) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    if let oauthStatus {
                        HStack(spacing: 8) {
                            if isAuthorizing { ProgressView().controlSize(.small) }
                            Text(oauthStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button(isAuthorizing ? "取消授权" : "开始 Kimi Code OAuth 授权") {
                        if isAuthorizing { onCancelOAuth() } else { onStartOAuth() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    Text("实验性 Device OAuth，令牌不会显示在界面，只保存到 TokenMeter 本地私有文件。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .kimiBrowserSession:
                VStack(alignment: .leading, spacing: 10) {
                    Button(isImportingBrowser ? "正在从 Chrome 导入…" : "从 Chrome 导入 Kimi 登录态", action: onImportBrowser)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(isImportingBrowser)
                    Text("TokenMeter 只读取当前 Kimi 页面 localStorage 中的登录态，不读取 Cookies 或钥匙串。首次使用需要允许 TokenMeter 控制 Chrome。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct AuthOption: View {
    let title: String
    let detail: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: icon).foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(isSelected ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
