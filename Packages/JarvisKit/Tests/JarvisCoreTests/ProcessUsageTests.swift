import Foundation
import Testing
@testable import JarvisCore

@Suite("Самодиагностика ресурсов")
struct ProcessUsageTests {
    @Test("Работа процессора видна в снимках, память известна")
    func measuresCPUAndMemory() {
        let before = ProcessUsage.sample()
        var accumulator = 0.0
        for index in 0..<3_000_000 {
            accumulator += sin(Double(index))
        }
        let after = ProcessUsage.sample()

        #expect(accumulator.isFinite)
        #expect(after.cpuTime > before.cpuTime)
        #expect(ProcessUsage.cpuPercent(from: before, to: after) > 0)
        #expect((after.memoryBytes ?? 0) > 1_000_000)
    }

    @Test("Нулевой интервал не делит на ноль")
    func zeroInterval() {
        let sample = ProcessUsageSample(cpuTime: 1, uptime: 10, memoryBytes: nil)
        #expect(ProcessUsage.cpuPercent(from: sample, to: sample) == 0)
    }
}
