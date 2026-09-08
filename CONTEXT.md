# TokenMeter

macOS 菜单栏应用：跟踪各 AI 供应商订阅的额度与余额。

## Language

**网页登录态凭证（Browser Session Credential）**:
按订阅 ID 保存在本地私有 `credentials.json` 中的 token / session cookie 凭证；用量查询与续期只依赖它。
_Avoid_: 登录态、网页凭证（单独使用时指代不明）

**内置浏览器会话（Embedded Browser Session）**:
内嵌登录窗口共享的 WKWebView 持久化站点数据，按供应商域名共享、与订阅无关；「切换账号」即清除目标域的该会话，不触碰网页登录态凭证。
_Avoid_: WebView 缓存、登录缓存

**订阅标识（Subscription ID）**:
每个订阅跨重命名和设备迁移保持不变的唯一身份，用于关联该订阅的配置与凭据。
_Avoid_: 订阅名称、账户名称

**凭据迁移包（Credential Migration Package）**:
由全部订阅配置及其存在时关联的凭据组成的加密可移植备份；不包含偏好设置、用量数据或内置浏览器会话。
_Avoid_: 数据导出、配置备份（范围不明确）
