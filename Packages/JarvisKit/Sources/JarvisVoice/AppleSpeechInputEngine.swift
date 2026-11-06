import AVFoundation
import Foundation
import Speech
import JarvisAssistant
import JarvisCore

/// Захват звука и распознавание речи **только на устройстве** через `SpeechAnalyzer` (macOS 26+).
///
/// * Модуль распознавания: `SpeechTranscriber`, если он поддерживает язык, иначе
///   `DictationTranscriber` (те же модели, что системная диктовка в on-device режиме;
///   языки, доступные только через сеть, он не поддерживает).
/// * `SpeechDetector` (детектор голоса) не даёт тратить ресурсы на тишину.
/// * Звук живёт только в памяти: буферы с микрофона конвертируются и сразу передаются
///   анализатору, на диск ничего не пишется.
@MainActor
public final class AppleSpeechInputEngine: SpeechInputEngine {
    public private(set) var isCapturing = false
    private var session: RecognitionSession?

    public init() {}

    public func modelStatus(for locale: Locale) async -> SpeechModelStatus {
        guard let choice = await TranscriberChoice.make(for: locale) else { return .unsupportedLanguage }
        switch await AssetInventory.status(forModules: [choice.module]) {
        case .installed: return .installed
        case .supported: return .needsDownload
        case .downloading: return .downloading
        case .unsupported: return .unsupportedLanguage
        @unknown default: return .unsupportedLanguage
        }
    }

    public func downloadModel(for locale: Locale) async throws {
        guard let choice = await TranscriberChoice.make(for: locale) else { throw SpeechEngineError.languageNotSupported }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [choice.module]) {
            try await request.downloadAndInstall()
        }
    }

    public func start(_ configuration: SpeechInputConfiguration) async throws -> AsyncStream<SpeechInputEvent> {
        await stop()
        guard let choice = await TranscriberChoice.make(for: configuration.locale) else {
            throw SpeechEngineError.languageNotSupported
        }
        let session = try await RecognitionSession.start(choice: choice, configuration: configuration)
        self.session = session
        isCapturing = true
        return session.events
    }

    public func stop() async {
        guard let session else { return }
        self.session = nil
        isCapturing = false
        await session.stop()
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

    static func make(for locale: Locale) async -> TranscriberChoice? {
        if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return .speech(SpeechTranscriber(locale: supported, preset: .progressiveTranscription))
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            return .dictation(DictationTranscriber(locale: supported, preset: .progressiveLongDictation))
        }
        return nil
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

    private init(
        events: AsyncStream<SpeechInputEvent>,
        eventContinuation: AsyncStream<SpeechInputEvent>.Continuation,
        inputContinuation: AsyncStream<AnalyzerInput>.Continuation,
        analyzer: SpeechAnalyzer,
        audioEngine: AVAudioEngine,
        converter: AudioBufferConverter
    ) {
        self.events = events
        self.eventContinuation = eventContinuation
        self.inputContinuation = inputContinuation
        self.analyzer = analyzer
        self.audioEngine = audioEngine
        self.converter = converter
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
        let analyzer = SpeechAnalyzer(modules: modules, options: nil)
        let session = RecognitionSession(
            events: events,
            eventContinuation: eventContinuation,
            inputContinuation: inputContinuation,
            analyzer: analyzer,
            audioEngine: audioEngine,
            converter: AudioBufferConverter(outputFormat: analyzerFormat)
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
    static func sensitivityLevel(for sensitivity: Double) -> SpeechDetector.SensitivityLevel {
        switch sensitivity {
        case ..<0.34: .low
        case ..<0.67: .medium
        default: .high
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
        inputContinuation.yield(AnalyzerInput(buffer: converted))
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
