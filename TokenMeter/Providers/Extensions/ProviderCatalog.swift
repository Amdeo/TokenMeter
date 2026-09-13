// MARK: - 供应商目录

/// 全部供应商的唯一清单：新增一个供应商，就在这里加一行。
///
/// 供应商实现放在 `Providers/Extensions/<供应商>/`，共享机制放在 `Providers/Common/`。
/// 本文件只做登记，因此新增供应商不需要改注册表、编辑页、HTTP 层或任何其他共享代码。
/// 这里的顺序决定 TM-03「选择供应商」页面的卡片顺序。
///
/// 为什么保留这一行显式登记：Swift 没有可靠的编译期自注册机制，而基于 Objective-C
/// 运行时枚举类的做法会被链接器 dead-strip 掉。一行可读、可 grep、可被测试断言的
/// 清单，是这里刻意选择的确定性；将来若想彻底去掉，可以在构建阶段扫描扩展目录生成它。
enum ProviderCatalog {
    static let providers: [any ProviderDefinition] = [
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
}
