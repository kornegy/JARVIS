/// Идентификатор действия или инструмента: `apps.open`, `files.move`, `assistant.enable`.
///
/// Формат: минимум два сегмента через точку; сегмент начинается с латинской буквы
/// в нижнем регистре, дальше — `a-z`, `0-9`, `_`; общая длина до 64 символов.
/// Идентификаторы задаёт разработчик, а не модель, поэтому их безопасно писать в журнал.
public struct ActionIdentifier: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard ActionIdentifier.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static func < (lhs: ActionIdentifier, rhs: ActionIdentifier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }
        return segments.allSatisfy(isValidSegment)
    }

    private static func isValidSegment(_ segment: Substring) -> Bool {
        guard let first = segment.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
        return segment.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_"
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = ActionIdentifier(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid action identifier")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension ActionIdentifier: ExpressibleByStringLiteral {
    /// Литерал в коде должен быть корректным — ошибка в нём ловится тестами при первом запуске.
    public init(stringLiteral value: StaticString) {
        guard let identifier = ActionIdentifier(value.description) else {
            preconditionFailure("Invalid ActionIdentifier literal")
        }
        self = identifier
    }
}
