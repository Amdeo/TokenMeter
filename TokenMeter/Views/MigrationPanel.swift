import AppKit
import SwiftUI

@MainActor
struct MigrationPanel: View {
    let store: UsageStore
    let onClose: () -> Void

    private enum Mode { case choice, export, importPassword, review }
    @State private var mode: Mode = .choice
    @State private var password = ""
    @State private var confirmation = ""
    @State private var packageData: Data?
    @State private var plan: MigrationImportPlan?
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderIconButton(systemName: "chevron.left", label: "返回设置", action: onClose)
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .padding(.top, 10)
                .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch mode {
                    case .choice: choiceContent
                    case .export: exportContent
                    case .importPassword: importPasswordContent
                    case .review: reviewContent
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(TM.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .reportsIntrinsicPanelHeight(route: .migration, chrome: PanelLayoutMetrics.settingsChrome)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var title: String {
        switch mode {
        case .choice: "数据迁移"
        case .export: "导出迁移包"
        case .importPassword: "导入迁移包"
        case .review: "确认导入"
        }
    }

    private var choiceContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            actionRow("导出迁移包", icon: "square.and.arrow.up") {
                reset(); mode = .export
            }
            actionRow("导入迁移包", icon: "square.and.arrow.down") {
                chooseImportFile()
            }
            Text("迁移包包含订阅配置和敏感凭据，不包含偏好设置、用量数据或内置浏览器会话。")
                .font(.system(size: 10))
                .foregroundStyle(TM.textTertiary)
                .padding(.top, 4)
        }
    }

    private var exportContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("迁移包包含 API Key、OAuth 与网页登录态凭据。请仅保存到可信位置。", systemImage: "lock.trianglebadge.exclamationmark")
                .font(.system(size: 11))
                .foregroundStyle(TM.warn)
            passwordFields(confirm: true)
            Button(isWorking ? "正在生成迁移包…" : "选择保存位置") { exportPackage() }
                .buttonStyle(.borderedProminent)
                .disabled(!passwordsMatch || isWorking)
        }
    }

    private var importPasswordContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("输入创建迁移包时设置的密码。")
                .font(.system(size: 11))
                .foregroundStyle(TM.textSecondary)
            passwordFields(confirm: false)
            Button("解锁并检查") { prepareImport() }
                .buttonStyle(.borderedProminent)
                .disabled(password.count < CredentialMigrationService.minimumPasswordLength || isWorking)
        }
    }

    private var reviewContent: some View {
        Group {
            if let plan {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        summary("新增", plan.addCount, TM.ok)
                        summary("覆盖", plan.updateCount, TM.accent)
                        summary("覆盖凭据", plan.credentialReplacementCount, TM.warn)
                        summary("认证变更覆盖", plan.authMethodChangeCredentialReplacementCount, TM.danger)
                        summary("删除凭据", plan.credentialRemovalCount, TM.danger)
                    }
                    if !plan.skippedItems.isEmpty {
                        Text("跳过 \(plan.skippedItems.count) 项")
                            .font(.system(size: 11))
                            .foregroundStyle(TM.textTertiary)
                    }
                    ForEach(plan.items) { item in
                        importItem(item)
                    }
                    Button("确认导入") { commitImport() }
                        .buttonStyle(.borderedProminent)
                        .disabled(plan.selectedItems.isEmpty || isWorking)
                }
            }
        }
    }

    private func passwordFields(confirm: Bool) -> some View {
        VStack(spacing: 8) {
            SecureField("至少 12 个字符", text: $password)
                .textFieldStyle(.roundedBorder)
            if confirm {
                SecureField("再次输入密码", text: $confirmation)
                    .textFieldStyle(.roundedBorder)
                if !password.isEmpty && password.count < CredentialMigrationService.minimumPasswordLength {
                    Text("密码至少需要 12 个字符")
                        .font(.system(size: 10))
                        .foregroundStyle(TM.warn)
                } else if !confirmation.isEmpty && password != confirmation {
                    Text("两次输入的密码不一致")
                        .font(.system(size: 10))
                        .foregroundStyle(TM.warn)
                }
            }
        }
    }

    private func actionRow(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).frame(width: 18)
                Text(label).font(.system(size: 12))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10))
            }
            .padding(.horizontal, TM.cardContentHorizontal)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(TM.cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func summary(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.system(size: 15, weight: .semibold)).foregroundStyle(color)
            Text(label).font(.system(size: 9)).foregroundStyle(TM.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func importItem(_ item: MigrationImportItem) -> some View {
        let selectable = { if case .skip = item.kind { return false }; return true }()
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("", isOn: Binding(
                    get: { item.isSelected },
                    set: { update(item, selected: $0) }
                ))
                .labelsHidden()
                .disabled(!selectable)
                Text(item.subscription.name).font(.system(size: 12))
                Spacer()
                Text(itemLabel(item)).font(.system(size: 10)).foregroundStyle(TM.textTertiary)
            }
            if item.requiresCredentialRemoval {
                Text("选择此项会删除本地旧凭据。")
                    .font(.system(size: 10)).foregroundStyle(TM.danger)
            } else if item.credentialAction == .preserveLocal {
                Button("删除本地凭据") {
                    plan = plan?.updatingCredentialAction(.removeLocal, for: item.id)
                }
                .font(.system(size: 10))
                .foregroundStyle(TM.danger)
                .buttonStyle(.plain)
            } else if item.isExpired {
                Text("导入凭据已过期，将在导入后立即验证。")
                    .font(.system(size: 10)).foregroundStyle(TM.warn)
            }
        }
        .padding(.vertical, 5)
    }

    private func itemLabel(_ item: MigrationImportItem) -> String {
        switch item.kind {
        case .add: "新增"
        case .update: "覆盖"
        case .skip(let reason): reason
        }
    }

    private var passwordsMatch: Bool { password.count >= CredentialMigrationService.minimumPasswordLength && password == confirmation }

    private func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "选择 TokenMeter 凭据迁移包"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= CredentialMigrationService.maximumPackageBytes else {
                throw CredentialMigrationError.invalidPackage
            }
            packageData = data
            reset(clearData: false)
            mode = .importPassword
        } catch {
            errorMessage = CredentialMigrationError.passwordOrFileCorrupt.localizedDescription
        }
    }

    private func exportPackage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "TokenMeter-migration.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let data = try await store.exportMigrationPackage(password: password)
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
                    throw CocoaError(.fileWriteUnknown)
                }
                onClose()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func prepareImport() {
        guard let packageData else { return }
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                plan = try await store.prepareMigrationImport(data: packageData, password: password)
                mode = .review
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func commitImport() {
        guard let plan else { return }
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await store.commitMigrationImport(plan)
                onClose()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func update(_ item: MigrationImportItem, selected: Bool) {
        var changed = item
        changed.isSelected = selected
        plan = plan?.updating(changed)
    }

    private func reset(clearData: Bool = true) {
        password = ""
        confirmation = ""
        plan = nil
        errorMessage = nil
        if clearData { packageData = nil }
    }
}
