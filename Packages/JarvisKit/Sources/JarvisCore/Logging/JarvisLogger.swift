import Foundation
#if canImport(os)
import os
#endif

/// Уровень важности сообщения.
public enum LogLevel: Int, Sendable, Comparable, CaseIterable {
    case debug, info, notice, error, fault

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Значение, которое можно безопасно записать в лог.
///
/// Нарочно нет варианта «произвольная строка»: только числа, флаги, статические токены
/// и ошибки (от ошибки пишется только тип и код, без текста сообщения, потому что
/// сообщение может содержать путь к файлу или фрагмент команды).
public struct LogValue: Sendable {
    enum Storage: Sendable {
        case int(Int)
        case double(Double)
        case bool(Bool)
        case token(StaticString)
        case error(String)
    }

    let storage: Storage

    public static func int(_ value: Int) -> LogValue { LogValue(storage: .int(value)) }
    public static func double(_ value: Double) -> LogValue { LogValue(storage: .double(value)) }
    public static func bool(_ value: Bool) -> LogValue { LogValue(storage: .bool(value)) }
    public static func token(_ value: StaticString) -> LogValue { LogValue(storage: .token(value)) }
    public static func error(_ error: any Error) -> LogValue {
        LogValue(storage: .error(LogValue.describe(error)))
    }

    var rendered: String {
        switch storage {
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .bool(let value): value ? "true" : "false"
        case .token(let value): value.description
        case .error(let value): value
        }
    }

    /// Тип ошибки + домен/код. Текст (`localizedDescription`) не используется намеренно.
    static func describe(_ error: any Error) -> String {
        let typeName = String(reflecting: type(of: error))
        let nsError = error as NSError
        return "\(typeName)(domain: \(nsError.domain), code: \(nsError.code))"
    }
}

/// Поле лога: статический ключ + безопасное значение.
public struct LogField: Sendable {
    public let key: StaticString
    public let value: LogValue

    public init(_ key: StaticString, _ value: LogValue) {
        self.key = key
        self.value = value
    }

    public static func int(_ key: StaticString, _ value: Int) -> LogField { LogField(key, .int(value)) }
    public static func double(_ key: StaticString, _ value: Double) -> LogField { LogField(key, .double(value)) }
    public static func bool(_ key: StaticString, _ value: Bool) -> LogField { LogField(key, .bool(value)) }
    public static func token(_ key: StaticString, _ value: StaticString) -> LogField { LogField(key, .token(value)) }
    public static func error(_ error: any Error) -> LogField { LogField("error", .error(error)) }
}

/// Куда пишутся строки лога. В приложении — Unified Logging (os.Logger), в тестах — память.
public protocol LogSink: Sendable {
    func write(level: LogLevel, category: StaticString, message: String)
}

/// Privacy-safe логгер JARVIS — единственный разрешённый способ логирования
/// (правило проверяется `scripts/privacy-lint.sh`).
///
/// Сообщение — только `StaticString`, то есть строковый литерал, известный при компиляции.
/// Поэтому записать в лог расшифровку команды, ответ модели или содержимое файла
/// невозможно в принципе: такой код не скомпилируется.
///
/// ```swift
/// let log = JarvisLogger(category: "settings")
/// log.info("Settings saved", .int("schemaVersion", 1))
/// ```
public struct JarvisLogger: Sendable {
    public static let subsystem = "io.github.kornegy.jarvis"

    private let category: StaticString
    private let sink: any LogSink

    public init(category: StaticString, sink: (any LogSink)? = nil) {
        self.category = category
        self.sink = sink ?? JarvisLogger.defaultSink(category: category)
    }

    public func debug(_ message: StaticString, _ fields: LogField...) { log(.debug, message, fields) }
    public func info(_ message: StaticString, _ fields: LogField...) { log(.info, message, fields) }
    public func notice(_ message: StaticString, _ fields: LogField...) { log(.notice, message, fields) }
    public func error(_ message: StaticString, _ fields: LogField...) { log(.error, message, fields) }
    public func fault(_ message: StaticString, _ fields: LogField...) { log(.fault, message, fields) }

    private func log(_ level: LogLevel, _ message: StaticString, _ fields: [LogField]) {
        sink.write(level: level, category: category, message: JarvisLogger.render(message, fields))
    }

    static func render(_ message: StaticString, _ fields: [LogField]) -> String {
        guard !fields.isEmpty else { return message.description }
        let pairs = fields.map { "\($0.key.description)=\($0.value.rendered)" }
        return message.description + " [" + pairs.joined(separator: ", ") + "]"
    }

    private static func defaultSink(category: StaticString) -> any LogSink {
        #if canImport(os)
        return OSLogSink(category: category)
        #else
        return NullLogSink()
        #endif
    }
}

/// Отбрасывает всё. Используется там, где Unified Logging недоступен.
public struct NullLogSink: LogSink {
    public init() {}
    public func write(level: LogLevel, category: StaticString, message: String) {}
}

#if canImport(os)
/// Пишет в Unified Logging. Все части сообщения статические или числовые (см. `LogValue`),
/// поэтому помечать их `.public` безопасно.
final class OSLogSink: LogSink, @unchecked Sendable {
    private let logger: Logger

    init(category: StaticString) {
        logger = Logger(subsystem: JarvisLogger.subsystem, category: category.description)
    }

    func write(level: LogLevel, category: StaticString, message: String) {
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .notice: logger.notice("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        case .fault: logger.fault("\(message, privacy: .public)")
        }
    }
}
#endif
