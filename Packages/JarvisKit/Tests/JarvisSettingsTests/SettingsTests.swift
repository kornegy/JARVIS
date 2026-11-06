import Foundation
import Testing
@testable import JarvisCore
@testable import JarvisSettings

private struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "JarvisSettingsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var settingsFile: URL { url.appending(path: "settings.json") }
    var backups: URL { url.appending(path: "backups", directoryHint: .isDirectory) }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

private let fixedNow = Date(timeIntervalSince1970: 1_793_966_400)

@Suite("Настройки: значения по умолчанию")
struct SettingsDefaultsTests {
    @Test("По умолчанию настройки приватны")
    func privacyByDefault() {
        let settings = JarvisSettings.defaults
        #expect(settings.ai.mode == .local)
        #expect(settings.ai.cloudProvider == .none)
        #expect(settings.ai.askBeforeEachCloudRequest)
        #expect(!settings.ai.cloudAllowed(privacyMode: settings.privacy.privacyMode))
        #expect(settings.privacy.auditDetail == .minimal)
        #expect(settings.voice.listeningMode == .pushToTalk)
        #expect(settings.confirmations.confirmConsequentialActions)
        #expect(!settings.confirmations.allowVoiceConfirmationForDangerousActions)
        #expect(settings.schemaVersion == JarvisSettings.currentSchemaVersion)
    }

    @Test("Privacy Mode запрещает облако даже при выбранном провайдере")
    func privacyModeBlocksCloud() {
        var ai = AISettings()
        ai.mode = .hybrid
        ai.cloudProvider = .anthropic
        #expect(ai.cloudAllowed(privacyMode: false))
        #expect(!ai.cloudAllowed(privacyMode: true))
        ai.mode = .local
        #expect(!ai.cloudAllowed(privacyMode: false))
    }

    @Test("Нормализация приводит значения к допустимым диапазонам")
    func normalization() {
        var settings = JarvisSettings()
        settings.general.assistantName = "  \n "
        settings.voice.microphoneSensitivity = 7
        settings.voice.speechRate = -1
        settings.voice.endOfSpeechSilenceSeconds = 100
        settings.voice.wakePhrases = ["  ", ""]
        settings.privacy.auditRetentionDays = 0
        settings.privacy.conversationContextMinutes = 999
        settings.personality.humor = 2

        let normalized = settings.normalized()
        #expect(normalized.general.assistantName == GeneralSettings().assistantName)
        #expect(normalized.voice.microphoneSensitivity == 1)
        #expect(normalized.voice.speechRate == 0)
        #expect(normalized.voice.endOfSpeechSilenceSeconds == 3)
        #expect(normalized.voice.wakePhrases == VoiceSettings().wakePhrases)
        #expect(normalized.privacy.auditRetentionDays == 1)
        #expect(normalized.privacy.conversationContextMinutes == 30)
        #expect(normalized.personality.humor == 1)
    }

    @Test("Имя ассистента обрезается до лимита")
    func assistantNameLimit() {
        var settings = JarvisSettings()
        settings.general.assistantName = String(repeating: "Ж", count: 100)
        #expect(settings.normalized().general.assistantName.count == GeneralSettings.maxNameLength)
    }
}

@Suite("Настройки: хранение и миграции")
struct SettingsStoreTests {
    @Test("Нет файла — значения по умолчанию")
    func missingFileGivesDefaults() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let result = SettingsStore(fileURL: temp.settingsFile, backupsDirectory: temp.backups).load()
        #expect(result.origin == .defaults)
        #expect(result.settings == .defaults)
    }

    @Test("Сохранение и загрузка дают те же настройки; файл доступен только владельцу")
    func roundTrip() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let store = SettingsStore(fileURL: temp.settingsFile, backupsDirectory: temp.backups)
        var settings = JarvisSettings()
        settings.general.assistantName = "Пятница"
        settings.privacy.privacyMode = true
        settings.voice.listeningMode = .wakeWord
        settings.personality.humor = 0.9

        try store.save(settings)
        let result = store.load()

        #expect(result.origin == .file)
        #expect(result.settings == settings)
        #expect(try SecureFileIO.posixPermissions(of: temp.settingsFile) == 0o600)
    }

    @Test("Отсутствующие поля (файл старой версии приложения) получают значения по умолчанию")
    func missingFieldsUseDefaults() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let json = #"{"schemaVersion": 1, "general": {"assistantName": "Пятница"}}"#
        try Data(json.utf8).write(to: temp.settingsFile)

        let result = SettingsStore(fileURL: temp.settingsFile, backupsDirectory: temp.backups).load()

        #expect(result.origin == .file)
        #expect(result.settings.general.assistantName == "Пятница")
        #expect(result.settings.general.showMainWindowAtLaunch == GeneralSettings().showMainWindowAtLaunch)
        #expect(result.settings.ai == AISettings())
        #expect(result.settings.voice == VoiceSettings())
    }

    @Test("Повреждённый файл: резервная копия + значения по умолчанию")
    func corruptedFileIsBackedUp() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        try Data("{ это не JSON".utf8).write(to: temp.settingsFile)

        let result = SettingsStore(fileURL: temp.settingsFile, backupsDirectory: temp.backups, now: { fixedNow }).load()

        #expect(result.origin == .recoveredFromCorruption)
        #expect(result.settings == .defaults)
        let backups = try FileBackups(directory: temp.backups).backups(name: "settings")
        #expect(backups.count == 1)
        #expect(backups.first?.lastPathComponent.contains("corrupt") == true)
    }

    @Test("Неверный тип поля считается повреждением")
    func wrongFieldTypeIsCorruption() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let json = #"{"schemaVersion": 1, "privacy": {"privacyMode": "да"}}"#
        try Data(json.utf8).write(to: temp.settingsFile)

        let result = SettingsStore(fileURL: temp.settingsFile, backupsDirectory: temp.backups).load()
        #expect(result.origin == .recoveredFromCorruption)
    }

    @Test("Файл более новой версии не перезаписывается")
    func newerSchemaIsProtected() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let future = JarvisSettings.currentSchemaVersion + 1
        let json = #"{"schemaVersion": \#(future), "general": {"assistantName": "Пятница"}}"#
        try Data(json.utf8).write(to: temp.settingsFile)
        let store = SettingsStore(fileURL: temp.settingsFile, backupsDirectory: temp.backups)

        let result = store.load()
        #expect(result.origin == .newerSchema(version: future))
        #expect(result.settings.general.assistantName == "Пятница")

        #expect(throws: SettingsStoreError.refusingToOverwriteNewerSchema(version: future)) {
            try store.save(result.settings)
        }
        #expect(try String(contentsOf: temp.settingsFile, encoding: .utf8) == json)
    }

    @Test("Миграция старой схемы: резервная копия, шаги по порядку, новая версия на диске")
    func migrationRunsStepsAndBacksUp() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        // Имитируем файл версии 0, где имя хранилось в поле «name».
        let json = #"{"schemaVersion": 0, "general": {"name": "Пятница"}}"#
        try Data(json.utf8).write(to: temp.settingsFile)
        let migrator = SettingsMigrator(steps: [
            0: { json in
                if var general = json["general"] as? [String: Any] {
                    general["assistantName"] = general.removeValue(forKey: "name")
                    json["general"] = general
                }
            },
        ])
        let store = SettingsStore(fileURL: temp.settingsFile, backupsDirectory: temp.backups, migrator: migrator, now: { fixedNow })

        let result = store.load()

        #expect(result.origin == .migrated(fromVersion: 0))
        #expect(result.settings.general.assistantName == "Пятница")
        let backups = try FileBackups(directory: temp.backups).backups(name: "settings")
        #expect(backups.first?.lastPathComponent == "settings.v0.1793966400.json")
        // На диске теперь текущая версия схемы.
        #expect(store.load().origin == .file)
    }

    @Test("Нет шага миграции — ошибка, а не тихая потеря данных")
    func missingMigrationStep() {
        var json: [String: Any] = ["schemaVersion": 0]
        #expect(throws: SettingsMigrator.MigrationError.missingStep(fromVersion: 0)) {
            try SettingsMigrator.standard.migrate(&json, from: 0, to: 1)
        }
    }
}
