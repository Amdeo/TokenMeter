import Foundation

// MARK: - 认证流程注册表

/// 认证 flow 的统一入口：根据 flowID 提供「能否保存 / 保存凭据」能力。
/// 新增认证协议（如新的 OAuth 变体）时在此注册对应的校验与保存逻辑。
@MainActor
enum AuthFlowRegistry {
    static func canSave(
        originalAuthMethodID: AuthMethodID?,
        selected: AuthMethodID,
        flowID: AuthFlowID,
        draft: SubscriptionEditorDraft
    ) -> Bool {
        guard !draft.isImportingBrowser else { return false }
        guard originalAuthMethodID != selected else { return true }
        return switch flowID {
        case .apiKey:
            !draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .deviceOAuth, .oauthCode:
            draft.oauthCredential != nil
        case .browserSession:
            draft.browserCredential != nil || draft.cookieCredential != nil
        }
    }

    /// 保存当前 draft 的凭据到订阅 ID；返回是否写入了内容。
    static func saveCredential(for subscriptionID: UUID, flowID: AuthFlowID, draft: SubscriptionEditorDraft) throws {
        switch flowID {
        case .apiKey:
            let key = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            try CredentialStore().save(.apiKey(key), for: subscriptionID)
        case .deviceOAuth, .oauthCode:
            guard let credential = draft.oauthCredential else { return }
            try CredentialStore().save(.oauth(credential), for: subscriptionID)
        case .browserSession:
            if let credential = draft.cookieCredential {
                try CredentialStore().save(cookieSession: credential, for: subscriptionID)
            } else if let credential = draft.browserCredential {
                try CredentialStore().save(.browserSession(credential), for: subscriptionID)
            }
        }
    }
}
