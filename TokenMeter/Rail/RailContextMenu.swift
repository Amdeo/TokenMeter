import AppKit

/// 悬浮条的右键菜单。
///
/// 从 app 委托里搬出来单独放，是因为它值得被测：菜单里有什么、勾在哪一项上，
/// 都是用户直接看得见的行为，而委托本身（要起窗口、要装状态栏图标）测不了。
///
/// 菜单里**没有**「打开 TokenMeter」：概览面板的入口是菜单栏图标，
/// 条上的菜单只管这条条自己（常显示、位置）加上设置与退出。
@MainActor
enum RailContextMenu {
    static func build(
        placement: RailPlacement,
        settings: SettingsStore,
        actions: RailMenuActions
    ) -> NSMenu {
        let menu = NSMenu()

        // 「常显示」只对贴边的条出现。悬浮着的条本来就不收，摆一个勾了也不生效的项
        // 只会让人以为坏了。勾选说的是正面：勾上 = 不收，对应设置里的「离开时自动收起」关掉。
        if placement.isDocked {
            let alwaysVisible = NSMenuItem(
                title: "常显示",
                action: #selector(RailMenuActions.toggleAlwaysVisible),
                keyEquivalent: ""
            )
            alwaysVisible.target = actions
            alwaysVisible.state = settings.railAutoCollapse ? .off : .on
            menu.addItem(alwaysVisible)

            menu.addItem(.separator())
        }

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(RailMenuActions.openSettings), keyEquivalent: "")
        settingsItem.target = actions
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // 位置放在菜单里而不是只放设置页里：它作用的对象就是这条条本身，
        // 而拖动已经能做同一件事，菜单只是给一个说得清楚的做法。
        let position = NSMenuItem(title: "位置", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let options: [(String, RailDock, Selector)] = [
            ("贴到屏幕左侧", .edge(.left), #selector(RailMenuActions.dockLeft)),
            ("贴到屏幕右侧", .edge(.right), #selector(RailMenuActions.dockRight)),
            ("贴到屏幕顶部", .edge(.top), #selector(RailMenuActions.dockTop)),
            ("自由悬浮", .floating, #selector(RailMenuActions.float)),
        ]
        for (title, dock, action) in options {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = actions
            item.state = placement.dock == dock ? .on : .off
            submenu.addItem(item)
        }
        position.submenu = submenu
        menu.addItem(position)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 TokenMeter", action: #selector(RailMenuActions.quit), keyEquivalent: "")
        quit.target = actions
        menu.addItem(quit)

        return menu
    }
}
