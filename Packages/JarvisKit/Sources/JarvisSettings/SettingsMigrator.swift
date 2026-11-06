import Foundation

/// Миграции файла настроек между версиями схемы.
///
/// Шаг миграции работает с «сырым» JSON-словарём **до** декодирования, поэтому может
/// переименовывать и переносить поля. Ключ словаря `steps` — версия, *из* которой шаг
/// переводит в следующую (`1` → `2` и т.д.).
///
/// Сейчас схема версии 1 и шагов нет. Пример будущего шага:
/// ```swift
/// SettingsMigrator(steps: [
///     1: { json in
///         if var voice = json["voice"] as? [String: Any] {
///             voice["recognitionLocale"] = voice.removeValue(forKey: "language")
///             json["voice"] = voice
///         }
///     },
/// ])
/// ```
public struct SettingsMigrator: Sendable {
    public typealias Step = @Sendable (inout [String: Any]) throws -> Void

    public enum MigrationError: Error, Equatable {
        case missingStep(fromVersion: Int)
    }

    public let steps: [Int: Step]

    public init(steps: [Int: Step]) {
        self.steps = steps
    }

    public static let standard = SettingsMigrator(steps: [:])

    public func migrate(_ json: inout [String: Any], from oldVersion: Int, to newVersion: Int) throws {
        var version = oldVersion
        while version < newVersion {
            guard let step = steps[version] else { throw MigrationError.missingStep(fromVersion: version) }
            try step(&json)
            version += 1
            json["schemaVersion"] = version
        }
    }
}
