import Foundation
import Synchronization
import Testing
@testable import JarvisCore

/// Запоминает строки лога в памяти.
final class RecordingLogSink: LogSink {
    struct Line: Sendable {
        let level: LogLevel
        let category: String
        let message: String
    }

    private let storage = Mutex<[Line]>([])

    var lines: [Line] { storage.withLock { $0 } }

    func write(level: LogLevel, category: StaticString, message: String) {
        storage.withLock { $0.append(Line(level: level, category: category.description, message: message)) }
    }
}

/// Ошибка, чьё описание содержит приватные данные.
private struct LeakyError: LocalizedError {
    let secret: String
    var errorDescription: String? { "не удалось открыть \(secret)" }
}

@Suite("Privacy-safe логгер")
struct JarvisLoggerTests {
    @Test("Сообщение и поля выводятся в формате «текст [ключ=значение]»")
    func rendersFields() {
        let sink = RecordingLogSink()
        let log = JarvisLogger(category: "test", sink: sink)
        log.info("Settings saved", .int("schemaVersion", 1), .bool("migrated", false), .token("mode", "local"))

        #expect(sink.lines.count == 1)
        #expect(sink.lines[0].level == .info)
        #expect(sink.lines[0].category == "test")
        #expect(sink.lines[0].message == "Settings saved [schemaVersion=1, migrated=false, mode=local]")
    }

    @Test("Сообщение без полей выводится как есть")
    func rendersPlainMessage() {
        let sink = RecordingLogSink()
        JarvisLogger(category: "test", sink: sink).notice("Assistant enabled")
        #expect(sink.lines.map(\.message) == ["Assistant enabled"])
    }

    @Test("От ошибки в лог попадают только тип и код — не текст")
    func errorsDoNotLeakDescriptions() {
        let sink = RecordingLogSink()
        let secret = "/Users/me/Documents/диплом.pdf"
        JarvisLogger(category: "test", sink: sink).error("Open failed", .error(LeakyError(secret: secret)))

        let message = sink.lines[0].message
        #expect(!message.contains(secret))
        #expect(!message.contains("диплом"))
        #expect(message.contains("LeakyError"))
    }

    @Test("Все уровни доходят до приёмника")
    func allLevels() {
        let sink = RecordingLogSink()
        let log = JarvisLogger(category: "test", sink: sink)
        log.debug("d")
        log.info("i")
        log.notice("n")
        log.error("e")
        log.fault("f")
        #expect(sink.lines.map(\.level) == [.debug, .info, .notice, .error, .fault])
    }
}
