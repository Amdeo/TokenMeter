import Foundation
import Testing
@testable import TokenMeter

/// 设置窗口的导航逻辑回归：应用级页、订阅子页的草稿生命周期，以及「添加订阅」流程。
///
/// 这些是窗口自己状态机的纯逻辑，不依赖任何点击——点击只是触发它们的另一种方式。
@MainActor
struct SettingsNavigationTests {
    private static let subs = [
        Subscription(providerID: .kimi, name: "Kimi小号", authMethodID: .apiKey),
        Subscription(providerID: .kimi, name: "Kimi", authMethodID: .apiKey),
        Subscription(providerID: .deepSeek, name: "DeepSeek", authMethodID: .apiKey),
    ]

    // MARK: - 订阅子页

    @Test
    func selectingASubscriptionPreparesItsDraft() {
        let navigation = SettingsNavigation()
        navigation.select(.subscription(Self.subs[0].id), subscriptions: Self.subs)
        #expect(navigation.pane == .subscription(Self.subs[0].id))
        #expect(navigation.subscriptionDraft?.original?.id == Self.subs[0].id)
    }

    @Test
    func selectingTheSameSubscriptionKeepsTheUnsavedDraft() {
        // **同一条订阅不重建草稿**：在侧边栏来回切换时未保存的改动要留住。
        let navigation = SettingsNavigation()
        navigation.select(.subscription(Self.subs[0].id), subscriptions: Self.subs)
        let draft = navigation.subscriptionDraft
        draft?.name = "改过的名字"

        navigation.select(.general, subscriptions: Self.subs)
        navigation.select(.subscription(Self.subs[0].id), subscriptions: Self.subs)

        #expect(navigation.subscriptionDraft === draft)
        #expect(navigation.subscriptionDraft?.name == "改过的名字")
    }

    @Test
    func selectingAnotherSubscriptionReplacesTheDraft() {
        let navigation = SettingsNavigation()
        navigation.select(.subscription(Self.subs[0].id), subscriptions: Self.subs)
        navigation.select(.subscription(Self.subs[1].id), subscriptions: Self.subs)
        #expect(navigation.subscriptionDraft?.original?.id == Self.subs[1].id)
    }

    @Test
    func aMissingSubscriptionFallsBackToGeneral() {
        let navigation = SettingsNavigation()
        navigation.select(.subscription(UUID()), subscriptions: Self.subs)
        #expect(navigation.pane == .general)
        #expect(navigation.subscriptionDraft == nil)
    }

    @Test
    func finishEditingRebuildsTheDraftAfterASave() {
        // 保存之后要按保存后的样子重建草稿，`isDirty` 随之归零。
        let navigation = SettingsNavigation()
        navigation.select(.subscription(Self.subs[0].id), subscriptions: Self.subs)
        navigation.subscriptionDraft?.name = "改过的名字"
        #expect(navigation.subscriptionDraft?.isDirty == true)

        navigation.finishEditing(subscriptions: Self.subs)
        #expect(navigation.subscriptionDraft?.isDirty == false)
        #expect(navigation.pane == .subscription(Self.subs[0].id))
    }

    @Test
    func finishEditingFallsBackToGeneralWhenTheSubscriptionIsGone() {
        // 删除之后退回通用页，而不是留一个空子页。
        let navigation = SettingsNavigation()
        navigation.select(.subscription(Self.subs[0].id), subscriptions: Self.subs)
        navigation.finishEditing(subscriptions: Array(Self.subs.dropFirst()))
        #expect(navigation.pane == .general)
        #expect(navigation.subscriptionDraft == nil)
    }

    // MARK: - 添加订阅

    @Test
    func theAddFlowStartsWithProviderSelectionAndNoDraft() {
        let navigation = SettingsNavigation()
        navigation.select(.addSubscription, subscriptions: Self.subs)
        #expect(navigation.pane == .addSubscription)
        #expect(navigation.newSubscriptionDraft == nil)
    }

    @Test
    func choosingAProviderBuildsADraftForANewSubscription() {
        let navigation = SettingsNavigation()
        navigation.select(.addSubscription, subscriptions: Self.subs)
        navigation.chooseProvider(.deepSeek)

        #expect(navigation.newSubscriptionDraft?.providerID == .deepSeek)
        #expect(navigation.newSubscriptionDraft?.original == nil)
        #expect(navigation.showsAppearance == false)
    }

    @Test
    func leavingTheAddFlowDiscardsTheUnsavedDraft() {
        // 一条还没保存的订阅，离开这一页就丢掉，留着没有意义。
        let navigation = SettingsNavigation()
        navigation.select(.addSubscription, subscriptions: Self.subs)
        navigation.chooseProvider(.deepSeek)

        navigation.select(.general, subscriptions: Self.subs)
        #expect(navigation.newSubscriptionDraft == nil)
    }

    @Test
    func savingTheNewSubscriptionSelectsItInTheSidebar() {
        // 停在「添加订阅」页会让人以为没生效——侧边栏多了一行，右边也应当跟着过去。
        let navigation = SettingsNavigation()
        navigation.select(.addSubscription, subscriptions: Self.subs)
        navigation.chooseProvider(.deepSeek)

        let newSubscription = Subscription(providerID: .deepSeek, name: "DeepSeek 2", authMethodID: .apiKey)
        navigation.didCreate(newSubscription.id, subscriptions: Self.subs + [newSubscription])

        #expect(navigation.pane == .subscription(newSubscription.id))
        #expect(navigation.newSubscriptionDraft == nil)
        #expect(navigation.subscriptionDraft?.original?.id == newSubscription.id)
    }

    @Test
    func savingANewSubscriptionThatThenVanishesFallsBackToGeneral() {
        let navigation = SettingsNavigation()
        navigation.select(.addSubscription, subscriptions: Self.subs)
        navigation.chooseProvider(.deepSeek)

        navigation.didCreate(UUID(), subscriptions: Self.subs)
        #expect(navigation.pane == .general)
    }

    // MARK: - 外观子页

    @Test
    func theAppearanceSubpageIsSharedBetweenThePaneAndTheAddFlow() {
        let navigation = SettingsNavigation()
        navigation.select(.subscription(Self.subs[0].id), subscriptions: Self.subs)
        navigation.showsAppearance = true

        navigation.select(.subscription(Self.subs[1].id), subscriptions: Self.subs)
        // 换一条订阅就离开外观子页，而不是把上一条的外观页带过去。
        #expect(navigation.showsAppearance == false)
    }
}
