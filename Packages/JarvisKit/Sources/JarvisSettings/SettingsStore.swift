import Foundation
import JarvisCore

/// Откуда взялись загруженные настройки.
public enum SettingsOrigin: Sendable, Equatable {
    /// Файла нет (первый запуск) — значения по умолчанию.
    case defaults
    /// Прочитаны из файла текущей версии схемы.
    case file
    /// Файл старой версии: сделана резервная копия, выполнена миграция.
    case migrated(fromVersion: Int)
    /// Файл повреждён: он сохранён в резервные копии, используются значения по умолчанию.
    case recoveredFromCorruption
    /// Файл записан более новой версией JARVIS. Он не будет перезаписан.
    case newerSchema(version: Int)
}

public struct SettingsLoadResult: Sendable {
    public let settings: JarvisSettings
    public let origin: SettingsOrigin
}

public enum SettingsStoreError: Error, Equatable {
    /// На диске настройки более новой версии — перезапись уничтожила бы их.
    case refusingToOverwriteNewerSchema(version: Int)
}

/// Чтение и запись `settings.json`.
///
/// `load()` никогда не падает: в худшем случае возвращает значения по умолчанию и
/// сохраняет проблемный файл в резервные копии, чтобы ничего не потерялось.
public final class SettingsStore: Sendable {
    public let fileURL: URL
    private let backups: FileBackups
    private let migrator: SettingsMigrator
    private let now: @Sendable () -> Date
    private let log = JarvisLogger(category: "settings")

    public init(
        fileURL: URL,
        backupsDirectory: URL,
        migrator: SettingsMigrator = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.backups = FileBackups(directory: backupsDirectory)
        self.migrator = migrator
        self.now = now
    }

    public func load() -> SettingsLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            log.info("No settings file, using defaults")
            return SettingsLoadResult(settings: .defaults, origin: .defaults)
        }
        do {
            let data = try Data(contentsOf: fileURL)
            var json = try SettingsStore.jsonObject(from: data)
            let version = json["schemaVersion"] as? Int ?? 1
            let current = JarvisSettings.currentSchemaVersion

            if version > current {
                log.notice("Settings file has newer schema", .int("fileVersion", version), .int("supportedVersion", current))
                let settings = (try? SettingsStore.decode(data)) ?? .defaults
                return SettingsLoadResult(settings: settings.normalized(), origin: .newerSchema(version: version))
            }

            if version < current {
                try backups.backUp(fileURL, name: "settings", label: "v\(version)", at: now())
                try migrator.migrate(&json, from: version, to: current)
                let migratedData = try JSONSerialization.data(withJSONObject: json)
                let settings = try SettingsStore.decode(migratedData).normalized()
                try save(settings)
                log.notice("Settings migrated", .int("fromVersion", version), .int("toVersion", current))
                return SettingsLoadResult(settings: settings, origin: .migrated(fromVersion: version))
            }

            return SettingsLoadResult(settings: try SettingsStore.decode(data).normalized(), origin: .file)
        } catch {
            log.error("Settings file unreadable, falling back to defaults", .error(error))
            do {
                try backups.backUp(fileURL, name: "settings", label: "corrupt", at: now())
            } catch {
                log.error("Could not back up unreadable settings file", .error(error))
            }
            return SettingsLoadResult(settings: .defaults, origin: .recoveredFromCorruption)
        }
    }

    public func save(_ settings: JarvisSettings) throws {
        if let versionOnDisk = existingSchemaVersion(), versionOnDisk > JarvisSettings.currentSchemaVersion {
            throw SettingsStoreError.refusingToOverwriteNewerSchema(version: versionOnDisk)
        }
        var toSave = settings.normalized()
        toSave.schemaVersion = JarvisSettings.currentSchemaVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(toSave)
        try SecureFileIO.createPrivateDirectory(at: fileURL.deletingLastPathComponent())
        try SecureFileIO.writeAtomically(data, to: fileURL)
    }

    // MARK: - Вспомогательное

    private func existingSchemaVersion() -> Int? {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? SettingsStore.jsonObject(from: data) else { return nil }
        return json["schemaVersion"] as? Int
    }

    private static func jsonObject(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return object
    }

    private static func decode(_ data: Data) throws -> JarvisSettings {
        try JSONDecoder().decode(JarvisSettings.self, from: data)
    }
}
