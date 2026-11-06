import Foundation
import Synchronization
import Testing
@testable import JarvisCore

/// Управляемые часы для тестов.
final class TestClock: Sendable {
    private let current: Mutex<Date>

    init(_ date: Date) {
        current = Mutex(date)
    }

    var now: Date { current.withLock { $0 } }

    func set(_ date: Date) {
        current.withLock { $0 = date }
    }
}

@Suite("Журнал аудита")
struct AuditLogTests {
    @Test("Запись и чтение: от новых к старым")
    func recordAndRead() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = TestClock(fixedDate())
        let log = AuditLog(directory: directory.url, now: { clock.now })

        try await log.record(AuditEvent(action: "assistant.enable", source: .userInterface))
        clock.set(fixedDate(seconds: 5))
        try await log.record(AuditEvent(action: "apps.open", source: .voicePushToTalk, outcome: .failed))

        let entries = try await log.recentEntries()
        #expect(entries.map(\.action.rawValue) == ["apps.open", "assistant.enable"])
        #expect(entries[0].outcome == .failed)
        #expect(entries[0].source == .voicePushToTalk)
        #expect(entries[0].timestamp == fixedDate(seconds: 5))
    }

    @Test("Минимальный режим не сохраняет описание цели")
    func minimalModeDropsDetail() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let log = AuditLog(directory: directory.url, detailLevel: .minimal, now: { fixedDate() })

        try await log.record(AuditEvent(action: "apps.open", source: .typedText, detail: AuditDetail("Mail")))

        let entries = try await log.recentEntries()
        #expect(entries.first?.detail == nil)
        let raw = try String(contentsOf: directory.url.appending(path: "audit-2026-11-06.jsonl"), encoding: .utf8)
        #expect(!raw.contains("Mail"))
    }

    @Test("Подробный режим сохраняет санитизированное описание")
    func detailedModeKeepsSanitizedDetail() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let log = AuditLog(directory: directory.url, detailLevel: .detailed, now: { fixedDate() })

        try await log.record(AuditEvent(action: "apps.open", source: .typedText, detail: AuditDetail("  Mail\n\u{0007}app  ")))

        let entries = try await log.recentEntries()
        #expect(entries.first?.detail == "Mail app")
    }

    @Test("Описание цели ограничено по длине и не бывает пустым")
    func auditDetailSanitization() {
        #expect(AuditDetail("   \n\t ") == nil)
        let long = AuditDetail(String(repeating: "я", count: 500))
        #expect(long?.text.count == AuditDetail.maxLength)
    }

    @Test("Файлы журнала доступны только владельцу")
    func filePermissions() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let log = AuditLog(directory: directory.url, now: { fixedDate() })
        try await log.record(AuditEvent(action: "assistant.enable", source: .userInterface))

        let file = directory.url.appending(path: "audit-2026-11-06.jsonl")
        #expect(try SecureFileIO.posixPermissions(of: file) == 0o600)
    }

    @Test("Старые записи удаляются по сроку хранения")
    func retentionPurge() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = TestClock(fixedDate(daysFromBase: -40))
        let log = AuditLog(directory: directory.url, retentionDays: 30, now: { clock.now })

        try await log.record(AuditEvent(action: "assistant.enable", source: .userInterface)) // 40 дней назад
        clock.set(fixedDate(daysFromBase: -29))
        try await log.record(AuditEvent(action: "assistant.disable", source: .userInterface)) // в пределах срока
        clock.set(fixedDate())
        try await log.record(AuditEvent(action: "assistant.enable", source: .userInterface)) // сегодня

        let removed = try await log.purgeExpired()
        #expect(removed == 1)
        let remaining = try await log.recentEntries()
        #expect(remaining.count == 2)
    }

    @Test("Очистка удаляет весь журнал")
    func clearAll() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let log = AuditLog(directory: directory.url, now: { fixedDate() })
        try await log.record(AuditEvent(action: "assistant.enable", source: .userInterface))

        try await log.clearAll()
        let entries = try await log.recentEntries()
        #expect(entries.isEmpty)
    }

    @Test("Повреждённые строки пропускаются")
    func corruptedLinesAreSkipped() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let log = AuditLog(directory: directory.url, now: { fixedDate() })
        try await log.record(AuditEvent(action: "assistant.enable", source: .userInterface))
        let file = directory.url.appending(path: "audit-2026-11-06.jsonl")
        try SecureFileIO.append(Data("{not json}\n".utf8), to: file)

        let entries = try await log.recentEntries()
        #expect(entries.count == 1)
    }

    @Test("Срок хранения ограничен 1…365 днями")
    func retentionIsClamped() {
        #expect(AuditLog.clampRetention(0) == 1)
        #expect(AuditLog.clampRetention(1000) == 365)
        #expect(AuditLog.clampRetention(30) == 30)
    }
}

@Suite("Идентификаторы действий")
struct ActionIdentifierTests {
    @Test("Допустимые идентификаторы", arguments: ["apps.open", "files.move_to_trash", "assistant.enable", "a.b.c", "system.volume2"])
    func valid(raw: String) {
        #expect(ActionIdentifier(raw) != nil)
    }

    @Test("Недопустимые идентификаторы", arguments: ["", "apps", "Apps.open", "apps.", ".open", "apps..open", "apps.open now", "apps.открыть", "1apps.open", "apps.open;rm"])
    func invalid(raw: String) {
        #expect(ActionIdentifier(raw) == nil)
    }

    @Test("Идентификатор кодируется строкой и проверяется при декодировании")
    func codable() throws {
        let identifier: ActionIdentifier = "apps.open"
        let data = try JSONEncoder().encode([identifier])
        #expect(String(decoding: data, as: UTF8.self) == "[\"apps.open\"]")
        #expect(try JSONDecoder().decode([ActionIdentifier].self, from: data) == [identifier])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([ActionIdentifier].self, from: Data("[\"bad name\"]".utf8))
        }
    }
}
