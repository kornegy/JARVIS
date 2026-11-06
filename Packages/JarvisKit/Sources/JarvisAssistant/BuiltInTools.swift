import Foundation
import JarvisCore
import JarvisTools

/// Встроенные инструменты, которым не нужны разрешения macOS.
public enum BuiltInTools {
    public static let currentTime: ToolName = "info.time"
    public static let currentDate: ToolName = "info.date"

    /// Реестр со встроенными инструментами.
    public static func makeRegistry(
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current
    ) throws -> ToolRegistry {
        var registry = ToolRegistry()
        try registry.register(CurrentTimeTool(now: now, timeZone: timeZone))
        try registry.register(CurrentDateTool(now: now, timeZone: timeZone))
        return registry
    }
}

/// «Который час?» — категория 1, только чтение.
struct CurrentTimeTool: Tool {
    let now: @Sendable () -> Date
    let timeZone: TimeZone

    var descriptor: ToolDescriptor {
        ToolDescriptor(name: BuiltInTools.currentTime, summary: "Текущее время на этом Mac.", risk: .safe, effect: .readOnly)
    }

    func run(_ arguments: ValidatedArguments, context: ToolContext) async throws -> ToolOutcome {
        ToolOutcome(message: Self.format(now(), locale: context.locale, timeZone: timeZone))
    }

    static func format(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: Calendar(identifier: .gregorian), timeZone: timeZone)
        return date.formatted(style)
    }
}

/// «Какое сегодня число?» — категория 1, только чтение.
struct CurrentDateTool: Tool {
    let now: @Sendable () -> Date
    let timeZone: TimeZone

    var descriptor: ToolDescriptor {
        ToolDescriptor(name: BuiltInTools.currentDate, summary: "Сегодняшняя дата и день недели.", risk: .safe, effect: .readOnly)
    }

    func run(_ arguments: ValidatedArguments, context: ToolContext) async throws -> ToolOutcome {
        ToolOutcome(message: Self.format(now(), locale: context.locale, timeZone: timeZone))
    }

    static func format(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: Calendar(identifier: .gregorian), timeZone: timeZone)
            .weekday(.wide)
            .day()
            .month(.wide)
        return date.formatted(style)
    }
}
