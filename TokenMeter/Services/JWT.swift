import Foundation

/// JWT 载荷解码：只用于读取本地令牌里的声明（过期时间、账户 ID）。
///
/// **不做签名校验**——这些值不参与任何信任决策，令牌有效性由服务端在每次请求时校验；
/// 本地读取只是为了判断是否该提前续期、以及给请求补上账户标识。
enum JWT {
    /// 解码 JWT 中间段的 payload。
    /// 段数不是 3、base64url 非法、或顶层不是 JSON 对象时返回 nil。
    static func payload(of token: String) -> JSONValue? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object = value else { return nil }
        return value
    }

    /// 载荷中的 `exp`（秒级时间戳）。
    /// 只认数字形态：字符串形态的 exp 视为不可用（与各供应商原先的严格行为一致）。
    static func expiration(of token: String) -> Date? {
        guard case .number(let seconds)? = payload(of: token)?.value(for: ["exp"]) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
