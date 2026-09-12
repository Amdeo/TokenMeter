import SwiftUI

// MARK: - 供应商注册表

/// 全部内置供应商的编译期注册表。新增供应商时在这里追加一条定义即可。
@MainActor
enum ProviderRegistry {
    /// 唯一供应商目录；初始化时校验 ID 唯一性（Assert 保护，避免误注册重复 ID）。
    static let all: [any ProviderDefinition] = {
        let definitions: [any ProviderDefinition] = [
            DeepSeekProviderDefinition(),
            KimiProviderDefinition(),
            ZhipuProviderDefinition(),
            OpenCodeGoProviderDefinition(),
            MiniMaxProviderDefinition(),
            RelayBalanceProviderDefinition.ccbus,
            RelayBalanceProviderDefinition.apiKeyFun,
            NowCodingProviderDefinition(),
            SiyuProviderDefinition(),
            CodexProviderDefinition(),
            ClaudeProviderDefinition(),
        ]
        var seen = Set<String>()
        for definition in definitions {
            assert(seen.insert(definition.id.rawValue).inserted, "重复的 ProviderID: \(definition.id.rawValue)")
        }
        return definitions
    }()

    static func definition(for providerID: ProviderID) -> (any ProviderDefinition)? {
        all.first { $0.id == providerID }
    }

    nonisolated static func isSupported(_ providerID: ProviderID) -> Bool {
        switch providerID {
        case .deepSeek, .kimi, .zhipu, .openCodeGo, .miniMax, .ccbus, .apikeyFun, .nowCoding, .siyu, .codex, .claude:
            true
        default:
            false
        }
    }

    nonisolated static func authFlow(for providerID: ProviderID, authMethodID: AuthMethodID) -> AuthFlowID? {
        switch providerID {
        case .deepSeek, .zhipu, .openCodeGo, .miniMax:
            authMethodID == .apiKey ? .apiKey : nil
        case .kimi:
            switch authMethodID {
            case .apiKey: .apiKey
            case .kimiDeviceOAuth: .deviceOAuth
            case .kimiBrowserSession: .browserSession
            default: nil
            }
        case .ccbus:
            authMethodID == .ccbusBrowserSession ? .browserSession : nil
        case .apikeyFun:
            authMethodID == .apikeyFunBrowserSession ? .browserSession : nil
        case .nowCoding:
            authMethodID == .nowCodingBrowserSession ? .browserSession : nil
        case .siyu:
            authMethodID == .siyuBrowserSession ? .browserSession : nil
        case .codex:
            authMethodID == .codexDeviceOAuth ? .deviceOAuth : nil
        case .claude:
            authMethodID == .claudeOAuth ? .oauthCode : nil
        default:
            nil
        }
    }
}

// MARK: - 未支持供应商

/// 未知/未注册供应商的降级定义：保留订阅但不崩溃，显示不可用状态。
@MainActor
struct UnsupportedProviderDefinition: ProviderDefinition {
    let id: ProviderID

    init(providerID: ProviderID) {
        self.id = providerID
    }

    var metadata: ProviderMetadata {
        ProviderMetadata(
            displayName: id.rawValue,
            iconResourceName: nil,
            fallbackSystemImage: "questionmark.circle",
            tintRGB: 0x737875,
            capabilityDescription: "未知供应商，暂无额度接口。",
            authPageURL: nil,
            authenticationSummary: "接口不支持"
        )
    }

    var authMethods: [AuthMethodDefinition] {
        [AuthMethodDefinition(id: .apiKey, flowID: .apiKey, title: "手动 API Key", systemImage: "key.fill", detail: "未知供应商")] 
    }

    let cardRenderer: any ProviderCardRenderer = UnsupportedCardRenderer()

    func makeUsageProvider(for subscription: Subscription) -> any UsageProvider {
        UnsupportedUsageProvider(subscription: subscription)
    }

    func makeDemoSnapshot(for subscription: Subscription, now: Date) -> UsageSnapshot {
        .unsupported(subscription: subscription, message: "未知供应商")
    }
}

/// 始终抛出 unsupported 的占位 provider（未知供应商刷新时不会崩溃）。
struct UnsupportedUsageProvider: UsageProvider {
    let subscription: Subscription

    func fetchUsage() async throws -> UsageSnapshot {
        throw UsageProviderError.unsupported(subscription.providerID)
    }
}
