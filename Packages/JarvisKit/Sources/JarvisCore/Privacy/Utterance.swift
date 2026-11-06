import Foundation

/// Распознанная фраза пользователя (расшифровка голосовой или текстовой команды).
///
/// Это самые приватные данные JARVIS, поэтому тип устроен так, чтобы их было трудно
/// случайно сохранить или вывести:
/// * **не** `Codable` — расшифровку нельзя закодировать в JSON и записать на диск;
/// * `description`, `debugDescription` и `Mirror` скрывают текст — интерполяция строк,
///   `dump` и отладчик покажут только `<redacted>`;
/// * логгер JARVIS принимает только статические строки, поэтому передать туда текст
///   невозможно (ошибка компиляции).
///
/// Текст доступен через `text` — явно, в коде интерпретации команды. Живёт только в RAM.
public struct Utterance: Sendable, Equatable {
    public let text: String
    public let locale: Locale

    public init(text: String, locale: Locale) {
        self.text = text
        self.locale = locale
    }

    public var isBlank: Bool {
        text.allSatisfy { $0.isWhitespace }
    }
}

extension Utterance: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "Utterance(<redacted>, \(text.count) chars)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
