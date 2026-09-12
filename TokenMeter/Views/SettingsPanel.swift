import SwiftUI

// 设置面板（TM-02）：从 MenuBarView 抽出的独立页面，设计令牌与组件见 MenuBarView.swift。

// MARK: - 设置页

struct SettingsPanel: View {
    @Bindable var settings: SettingsStore
    let onBack: () -> Void
    let onMigration: () -> Void
    let migrationRecoveryError: String?
    let persistenceError: String?
    let onPreview: () -> Void

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderIconButton(systemName: "chevron.left", label: "返回概览", action: onBack)

            VStack(alignment: .leading, spacing: 3) {
                Text("设置")
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.5)
                Text("TokenMeter 偏好设置")
                    .font(.system(size: 11))
                    .foregroundStyle(TM.textSecondary)
            }
            .padding(.top, 10)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    settingsSection("通用", footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(settings.loginItemStatus.label)
                                    .font(.system(size: 10))
                                    .foregroundStyle(TM.textTertiary)
                                Spacer()
                                Button("刷新状态") { settings.refreshLoginItemStatus() }
                                    .font(.system(size: 10))
                                    .foregroundStyle(TM.accent)
                                    .buttonStyle(.plain)
                            }
                            if let error = settings.loginItemError {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(TM.danger)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }) {
                        settingsToggle("登录时启动", isOn: Binding(
                            get: { settings.launchAtLogin },
                            set: { settings.setLaunchAtLogin($0) }
                        ))
                        settingsToggle("打开时刷新", isOn: $settings.refreshOnOpen)
                        settingsToggle("后台自动刷新", isOn: $settings.autoRefreshEnabled)
                        appearanceRow()
                        refreshIntervalRow()
                    }

                    settingsSection("通知", footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(settings.notificationStatus == .authorized ? TM.ok : TM.warn)
                                    .frame(width: 6, height: 6)
                                Text(settings.notificationStatusLabel)
                                    .font(.system(size: 10))
                                    .foregroundStyle(TM.textSecondary)
                                Spacer()
                                if settings.notificationStatus == .notDetermined {
                                    Button("允许通知") { settings.requestNotificationsIfNeeded() }
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(TM.accent)
                                        .buttonStyle(.plain)
                                } else if settings.notificationStatus == .denied {
                                    Button("前往系统设置") { settings.openNotificationSettings() }
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(TM.accent)
                                        .buttonStyle(.plain)
                                        .help("打开系统通知设置")
                                }
                            }
                            if settings.notificationStatus == .denied {
                                Text("请在 系统设置 → 通知 → TokenMeter 中开启。")
                                    .font(.system(size: 10))
                                    .foregroundStyle(TM.textTertiary)
                            }
                        }
                    }) {
                        settingsToggle("余额偏低提醒", isOn: $settings.lowBalanceAlerts)
                        settingsToggle("认证过期提醒", isOn: $settings.authenticationAlerts)
                        settingsToggle("服务错误提醒", isOn: $settings.serviceErrorAlerts, isLast: true)
                    }

                    settingsSection("余额阈值") {
                        thresholdRow("CNY", value: $settings.cnyBalanceThreshold)
                        thresholdRow("USD", value: $settings.usdBalanceThreshold, isLast: true)
                    }

                    if let persistenceError {
                        Label(persistenceError, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(TM.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    settingsSection("数据迁移", footer: {
                        if let migrationRecoveryError {
                            Label(migrationRecoveryError, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(TM.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }) {
                        Button(action: onMigration) {
                            HStack {
                                Image(systemName: "arrow.left.arrow.right")
                                    .font(.system(size: 12))
                                    .foregroundStyle(TM.accent)
                                Text("导入或导出凭据迁移包")
                                    .font(.system(size: 12))
                                    .foregroundStyle(TM.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(TM.textTertiary)
                            }
                            .padding(.horizontal, TM.cardContentHorizontal)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("导入或导出订阅配置和私有凭据")
                    }

                    #if DEBUG
                    settingsSection("开发者") {
                        Button(action: onPreview) {
                            HStack {
                                Text("预览状态")
                                    .font(.system(size: 12))
                                    .foregroundStyle(TM.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(TM.textTertiary)
                            }
                            .padding(.horizontal, TM.cardContentHorizontal)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("预览不同状态（仅 Debug）")
                        .accessibilityLabel("预览状态")
                    }
                    #endif

                    VStack(alignment: .leading, spacing: 8) {
                        Label("凭据以本地明文文件保存，受文件权限保护", systemImage: "lock.fill")
                        HStack {
                            Text("TokenMeter \(version)")
                            Spacer()
                            Link("反馈问题", destination: URL(string: "https://github.com/Amdeo/TokenMeter/issues/new/choose")!)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(TM.textTertiary)
                    .padding(.top, 6)
                }
                .reportsIntrinsicPanelHeight(route: .settings, chrome: PanelLayoutMetrics.settingsChrome)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear {
            settings.refreshLoginItemStatus()
            settings.updateNotificationStatus()
        }
    }

    private func settingsToggle(_ title: String, isOn: Binding<Bool>, isLast: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(TM.textPrimary)
                Spacer()
                Toggle(title, isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal, TM.cardContentHorizontal)
            .padding(.vertical, 8)
            if !isLast {
                Rectangle().fill(TM.divider).frame(height: 1).padding(.leading, TM.cardContentHorizontal)
            }
        }
    }

    private func appearanceRow() -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("外观")
                    .font(.system(size: 12))
                    .foregroundStyle(TM.textPrimary)
                Spacer()
                Picker("外观", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .help("面板外观主题")
            }
            .padding(.horizontal, TM.cardContentHorizontal)
            .padding(.vertical, 8)
            Rectangle().fill(TM.divider).frame(height: 1).padding(.leading, TM.cardContentHorizontal)
        }
    }

    private func refreshIntervalRow() -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("刷新间隔")
                    .font(.system(size: 12))
                    .foregroundStyle(TM.textPrimary)
                Spacer()
                Picker("刷新间隔", selection: $settings.refreshInterval) {
                    ForEach(SettingsStore.refreshIntervalPresets, id: \.self) { seconds in
                        Text("\(Int(seconds / 60)) 分钟").tag(seconds)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()
                .disabled(!settings.autoRefreshEnabled)
                .help("后台自动刷新的时间间隔")
            }
            .padding(.horizontal, TM.cardContentHorizontal)
            .padding(.vertical, 8)
        }
    }

    private func thresholdRow(_ currency: String, value: Binding<Double>, isLast: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("低于 \(currency)")
                    .font(.system(size: 12))
                    .foregroundStyle(TM.textPrimary)
                Spacer()
                TextField("0", value: value, format: .number)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(TM.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(width: 78)
                    .background(TM.fieldFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(TM.border, lineWidth: 1))
            }
            .padding(.horizontal, TM.cardContentHorizontal)
            .padding(.vertical, 7)
            if !isLast {
                Rectangle().fill(TM.divider).frame(height: 1).padding(.leading, TM.cardContentHorizontal)
            }
        }
    }

    @ViewBuilder
    private func settingsSection<Content: View, Footer: View>(
        _ title: String,
        @ViewBuilder footer: () -> Footer = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(TM.textTertiary)
            VStack(spacing: 0) { content() }
                .background(TM.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(TM.border, lineWidth: 1))
            footer()
        }
    }
}
