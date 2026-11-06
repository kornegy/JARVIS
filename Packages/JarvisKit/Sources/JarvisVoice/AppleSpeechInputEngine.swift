import AVFoundation
import Foundation
import Speech
import JarvisAssistant
import JarvisCore
import JarvisSettings

/// Захват звука и распознавание речи **только на устройстве** через `SpeechAnalyzer` (macOS 26+).
///
/// * Модуль распознавания: `SpeechTranscriber`, если он поддерживает язык, иначе
///   `DictationTranscriber` (те же модели, что системная диктовка в on-device режиме;
///   языки, доступные только через сеть, он не поддерживает).
/// * `SpeechDetector` (детектор голоса) не даёт тратить ресурсы на тишину, а в режиме
///   постоянного прослушивания тихие фрагменты вообще не доходят до анализатора (`SpeechGate`).
/// * Звук живёт только в памяти: буферы с микрофона конвертируются и сразу передаются
///   анализатору, на диск ничего не пишется.
@MainActor
public final class AppleSpeechInputEngine: SpeechInputEngine {
    public private(set) var isCapturing = false
    public private(set) var activeModelName: String?
    private var session: RecognitionSession?

    public init() {}

    public func modelStatus(for configuration: SpeechInputConfiguration) async -> SpeechModelStatus {
        guard let choice = await TranscriberChoice.make(for: configuration.locale, preference: configuration.modelPreference) else {
            return .unsupportedLanguage
        }
        switch await AssetInventory.status(forModules: [choice.module]) {
        case .installed: return .installed
        case .supported: return .needsDownload
        case .downloading: return .downloading
        case .unsupported: return .unsupportedLanguage
        @unknown default: return .unsupportedLanguage
        }
    }

    public func downloadModel(for configuration: SpeechInputConfiguration) async throws {
        guard let choice = await TranscriberChoice.make(for: configuration.locale, preference: configuration.modelPreference) else {
            throw SpeechEngineError.languageNotSupported
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [choice.module]) {
            try await request.downloadAndInstall()
        }
    }

    public func start(_ configuration: SpeechInputConfiguration) async throws -> AsyncStream<SpeechInputEvent> {
        await stop()
        guard let choice = await TranscriberChoice.make(for: configuration.locale, preference: configuration.modelPreference) else {
            throw SpeechEngineError.languageNotSupported
        }
        let session = try await RecognitionSession.start(choice: choice, configuration: configuration)
        self.session = session
        isCapturing = true
        activeModelName = choice.name
        return session.events
    }

    public func stop() async {
        guard let session else { return }
        self.session = nil
        isCapturing = false
        activeModelName = nil
        await session.stop()
    }

    public func setForcedListening(_ forced: Bool) {
        session?.setForcedListening(forced)
    }

    public func finalize() async {
        await session?.finalize()
    }
}

/// Какой модуль распознавания использовать для языка.
enum TranscriberChoice: Sendable {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    var module: any SpeechModule {
        switch self {
        case .speech(let transcriber): transcriber
        case .dictation(let transcriber): transcriber
        }
    }

    var name: String {
        switch self {
        case .speech: "SpeechTranscriber"
        case .dictation: "DictationTranscriber"
        }
    }

    static func make(for locale: Locale, preference: RecognitionModelPreference) async -> TranscriberChoice? {
        switch preference {
        case .dictation:
            if let choice = await dictation(for: locale) { return choice }
            return await modern(for: locale)
        case .automatic, .modern:
            if let choice = await modern(for: locale) { return choice }
            return await dictation(for: locale)
        }
    }

    /// Промежуточные результаты нужны для живой расшифровки и определения конца фразы.
    /// Опции «отвечать как можно быстрее» (fastResults / frequentFinalization) не включаем:
    /// они заставляют модель чаще пересчитывать текст — лишняя нагрузка на процессор.
    private static func modern(for locale: Locale) async -> TranscriberChoice? {
        guard SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return nil
        }
        return .speech(SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        ))
    }

    private static func dictation(for locale: Locale) async -> TranscriberChoice? {
        guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) else { return nil }
        return .dictation(DictationTranscriber(
            locale: supported,
            contentHints: [],
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        ))
    }
}

/// Один сеанс захвата: AVAudioEngine → конвертер → SpeechAnalyzer → поток событий.
final class RecognitionSession: @unchecked Sendable {
    let events: AsyncStream<SpeechInputEvent>

    private let eventContinuation: AsyncStream<SpeechInputEvent>.Continuation
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let analyzer: SpeechAnalyzer
    private let audioEngine: AVAudioEngine
    private let converter: AudioBufferConverter
    private let lock = NSLock()
    private var resultsTask: Task<Void, Never>?
    private var configurationObserver: (any NSObjectProtocol)?
    private var isStopped = false
    private var forced = false

    // Используются только на аудиопотоке.
    private var gate: SpeechGate<AVAudioPCMBuffer>?
    private var framePosition: Int64 = 0
    private let timescale: CMTimeScale

    private init(
        events: AsyncStream<SpeechInputEvent>,
        eventContinuation: AsyncStream<SpeechInputEvent>.Continuation,
        inputContinuation: AsyncStream<AnalyzerInput>.Continuation,
        analyzer: SpeechAnalyzer,
        audioEngine: AVAudioEngine,
        converter: AudioBufferConverter,
        gate: SpeechGate<AVAudioPCMBuffer>?
    ) {
        self.events = events
        self.eventContinuation = eventContinuation
        self.inputContinuation = inputContinuation
        self.analyzer = analyzer
        self.audioEngine = audioEngine
        self.converter = converter
        self.gate = gate
        self.timescale = CMTimeScale(converter.outputFormat.sampleRate.rounded())
    }

    static func start(choice: TranscriberChoice, configuration: SpeechInputConfiguration) async throws -> RecognitionSession {
        let detector = SpeechDetector(
            detectionOptions: SpeechDetector.DetectionOptions(sensitivityLevel: sensitivityLevel(for: configuration.sensitivity)),
            reportResults: false
        )
        let modules: [any SpeechModule] = [detector, choice.module]
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw SpeechEngineError.modelNotInstalled
        }

        let audioEngine = AVAudioEngine()
        if let uid = configuration.inputDeviceUID {
            guard let deviceID = AudioInputDevices.deviceID(forUID: uid) else { throw SpeechEngineError.microphoneUnavailable }
            do {
                try audioEngine.inputNode.auAudioUnit.setDeviceID(deviceID)
            } catch {
                throw SpeechEngineError.microphoneUnavailable
            }
        }
        let inputFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw SpeechEngineError.microphoneUnavailable }

        let (inputSequence, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingNewest(512))
        let (events, eventContinuation) = AsyncStream.makeStream(of: SpeechInputEvent.self, bufferingPolicy: .bufferingNewest(128))
        // Постоянное прослушивание — фоновая работа; модели держим в памяти недолго, чтобы
        // повторное нажатие Push-to-Talk не загружало их заново.
        let options = SpeechAnalyzer.Options(
            priority: configuration.continuous ? .utility : .userInitiated,
            modelRetention: .lingering
        )
        let analyzer = SpeechAnalyzer(modules: modules, options: options)
        let gate: SpeechGate<AVAudioPCMBuffer>? = configuration.continuous
            ? SpeechGate(
                thresholdDecibels: AudioLevel.threshold(forSensitivity: configuration.sensitivity),
                hangoverFrames: Int64(analyzerFormat.sampleRate * 1.5),
                preRollChunks: 6
            )
            : nil
        let session = RecognitionSession(
            events: events,
            eventContinuation: eventContinuation,
            inputContinuation: inputContinuation,
            analyzer: analyzer,
            audioEngine: audioEngine,
            converter: AudioBufferConverter(outputFormat: analyzerFormat),
            gate: gate
        )

        session.consumeResults(of: choice, locale: configuration.locale)
        do {
            try await analyzer.start(inputSequence: inputSequence)
            try session.startAudio(inputFormat: inputFormat)
        } catch {
            await session.stop()
            throw (error as? SpeechEngineError) ?? SpeechEngineError.audioEngineFailed
        }
        return session
    }

    /// Чувствительность из настроек (0…1) → уровень детектора речи.
    /// У Apple `.low` — «мягкий» детектор (пропускает больше звука, слышит тихую речь),
    /// `.high` — «строгий». Поэтому высокая чувствительность → `.low`.
    static func sensitivityLevel(for sensitivity: Double) -> SpeechDetector.SensitivityLevel {
        switch sensitivity {
        case ..<0.34: .high
        case ..<0.67: .medium
        default: .low
        }
    }

    func setForcedListening(_ value: Bool) {
        lock.withLock { forced = value }
    }

    private var isForced: Bool {
        lock.withLock { forced }
    }

    /// Выдать окончательный текст по уже полученному звуку.
    func finalize() async {
        do {
            try await analyzer.finalize(through: nil)
        } catch {
            // Сеанс уже завершён — финализировать нечего.
        }
    }

    private func consumeResults(of choice: TranscriberChoice, locale: Locale) {
        let continuation = eventContinuation
        resultsTask = Task {
            do {
                switch choice {
                case .speech(let transcriber):
                    for try await result in transcriber.results {
                        continuation.yield(.transcript(Utterance(text: String(result.text.characters), locale: locale), isFinal: result.isFinal))
                    }
                case .dictation(let transcriber):
                    for try await result in transcriber.results {
                        continuation.yield(.transcript(Utterance(text: String(result.text.characters), locale: locale), isFinal: result.isFinal))
                    }
                }
            } catch is CancellationError {
                // Остановлено нами.
            } catch {
                let code: FailureCode = SpeechRecognitionAuthorization.isAuthorized
                    ? .speechModelUnavailable
                    : .speechRecognitionNotAuthorized
                continuation.yield(.failed(code))
            }
        }
    }

    private func startAudio(inputFormat: AVAudioFormat) throws {
        let input = audioEngine.inputNode
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: nil
        ) { [weak self] _ in
            self?.eventContinuation.yield(.interrupted)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            throw SpeechEngineError.microphoneUnavailable
        }
    }

    /// Вызывается на аудиопотоке для каждого буфера с микрофона. Только память, никакого диска.
    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converted = try? converter.convert(buffer) else { return }
        let startFrame = framePosition
        framePosition += Int64(converted.frameLength)

        guard gate != nil else {
            inputContinuation.yield(AnalyzerInput(buffer: converted))
            return
        }
        // Пока пользователь явно говорит команду, пропускаем всё (уровень «0 дБ» — громко).
        let level = isForced ? 0 : (AudioLevel.decibels(of: buffer) ?? 0)
        let wasOpen = gate?.isOpen ?? false
        let chunks = gate?.process(converted, startFrame: startFrame, frameCount: Int64(converted.frameLength), level: level) ?? []
        for chunk in chunks {
            let start = CMTime(value: CMTimeValue(chunk.startFrame), timescale: timescale)
            inputContinuation.yield(AnalyzerInput(buffer: chunk.buffer, bufferStartTime: start))
        }
        if wasOpen, gate?.isOpen == false {
            // Стало тихо: просим модель сразу выдать окончательный текст по услышанному,
            // а не ждать следующего звука.
            Task { [weak self] in await self?.finalize() }
        }
    }

    func stop() async {
        let shouldStop = lock.withLock { () -> Bool in
            if isStopped { return false }
            isStopped = true
            return true
        }
        guard shouldStop else { return }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        inputContinuation.finish()
        await analyzer.cancelAndFinishNow()
        resultsTask?.cancel()
        eventContinuation.finish()
    }
}
