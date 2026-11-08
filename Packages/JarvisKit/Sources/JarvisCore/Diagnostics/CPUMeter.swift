import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#endif

/// Счётчик процессорного времени, которое тратит **наш** код в горячих местах.
///
/// Меряет время именно потока (`CLOCK_THREAD_CPUTIME_ID`), а не часы: ожидание и сон
/// не считаются. Сам замер стоит около микросекунды, поэтому его можно держать включённым
/// всегда — в том числе на аудиопотоке.
public final class CPUMeter: Sendable {
    /// Подготовка звука с микрофона: конвертация, ворота тишины, передача анализатору.
    public static let audio = CPUMeter(name: "Подготовка звука")
    /// Обработка распознанного текста: перевод в строку, поиск фразы-активатора, сборка команды.
    public static let transcripts = CPUMeter(name: "Обработка распознанного текста")
    /// Все счётчики — для отчёта.
    public static let all = [audio, transcripts]

    public let name: String
    private let nanoseconds = Atomic<UInt64>(0)

    public init(name: String) {
        self.name = name
    }

    /// Выполнить `body` и добавить потраченное процессорное время к счётчику.
    @discardableResult
    public func measure<T>(_ body: () throws -> T) rethrows -> T {
        let start = Self.threadTime()
        defer { _ = nanoseconds.wrappingAdd(Self.threadTime() &- start, ordering: .relaxed) }
        return try body()
    }

    /// Сколько всего процессорного времени насчитано, секунды.
    public var total: TimeInterval {
        TimeInterval(nanoseconds.load(ordering: .relaxed)) / 1_000_000_000
    }

    private static func threadTime() -> UInt64 {
        #if canImport(Darwin)
        clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        #else
        0
        #endif
    }
}
