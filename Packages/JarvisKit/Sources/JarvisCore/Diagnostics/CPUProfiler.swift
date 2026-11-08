import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Снимок процессорного времени: процесс JARVIS, его потоки, наши счётчики и системные
/// службы речи macOS. Сам по себе ничего не значит — сравниваются два снимка.
public struct CPUSnapshot: Sendable {
    struct Usage: Sendable, Equatable {
        let name: String
        /// Процессорное время с момента запуска потока/процесса, секунды.
        let cpu: TimeInterval
    }

    let uptime: TimeInterval
    let processCPU: TimeInterval
    /// Потоки JARVIS по идентификатору.
    let threads: [UInt64: Usage]
    /// Счётчики нашего кода по имени.
    let meters: [String: TimeInterval]
    /// Системные службы речи по pid.
    let services: [Int32: Usage]
}

/// Куда ушло процессорное время между двумя снимками (проценты одного ядра, как в
/// Мониторе активности: 100 % — одно ядро полностью).
public struct CPUBreakdown: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public let name: String
        public let percent: Double
        public var id: String { name }
    }

    public let interval: TimeInterval
    /// Весь процесс JARVIS.
    public let total: Double
    /// Потоки JARVIS, сгруппированные по назначению.
    public let threads: [Item]
    /// Наш код — часть времени потоков выше, замеренная изнутри.
    public let ownCode: [Item]
    /// Системные процессы macOS со словом «speech» в имени (они не входят в `total`).
    public let speechServices: [Item]

    /// Текстовый отчёт: только имена потоков/служб и проценты, без звука и текста.
    public var report: String {
        var lines = ["Нагрузка за \(Self.format(interval)) с: JARVIS — \(Self.format(total)) % ЦП"]
        lines.append("Потоки JARVIS:")
        lines += threads.map { "  • \($0.name) — \(Self.format($0.percent)) %" }
        lines.append("Наш код (входит в потоки выше):")
        lines += ownCode.map { "  • \($0.name) — \(Self.format($0.percent)) %" }
        lines.append("Системные службы речи macOS (отдельные процессы):")
        if speechServices.isEmpty {
            lines.append("  • не найдены или нет доступа")
        } else {
            lines += speechServices.map { "  • \($0.name) — \(Self.format($0.percent)) %" }
        }
        return lines.joined(separator: "\n")
    }

    public static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

/// Самодиагностика «где тратится процессор».
///
/// Только счётчики времени: имена потоков JARVIS, имена и время системных процессов
/// речи. Ничего не сохраняется и не отправляется — показывается в окне по запросу.
public enum CPUProfiler {
    /// Имя главного потока JARVIS (у главного потока macOS своего имени нет).
    public static let mainThreadName = "jarvis.main"

    /// Подписать главный поток, чтобы отличать его в разбивке.
    @MainActor
    public static func nameMainThread() {
        #if canImport(Darwin)
        _ = pthread_setname_np(mainThreadName)
        #endif
    }

    public static func snapshot() -> CPUSnapshot {
        CPUSnapshot(
            uptime: ProcessInfo.processInfo.systemUptime,
            processCPU: ProcessUsage.sample().cpuTime,
            threads: threadUsage(),
            meters: Dictionary(CPUMeter.all.map { ($0.name, $0.total) }, uniquingKeysWith: +),
            services: speechServiceUsage()
        )
    }

    public static func breakdown(from earlier: CPUSnapshot, to later: CPUSnapshot) -> CPUBreakdown {
        let interval = later.uptime - earlier.uptime
        guard interval > 0 else {
            return CPUBreakdown(interval: 0, total: 0, threads: [], ownCode: [], speechServices: [])
        }
        func percent(_ seconds: TimeInterval) -> Double { max(0, seconds) / interval * 100 }

        var threadGroups: [String: TimeInterval] = [:]
        for (id, now) in later.threads {
            threadGroups[category(forThreadName: now.name), default: 0] += delta(now.cpu, earlier.threads[id]?.cpu)
        }
        var serviceGroups: [String: TimeInterval] = [:]
        for (pid, now) in later.services {
            serviceGroups[now.name, default: 0] += delta(now.cpu, earlier.services[pid]?.cpu)
        }
        var meters: [String: TimeInterval] = [:]
        for (name, now) in later.meters {
            meters[name] = delta(now, earlier.meters[name])
        }

        return CPUBreakdown(
            interval: interval,
            total: percent(later.processCPU - earlier.processCPU),
            threads: items(threadGroups, percent: percent, minimum: 0.1),
            ownCode: items(meters, percent: percent, minimum: 0),
            speechServices: items(serviceGroups, percent: percent, minimum: 0.1)
        )
    }

    /// Понятное имя группы для потока. Имена потоков задают сами фреймворки.
    static func category(forThreadName name: String) -> String {
        let lowered = name.lowercased()
        if name == mainThreadName { return "Главный поток: интерфейс и логика JARVIS" }
        if lowered.isEmpty { return "Потоки без имени: задачи Swift и фреймворков" }
        if lowered.contains("audio") || lowered.contains("aurio") { return "Звук: захват с микрофона (Core Audio)" }
        if lowered.contains("speech") { return "Распознавание речи: фреймворк Apple" }
        if lowered.contains("espresso") || lowered.contains("coreml") || lowered.contains("e5rt")
            || lowered.hasPrefix("com.apple.ane") {
            return "Нейросеть: Core ML"
        }
        return name
    }

    /// Системный процесс, связанный с речью (распознавание, синтез).
    static func isSpeechService(_ name: String) -> Bool {
        name.lowercased().contains("speech")
    }

    /// Сколько времени добавилось. Если поток/процесс новый или идентификатор
    /// переиспользован (время уменьшилось) — всё его время приходится на интервал.
    private static func delta(_ now: TimeInterval, _ before: TimeInterval?) -> TimeInterval {
        guard let before, now >= before else { return now }
        return now - before
    }

    private static func items(
        _ groups: [String: TimeInterval],
        percent: (TimeInterval) -> Double,
        minimum: Double
    ) -> [CPUBreakdown.Item] {
        groups
            .map { CPUBreakdown.Item(name: $0.key, percent: percent($0.value)) }
            .filter { $0.percent >= minimum }
            .sorted { $0.percent == $1.percent ? $0.name < $1.name : $0.percent > $1.percent }
    }

    // MARK: - Системные вызовы

    private static func threadUsage() -> [UInt64: CPUSnapshot.Usage] {
        #if canImport(Darwin)
        let pid = getpid()
        var handles = [UInt64](repeating: 0, count: 1024)
        let bytes = handles.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes > 0 else { return [:] }
        let count = min(handles.count, Int(bytes) / MemoryLayout<UInt64>.stride)

        var result: [UInt64: CPUSnapshot.Usage] = [:]
        let size = Int32(MemoryLayout<proc_threadinfo>.size)
        for handle in handles.prefix(count) {
            var info = proc_threadinfo()
            guard proc_pidinfo(pid, PROC_PIDTHREADINFO, handle, &info, size) == size else { continue }
            let name = withUnsafeBytes(of: info.pth_name) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            // Время потока — в наносекундах.
            let nanoseconds = info.pth_user_time &+ info.pth_system_time
            result[handle] = CPUSnapshot.Usage(name: name, cpu: TimeInterval(nanoseconds) / 1_000_000_000)
        }
        return result
        #else
        return [:]
        #endif
    }

    private static func speechServiceUsage() -> [Int32: CPUSnapshot.Usage] {
        #if canImport(Darwin)
        var pids = [Int32](repeating: 0, count: 8192)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [:] }

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticksToSeconds = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        let ownPID = getpid()

        var result: [Int32: CPUSnapshot.Usage] = [:]
        for pid in pids.prefix(min(Int(count), pids.count)) where pid > 0 && pid != ownPID {
            var nameBuffer = [UInt8](repeating: 0, count: 256)
            let length = nameBuffer.withUnsafeMutableBytes { buffer in
                proc_name(pid, buffer.baseAddress, UInt32(buffer.count))
            }
            guard length > 0 else { continue }
            let name = String(decoding: nameBuffer.prefix(while: { $0 != 0 }), as: UTF8.self)
            guard isSpeechService(name) else { continue }

            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
                }
            }
            // Чужой процесс без доступа просто пропускаем.
            guard status == 0 else { continue }
            // Здесь время — в тиках системных часов, их переводим в секунды.
            let ticks = info.ri_user_time &+ info.ri_system_time
            result[pid] = CPUSnapshot.Usage(name: name, cpu: Double(ticks) * ticksToSeconds)
        }
        return result
        #else
        return [:]
        #endif
    }
}
