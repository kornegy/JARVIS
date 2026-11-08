import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Снимок потребления ресурсов процессом JARVIS.
public struct ProcessUsageSample: Sendable, Equatable {
    /// Суммарное процессорное время (пользовательское + системное), секунды.
    public let cpuTime: TimeInterval
    /// Монотонное время снимка, секунды.
    public let uptime: TimeInterval
    /// Физическая память процесса (как «Память» в Мониторе активности), байты.
    public let memoryBytes: UInt64?
}

/// Самодиагностика: сколько процессора и памяти тратит JARVIS.
///
/// Нужна, чтобы измерять, а не угадывать (docs/PerformanceTargets.md). Считает только
/// собственный процесс; системные службы распознавания речи сюда не входят.
public enum ProcessUsage {
    public static func sample() -> ProcessUsageSample {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = seconds(usage.ru_utime) + seconds(usage.ru_stime)
        return ProcessUsageSample(cpuTime: cpu, uptime: ProcessInfo.processInfo.systemUptime, memoryBytes: footprint())
    }

    /// Загрузка процессора между двумя снимками в процентах одного ядра
    /// (как в Мониторе активности: 100 % — одно ядро полностью).
    public static func cpuPercent(from earlier: ProcessUsageSample, to later: ProcessUsageSample) -> Double {
        let wall = later.uptime - earlier.uptime
        guard wall > 0 else { return 0 }
        return max(0, (later.cpuTime - earlier.cpuTime) / wall * 100)
    }

    private static func seconds(_ value: timeval) -> TimeInterval {
        TimeInterval(value.tv_sec) + TimeInterval(value.tv_usec) / 1_000_000
    }

    private static func footprint() -> UInt64? {
        #if canImport(Darwin)
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, rebound)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
        #else
        return nil
        #endif
    }
}
