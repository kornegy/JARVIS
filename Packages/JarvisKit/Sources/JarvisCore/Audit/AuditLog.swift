import Foundation

/// Чем закончилось действие.
public enum AuditOutcome: String, Codable, Sendable, CaseIterable {
    case succeeded
    case failed
    case cancelledByUser
    case deniedByPolicy
    case permissionMissing
}

/// Короткое описание цели действия для подробного режима журнала («Mail», «3 файла»).
///
/// Санитизация: убираются управляющие символы и переводы строк, пробелы схлопываются,
/// длина ограничена 80 символами. Пустое описание не создаётся.
/// Никогда не передавай сюда текст команды или содержимое файлов.
public struct AuditDetail: Sendable, Equatable {
    public static let maxLength = 80
    public let text: String

    public init?(_ raw: String) {
        let cleaned = raw.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }
        text = String(cleaned.prefix(AuditDetail.maxLength))
    }
}

/// Событие для записи в журнал.
public struct AuditEvent: Sendable {
    public var action: ActionIdentifier
    public var source: CommandSource
    public var risk: RiskLevel
    public var outcome: AuditOutcome
    public var confirmationRequired: Bool
    public var confirmed: Bool?
    public var detail: AuditDetail?

    public init(
        action: ActionIdentifier,
        source: CommandSource,
        risk: RiskLevel = .safe,
        outcome: AuditOutcome = .succeeded,
        confirmationRequired: Bool = false,
        confirmed: Bool? = nil,
        detail: AuditDetail? = nil
    ) {
        self.action = action
        self.source = source
        self.risk = risk
        self.outcome = outcome
        self.confirmationRequired = confirmationRequired
        self.confirmed = confirmed
        self.detail = detail
    }
}

/// Запись журнала аудита (то, что лежит на диске).
public struct AuditEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let action: ActionIdentifier
    public let source: CommandSource
    public let risk: RiskLevel
    public let outcome: AuditOutcome
    public let confirmationRequired: Bool
    public let confirmed: Bool?
    public let detail: String?
}

/// Журнал аудита: что JARVIS сделал, когда, по чьей команде и с каким результатом.
///
/// * Формат — JSON Lines, по файлу на день (UTC): `audit-2026-11-06.jsonl`, права 0600.
/// * Текст команд, ответы модели, пароли и содержимое файлов **не записываются**:
///   на вход принимается только `AuditEvent` с идентификатором действия.
/// * В режиме `.minimal` поле `detail` не сохраняется вовсе.
/// * Записи старше `retentionDays` удаляются `purgeExpired()`; `clearAll()` удаляет всё.
public actor AuditLog {
    public let directory: URL
    public private(set) var retentionDays: Int
    public private(set) var detailLevel: AuditDetailLevel

    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private static let filePrefix = "audit-"
    private static let fileExtension = "jsonl"

    public init(
        directory: URL,
        retentionDays: Int = 30,
        detailLevel: AuditDetailLevel = .minimal,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.retentionDays = AuditLog.clampRetention(retentionDays)
        self.detailLevel = detailLevel
        self.now = now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        self.calendar = calendar
    }

    public static func clampRetention(_ days: Int) -> Int { min(max(days, 1), 365) }

    public func configure(retentionDays: Int, detailLevel: AuditDetailLevel) {
        self.retentionDays = AuditLog.clampRetention(retentionDays)
        self.detailLevel = detailLevel
    }

    @discardableResult
    public func record(_ event: AuditEvent) throws -> AuditEntry {
        let entry = AuditEntry(
            id: UUID(),
            timestamp: now(),
            action: event.action,
            source: event.source,
            risk: event.risk,
            outcome: event.outcome,
            confirmationRequired: event.confirmationRequired,
            confirmed: event.confirmed,
            detail: detailLevel == .detailed ? event.detail?.text : nil
        )
        try SecureFileIO.createPrivateDirectory(at: directory)
        var line = try AuditLog.encoder().encode(entry)
        line.append(0x0A) // "\n"
        try SecureFileIO.append(line, to: fileURL(for: entry.timestamp))
        return entry
    }

    /// Последние записи, от новых к старым. Повреждённые строки пропускаются.
    public func recentEntries(limit: Int = 200) throws -> [AuditEntry] {
        guard limit > 0 else { return [] }
        let decoder = AuditLog.decoder()
        var result: [AuditEntry] = []
        for file in try logFiles().sorted(by: { $0.day > $1.day }) {
            let content = try String(contentsOf: file.url, encoding: .utf8)
            let entries = content
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { try? decoder.decode(AuditEntry.self, from: Data($0.utf8)) }
            // Внутри файла строки идут по времени, файлы перебираем от новых к старым —
            // значит, развернув строки файла, получаем порядок «от новых к старым» без сортировки.
            result.append(contentsOf: entries.reversed())
            if result.count >= limit { break }
        }
        return Array(result.prefix(limit))
    }

    /// Удаляет файлы старше срока хранения. Возвращает число удалённых файлов.
    @discardableResult
    public func purgeExpired() throws -> Int {
        let today = calendar.startOfDay(for: now())
        guard let cutoff = calendar.date(byAdding: .day, value: -(retentionDays - 1), to: today) else { return 0 }
        var removed = 0
        for file in try logFiles() where file.day < cutoff {
            try FileManager.default.removeItem(at: file.url)
            removed += 1
        }
        return removed
    }

    /// Удаляет весь журнал.
    public func clearAll() throws {
        for file in try logFiles() {
            try FileManager.default.removeItem(at: file.url)
        }
    }

    // MARK: - Файлы

    func fileURL(for date: Date) -> URL {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let dayString = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let name = AuditLog.filePrefix + dayString + "." + AuditLog.fileExtension
        return directory.appending(path: name, directoryHint: .notDirectory)
    }

    private func logFiles() throws -> [(url: URL, day: Date)] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path(percentEncoded: false)) else { return [] }
        return try fileManager
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .compactMap { (url: URL) -> (url: URL, day: Date)? in
                guard let parsed = self.parseDay(fromFileName: url.lastPathComponent) else { return nil }
                return (url: url, day: parsed)
            }
    }

    private func parseDay(fromFileName name: String) -> Date? {
        guard name.hasPrefix(AuditLog.filePrefix), name.hasSuffix("." + AuditLog.fileExtension) else { return nil }
        let stem = name.dropFirst(AuditLog.filePrefix.count).dropLast(AuditLog.fileExtension.count + 1)
        let numbers = stem.split(separator: "-").compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: numbers[0], month: numbers[1], day: numbers[2]))
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
