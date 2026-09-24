import SwiftUI

/// 一个带标题的设置分组，画成一张圆角卡片。
///
/// 移植自 Pulse 的 `SettingsGroup`。整个设置窗口就是用这个形状搭起来的：
/// 上面一行小标题，卡片里是一叠用细线分隔的行。
///
/// 配色用 `TM` 令牌而不是系统色：窗口虽然是普通窗口，但它是同一个 app 的一部分，
/// 跟着 app 自己的浅色/深色与卡片底色走，才不会看起来像另一个程序。
struct SettingsGroup<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TM.textPrimary)
                    .padding(.leading, 4)
            }

            // 左对齐而不是居中：`SettingsRow` 靠 `Spacer` 自己占满整行，居中对它没有影响，
            // 但卡片里若放的是裸文本，居中会把整段话挪到卡片中间去。
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .background(TM.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(TM.border, lineWidth: 1)
                    // 装饰不该盖在控件的点击区上。
                    .allowsHitTesting(false)
            }
        }
    }
}

/// 分组里的一行：左边标签、右边控件，标签下面可以有说明。
///
/// 移植自 Pulse 的 `SettingsRow`。`icon` 给的是单色 mark 的资源名，
/// 用在「这一行**就是**那个标记所代表的东西」的地方——订阅行、外观预览之类。
struct SettingsRow<Control: View>: View {
    let title: String
    let subtitle: String?
    let icon: String?
    let iconFallback: String
    @ViewBuilder let control: Control

    init(
        _ title: String,
        subtitle: String? = nil,
        icon: String? = nil,
        iconFallback: String = "questionmark",
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.iconFallback = iconFallback
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if let icon {
                ProviderMarkView(resource: icon, fallbackSystemImage: iconFallback, size: 15)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(TM.textPrimary)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(TM.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
    }
}

/// 卡片里不放控件的一段内容：状态行、说明文字、报错。
///
/// `SettingsRow` 自带内边距，裸着放进 `SettingsGroup` 的文本会一直贴到卡片边线上——
/// 圆角与描边正好压着第一个字。这一层补上同一份内边距，多行内容之间再留一点行距。
struct SettingsNote<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

enum SettingsLayout {
    /// 行右侧控件的宽度上限，不是固定尺寸。
    ///
    /// macOS 的 `Picker` 按最长选项给自己定尺寸，没法让它填满一个 frame，
    /// 所以这里限制它**最多**多宽——一个装着长文案的下拉会截断而不是把邻居顶开，
    /// 而展开时全文仍然在。配 `alignment: .trailing` 用：`Picker` 会在给定 frame 里
    /// 自己居中，那会让它离行的右缘还差一截，而普通 `Button` 能贴到边。
    static let controlWidth: CGFloat = 180
}

/// 行之间的细线，缩进与行自己的内边距对齐，跟 macOS 的分组列表一样。
struct SettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(TM.divider)
            .frame(height: 1)
            .padding(.leading, 14)
    }
}
