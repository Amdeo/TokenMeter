import Foundation

/// 可 Codable 的 JSON 值树：用于 `UsageSnapshot.providerData` 与供应商响应解析。
/// 自定义卡片 renderer 可读取自己命名空间下的字段；标准卡片不消费它。
enum JSONValue: Decodable, Encodable, Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let boolean = try? container.decode(Bool.self) {
            self = .boolean(boolean)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let object): try container.encode(object)
        case .array(let values): try container.encode(values)
        case .string(let string): try container.encode(string)
        case .number(let number): try container.encode(number)
        case .boolean(let boolean): try container.encode(boolean)
        case .null: try container.encodeNil()
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    /// 按别名集合在直接子键中查找值；键名归一化为小写字母数字。
    func value(for aliases: [String]) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        let names = Set(aliases.map(Self.normalize))
        for (key, value) in object where names.contains(Self.normalize(key)) { return value }
        return nil
    }

    /// 递归查找键别名对应的对象值（支持嵌套数组/对象）。
    func findObject(for aliases: [String]) -> JSONValue? {
        guard case .object(let object) = self else {
            if case .array(let values) = self {
                return values.lazy.compactMap { $0.findObject(for: aliases) }.first
            }
            return nil
        }
        let normalizedAliases = Set(aliases.map(Self.normalize))
        if let match = object.first(where: { normalizedAliases.contains(Self.normalize($0.key)) }),
           case .object = match.value {
            return match.value
        }
        return object.values.lazy.compactMap { $0.findObject(for: aliases) }.first
    }

    func number(for aliases: [String]) -> Double? {
        guard case .object(let object) = self else { return nil }
        let names = Set(aliases.map(Self.normalize))
        for (key, value) in object where names.contains(Self.normalize(key)) {
            switch value {
            case .number(let number): return number
            case .string(let string): return Double(string)
            default: continue
            }
        }
        return nil
    }

    func string(for aliases: [String]) -> String? {
        guard case .object(let object) = self else { return nil }
        let names = Set(aliases.map(Self.normalize))
        for (key, value) in object where names.contains(Self.normalize(key)) {
            if case .string(let string) = value { return string }
        }
        return nil
    }

    /// 从多种时间字段形态解析重置时间（ISO8601 / 秒级 / 毫秒级时间戳）。
    var resetDate: Date? {
        if let string = string(for: ["reset_at", "resetAt", "resets_at", "resetsAt", "reset", "reset_time"]) {
            if let date = ISO8601DateFormatter().date(from: string) { return date }
            if let timestamp = Double(string) { return Self.date(from: timestamp) }
        }
        if let timestamp = number(for: ["reset_at", "resetAt", "resets_at", "resetsAt", "reset", "reset_time"]) {
            return Self.date(from: timestamp)
        }
        return nil
    }

    static func date(from timestamp: Double) -> Date {
        Date(timeIntervalSince1970: timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp)
    }

    private static func normalize(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
