import Foundation
import Testing
@testable import JarvisCore

@Suite("Где тратится процессор")
struct CPUProfilerTests {
    @Test("Потоки получают понятные имена групп")
    func threadCategories() {
        #expect(CPUProfiler.category(forThreadName: CPUProfiler.mainThreadName) == "Главный поток: интерфейс и логика JARVIS")
        #expect(CPUProfiler.category(forThreadName: "") == "Потоки без имени: задачи Swift и фреймворков")
        #expect(CPUProfiler.category(forThreadName: "com.apple.audio.IOThread.client") == "Звук: захват с микрофона (Core Audio)")
        #expect(CPUProfiler.category(forThreadName: "com.apple.speech.analyzer") == "Распознавание речи: фреймворк Apple")
        #expect(CPUProfiler.category(forThreadName: "Espresso::ANERuntime") == "Нейросеть: Core ML")
        #expect(CPUProfiler.category(forThreadName: "com.apple.NSEventThread") == "com.apple.NSEventThread")
    }

    @Test("Службы речи узнаются по имени процесса")
    func speechServices() {
        #expect(CPUProfiler.isSpeechService("localspeechrecognition"))
        #expect(CPUProfiler.isSpeechService("SpeechSynthesisServerXPC"))
        #expect(!CPUProfiler.isSpeechService("WindowServer"))
    }

    @Test("Разбивка: проценты одного ядра, группировка, новые потоки")
    func breakdownMath() {
        let earlier = CPUSnapshot(
            uptime: 100,
            processCPU: 10,
            threads: [
                1: .init(name: CPUProfiler.mainThreadName, cpu: 5),
                2: .init(name: "", cpu: 3),
                3: .init(name: "", cpu: 1),
            ],
            meters: ["Подготовка звука": 0.5],
            services: [42: .init(name: "localspeechrecognition", cpu: 20)]
        )
        let later = CPUSnapshot(
            uptime: 102,
            processCPU: 10.5,
            threads: [
                1: .init(name: CPUProfiler.mainThreadName, cpu: 5.1),  // +0,1 с → 5 %
                2: .init(name: "", cpu: 3.2),                          // +0,2 с
                3: .init(name: "", cpu: 1.1),                          // +0,1 с
                4: .init(name: "", cpu: 0.1),                          // новый поток: +0,1 с
            ],
            meters: ["Подготовка звука": 0.52],
            services: [42: .init(name: "localspeechrecognition", cpu: 21)]
        )

        let breakdown = CPUProfiler.breakdown(from: earlier, to: later)
        #expect(breakdown.interval == 2)
        #expect(abs(breakdown.total - 25) < 0.001)
        #expect(breakdown.threads.map(\.name) == [
            "Потоки без имени: задачи Swift и фреймворков",
            "Главный поток: интерфейс и логика JARVIS",
        ])
        #expect(abs(breakdown.threads[0].percent - 20) < 0.001)
        #expect(abs(breakdown.threads[1].percent - 5) < 0.001)
        #expect(abs(breakdown.ownCode[0].percent - 1) < 0.001)
        #expect(abs(breakdown.speechServices[0].percent - 50) < 0.001)
        #expect(breakdown.report.contains("localspeechrecognition — 50.0 %"))
    }

    @Test("Нулевой интервал не делит на ноль")
    func zeroInterval() {
        let snapshot = CPUSnapshot(uptime: 1, processCPU: 1, threads: [:], meters: [:], services: [:])
        #expect(CPUProfiler.breakdown(from: snapshot, to: snapshot).total == 0)
    }

    @Test("Настоящий снимок: потоки процесса видны вместе с именами")
    func realSnapshotListsNamedThreads() {
        let started = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let worker = Thread {
            _ = pthread_setname_np("jarvis.test.worker")
            started.signal()
            finish.wait()
        }
        worker.start()
        started.wait()
        let snapshot = CPUProfiler.snapshot()
        finish.signal()

        #expect(snapshot.threads.count >= 2)
        #expect(snapshot.threads.values.contains { $0.name == "jarvis.test.worker" })
        #expect(snapshot.processCPU > 0)
    }

    @Test("Счётчик нашего кода считает только время работы")
    func meterMeasuresWork() {
        let meter = CPUMeter(name: "тест")
        let result = meter.measure { () -> Double in
            var accumulator = 0.0
            for index in 0..<2_000_000 { accumulator += sin(Double(index)) }
            return accumulator
        }
        #expect(result.isFinite)
        #expect(meter.total > 0)
    }
}
