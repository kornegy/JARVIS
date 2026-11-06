/// Обёртка для чувствительного значения (API-ключ, путь к личному файлу и т.п.).
///
/// При печати, интерполяции и `dump` показывает `<redacted>`. Само значение доступно
/// только явно через `revealed` — такое место в коде легко найти поиском и проверить на ревью.
public struct Sensitive<Value: Sendable>: Sendable {
    public let revealed: Value

    public init(_ value: Value) {
        self.revealed = value
    }
}

extension Sensitive: Equatable where Value: Equatable {}

extension Sensitive: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
