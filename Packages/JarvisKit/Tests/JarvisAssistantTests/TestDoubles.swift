import Foundation
import JarvisCore
import JarvisTools
import Synchronization
@testable import JarvisAssistant

/// Подделка «закрыть приложение» (категория 2): считает, сколько раз действие выполнено.
final class FakeQuitTool: Tool {
    let descriptor = ToolDescriptor(
        name: StandardTools.quitApp,
        summary: "Закрыть приложение",
        parameters: [ParameterSpec(name: "name", summary: "Имя", type: .text(maxLength: 100))],
        risk: .consequential,
        effect: .local
    )
    private let runs = Mutex(0)

    var runCount: Int { runs.withLock { $0 } }

    func describe(_ arguments: ValidatedArguments, context: ToolContext) async throws -> String {
        "закрыть «\(arguments.text("name") ?? "")»"
    }

    func run(_ arguments: ValidatedArguments, context: ToolContext) async throws -> ToolOutcome {
        runs.withLock { $0 += 1 }
        return ToolOutcome(message: "Safari")
    }
}

/// Подделка распознавания: тест сам «произносит» фразы через `say`.
@MainActor
final class FakeSpeechInput: SpeechInputEngine {
    var isCapturing = false
    var activeModelName: String? { isCapturing ? "Fake" : nil }
    var status: SpeechModelStatus = .installed
    private(set) var forcedListening = false
    private(set) var finalizeCount = 0
    var startError: SpeechEngineError?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var lastConfiguration: SpeechInputConfiguration?
    private var continuation: AsyncStream<SpeechInputEvent>.Continuation?

    func modelStatus(for configuration: SpeechInputConfiguration) async -> SpeechModelStatus { status }

    func downloadModel(for configuration: SpeechInputConfiguration) async throws {
        status = .installed
    }

    func setForcedListening(_ forced: Bool) {
        forcedListening = forced
    }

    func finalize() async {
        finalizeCount += 1
    }

    func start(_ configuration: SpeechInputConfiguration) async throws -> AsyncStream<SpeechInputEvent> {
        if let startError { throw startError }
        startCount += 1
        lastConfiguration = configuration
        isCapturing = true
        let (stream, continuation) = AsyncStream.makeStream(of: SpeechInputEvent.self)
        self.continuation = continuation
        return stream
    }

    func stop() async {
        stopCount += 1
        isCapturing = false
        continuation?.finish()
        continuation = nil
    }

    func say(_ text: String, isFinal: Bool = true) {
        continuation?.yield(.transcript(Utterance(text: text, locale: Locale(identifier: "ru_RU")), isFinal: isFinal))
    }

    func emit(_ event: SpeechInputEvent) {
        continuation?.yield(event)
    }
}

@MainActor
final class FakeSpeechOutput: SpeechOutputEngine {
    private(set) var spoken: [String] = []
    private(set) var stopCount = 0

    func speak(_ text: String, settings: SpeechOutputSettings) async {
        spoken.append(text)
    }

    func stopSpeaking() {
        stopCount += 1
    }
}

@MainActor
final class FakePermission: PermissionAccess {
    var state: PermissionState
    var grantOnRequest: Bool
    private(set) var requestCount = 0

    init(state: PermissionState = .granted, grantOnRequest: Bool = true) {
        self.state = state
        self.grantOnRequest = grantOnRequest
    }

    func request() async -> Bool {
        requestCount += 1
        state = grantOnRequest ? .granted : .denied
        return grantOnRequest
    }
}

@MainActor
final class FakeSounds: FeedbackSounds {
    private(set) var played: [SoundCue] = []

    func play(_ cue: SoundCue) {
        played.append(cue)
    }
}

/// Часы, которые тест двигает вручную (используются только из одного теста).
final class ManualClock: @unchecked Sendable {
    var time: TimeInterval = 1000

    func advance(_ seconds: TimeInterval) {
        time += seconds
    }
}

struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "JarvisAssistantTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Ждёт выполнения условия (асинхронные события обрабатываются в отдельных задачах).
@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Фиксированная дата: 2026-11-06 12:00:00 UTC (пятница).
let fixedNoon = Date(timeIntervalSince1970: 1_793_966_400)
