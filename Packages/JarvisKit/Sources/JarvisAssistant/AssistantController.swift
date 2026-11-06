import Foundation
import Observation
import JarvisAI
import JarvisCore
import JarvisSettings
import JarvisTools

/// Проблема, о которой нужно сказать пользователю (с понятным действием).
public enum AssistantProblem: Sendable, Equatable {
    case microphoneDenied
    case speechRecognitionDenied
    case speechModelMissing
    case speechModelDownloading
    case speechModelDownloadFailed
    case languageNotSupported
    case microphoneUnavailable

    public var message: String {
        switch self {
        case .microphoneDenied:
            "Нет доступа к микрофону. Разрешите его в «Системные настройки → Конфиденциальность и безопасность → Микрофон»."
        case .speechRecognitionDenied:
            "macOS не разрешает распознавание речи. Разрешите его — распознавание всё равно идёт только на этом Mac."
        case .speechModelMissing:
            "Для распознавания нужна языковая модель Apple. Её нужно скачать один раз; звук и текст при этом никуда не отправляются."
        case .speechModelDownloading:
            "Языковая модель скачивается. Попробуйте чуть позже."
        case .speechModelDownloadFailed:
            "Не удалось скачать языковую модель. Проверьте интернет и попробуйте снова."
        case .languageNotSupported:
            "Этот язык не поддерживается для распознавания на устройстве. Выберите другой язык в настройках."
        case .microphoneUnavailable:
            "Не удалось запустить микрофон. Проверьте выбранное устройство в настройках."
        }
    }
}

/// Оркестратор ассистента («App Core»): связывает микрофон, распознавание, сборку команды,
/// обработку, ответ голосом и машину состояний.
///
/// Не зависит от macOS-фреймворков — все системные части приходят через протоколы
/// (`SpeechInputEngine`, `SpeechOutputEngine`, …), поэтому весь сценарий тестируется в CI.
///
/// Приватность: распознанный текст живёт только в памяти (`liveTranscript`, `lastReply`)
/// и очищается; в журнал попадают только идентификаторы действий.
@MainActor
@Observable
public final class AssistantController {
    public private(set) var machine: AssistantStateMachine
    /// Идёт ли реальный захват звука (для индикатора микрофона).
    public private(set) var isMicrophoneCapturing = false
    /// Что сейчас распознано (только во время прослушивания).
    public private(set) var liveTranscript: String?
    /// Последний ответ (очищается через несколько минут).
    public private(set) var lastReply: String?
    public private(set) var problem: AssistantProblem?
    public private(set) var isDownloadingModel = false

    public var state: AssistantState { machine.state }

    /// Какая модель распознавания сейчас работает (для диагностики).
    public var activeSpeechModelName: String? { speechInput.activeModelName }

    /// Голосовая команда изменила Privacy Mode — приложение сохраняет настройку.
    @ObservationIgnored public var onPrivacyModeRequest: ((Bool, CommandSource) -> Void)?
    /// В журнал добавлена запись — интерфейс может обновить список.
    @ObservationIgnored public var onActivityRecorded: (() -> Void)?

    private let speechInput: any SpeechInputEngine
    private let speechOutput: any SpeechOutputEngine
    private let microphone: any PermissionAccess
    private let speechRecognition: any PermissionAccess
    private let sounds: any FeedbackSounds
    private let processor: CommandProcessor
    private let auditLog: AuditLog
    private let now: () -> TimeInterval
    private let log = JarvisLogger(category: "assistant")

    @ObservationIgnored private var settings: JarvisSettings
    @ObservationIgnored private var assembler: UtteranceAssembler
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var replyClearTask: Task<Void, Never>?
    @ObservationIgnored private var isStartingEngine = false

    public init(
        settings: JarvisSettings,
        speechInput: any SpeechInputEngine,
        speechOutput: any SpeechOutputEngine,
        microphone: any PermissionAccess,
        speechRecognition: any PermissionAccess,
        sounds: any FeedbackSounds,
        processor: CommandProcessor,
        auditLog: AuditLog,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.settings = settings
        self.speechInput = speechInput
        self.speechOutput = speechOutput
        self.microphone = microphone
        self.speechRecognition = speechRecognition
        self.sounds = sounds
        self.processor = processor
        self.auditLog = auditLog
        self.now = now
        self.machine = AssistantStateMachine(listeningMode: settings.voice.listeningMode)
        self.assembler = UtteranceAssembler(
            matcher: WakePhraseMatcher(phrases: settings.voice.wakePhrases),
            timing: UtteranceAssembler.Timing(endOfSpeechSilence: settings.voice.endOfSpeechSilenceSeconds),
            locale: settings.voice.locale
        )
    }

    // MARK: - Управление

    public func enable() async {
        guard machine.handle(.enable) else { return }
        problem = nil
        await record("assistant.enable", source: .userInterface)
        await reconcileListening()
    }

    public func disable(source: CommandSource = .userInterface) async {
        guard machine.state != .disabled else { return }
        machine.handle(.disable)
        speechOutput.stopSpeaking()
        cancelCapture()
        problem = nil
        await stopEngine()
        await record("assistant.disable", source: source)
    }

    public func toggleMicrophonePause() async {
        if machine.isMicrophonePaused {
            await resumeMicrophone()
        } else {
            await pauseMicrophone(source: .userInterface)
        }
    }

    public func pauseMicrophone(source: CommandSource) async {
        guard machine.handle(.pauseMicrophone) else { return }
        cancelCapture()
        await record("microphone.pause", source: source)
        await reconcileListening()
    }

    public func resumeMicrophone() async {
        guard machine.handle(.resumeMicrophone) else { return }
        await record("microphone.resume", source: .userInterface)
        await reconcileListening()
    }

    /// Клавиша Push-to-Talk нажата.
    public func pushToTalkPressed() async {
        await beginManualCapture(trigger: .pushToTalkHold)
    }

    /// Клавиша Push-to-Talk отпущена.
    public func pushToTalkReleased() {
        guard assembler.captureTrigger == .pushToTalkHold else { return }
        assembler.releaseCapture(at: now())
        // Попросить окончательный текст сразу, не дожидаясь паузы.
        Task { [weak self] in await self?.speechInput.finalize() }
    }

    /// Кнопка «Говорить»: слушать до паузы.
    public func startListening() async {
        await beginManualCapture(trigger: .manualTap)
    }

    /// Остановить прослушивание без выполнения команды.
    public func cancelListening() async {
        guard machine.state == .listening else { return }
        cancelCapture()
        machine.handle(.listeningCancelled)
        await reconcileListening()
    }

    /// Команда, набранная текстом. Обрабатывается так же, как голосовая, но без ответа голосом.
    public func submitTypedCommand(_ text: String) async {
        let command = assembler.matcher.strippingAddress(from: text)
        guard !command.isEmpty, machine.handle(.commandReceived) else { return }
        lastReply = nil
        await execute(Utterance(text: command, locale: settings.voice.locale), source: .typedText, speakReply: false)
    }

    /// Новые настройки (из окна настроек или после голосовой команды).
    public func apply(settings newSettings: JarvisSettings) async {
        let previous = settings
        settings = newSettings
        assembler.matcher = WakePhraseMatcher(phrases: newSettings.voice.wakePhrases)
        assembler.timing.endOfSpeechSilence = newSettings.voice.endOfSpeechSilenceSeconds
        assembler.locale = newSettings.voice.locale

        if newSettings.voice.listeningMode != machine.listeningMode {
            machine.handle(.setListeningMode(newSettings.voice.listeningMode))
        }
        let captureChanged = previous.voice.recognitionLocale != newSettings.voice.recognitionLocale
            || previous.voice.inputDeviceUID != newSettings.voice.inputDeviceUID
            || previous.voice.microphoneSensitivity != newSettings.voice.microphoneSensitivity
            || previous.voice.recognitionModel != newSettings.voice.recognitionModel
        if captureChanged {
            problem = nil
            if case .failed(_) = machine.state { machine.handle(.recover) }
            await stopEngine()
        }
        await reconcileListening()
    }

    /// Повторить после устранения проблемы (выдали разрешение и т.п.).
    public func retry() async {
        problem = nil
        if case .failed(_) = machine.state { machine.handle(.recover) }
        await reconcileListening()
    }

    public func downloadSpeechModel() async {
        guard !isDownloadingModel else { return }
        isDownloadingModel = true
        defer { isDownloadingModel = false }
        do {
            try await speechInput.downloadModel(for: captureConfiguration())
            log.notice("Speech model installed")
            await retry()
        } catch {
            log.error("Speech model download failed", .error(error))
            problem = .speechModelDownloadFailed
        }
    }

    public func requestSpeechRecognitionAccess() async {
        _ = await speechRecognition.request()
        await retry()
    }

    // MARK: - Захват

    private var wantsContinuousListening: Bool {
        if case .failed(_) = machine.state { return false }
        return machine.state.isEnabled && machine.listeningMode == .wakeWord && !machine.isMicrophonePaused
    }

    private func reconcileListening() async {
        let needsEngine = wantsContinuousListening || assembler.isCapturing
        if needsEngine, !speechInput.isCapturing {
            await startEngine()
        } else if !needsEngine, speechInput.isCapturing {
            await stopEngine()
        }
    }

    private func beginManualCapture(trigger: UtteranceAssembler.Trigger) async {
        if machine.state == .speaking { speechOutput.stopSpeaking() }
        guard machine.handle(.pushToTalkPressed) else { return }
        lastReply = nil
        liveTranscript = ""
        assembler.beginCapture(trigger: trigger, at: now())
        if !speechInput.isCapturing {
            guard await startEngine() else { return }
        }
        guard machine.state == .listening else { return }
        // Пользователь явно говорит команду — тихую речь не отсекаем.
        speechInput.setForcedListening(true)
        play(.listening)
        startTicking()
    }

    private func captureConfiguration() -> SpeechInputConfiguration {
        SpeechInputConfiguration(
            locale: settings.voice.locale,
            inputDeviceUID: settings.voice.inputDeviceUID,
            sensitivity: settings.voice.microphoneSensitivity,
            continuous: wantsContinuousListening,
            modelPreference: settings.voice.recognitionModel
        )
    }

    @discardableResult
    private func startEngine() async -> Bool {
        guard !isStartingEngine else { return false }
        isStartingEngine = true
        defer { isStartingEngine = false }

        switch microphone.state {
        case .granted:
            break
        case .notDetermined:
            guard await microphone.request() else {
                fail(.microphoneDenied, code: .permissionDenied)
                return false
            }
        case .denied:
            fail(.microphoneDenied, code: .permissionDenied)
            return false
        }

        let configuration = captureConfiguration()
        switch await speechInput.modelStatus(for: configuration) {
        case .installed:
            break
        case .needsDownload:
            fail(.speechModelMissing, code: .speechModelUnavailable)
            return false
        case .downloading:
            fail(.speechModelDownloading, code: .speechModelUnavailable)
            return false
        case .unsupportedLanguage:
            fail(.languageNotSupported, code: .languageNotSupportedOnDevice)
            return false
        }

        do {
            let events = try await speechInput.start(configuration)
            isMicrophoneCapturing = true
            log.notice("Speech capture started", .bool("continuous", wantsContinuousListening))
            eventsTask?.cancel()
            eventsTask = Task { [weak self] in
                for await event in events {
                    self?.handle(event)
                }
            }
            // Пока запускался захват, пользователь мог всё выключить.
            if !wantsContinuousListening, !assembler.isCapturing {
                await stopEngine()
                return false
            }
            return true
        } catch let error as SpeechEngineError {
            switch error {
            case .languageNotSupported: fail(.languageNotSupported, code: .languageNotSupportedOnDevice)
            case .modelNotInstalled: fail(.speechModelMissing, code: .speechModelUnavailable)
            case .speechRecognitionNotAuthorized: fail(.speechRecognitionDenied, code: .speechRecognitionNotAuthorized)
            case .microphoneUnavailable, .audioEngineFailed: fail(.microphoneUnavailable, code: .microphoneUnavailable)
            }
            return false
        } catch {
            log.error("Speech capture failed to start", .error(error))
            fail(.microphoneUnavailable, code: .microphoneUnavailable)
            return false
        }
    }

    private func stopEngine() async {
        eventsTask?.cancel()
        eventsTask = nil
        if speechInput.isCapturing {
            await speechInput.stop()
            log.notice("Speech capture stopped")
        }
        isMicrophoneCapturing = false
    }

    private func handle(_ event: SpeechInputEvent) {
        switch event {
        case .transcript(let utterance, let isFinal):
            guard acceptsTranscripts else { return }
            let events = assembler.receive(
                text: utterance.text,
                isFinal: isFinal,
                at: now(),
                listeningForWakePhrase: machine.state == .idle(.wakeWord)
            )
            apply(events)
        case .interrupted:
            Task { [weak self] in
                guard let self else { return }
                await self.stopEngine()
                await self.reconcileListening()
            }
        case .failed(let code):
            switch code {
            case .speechRecognitionNotAuthorized: fail(.speechRecognitionDenied, code: code)
            case .languageNotSupportedOnDevice: fail(.languageNotSupported, code: code)
            case .speechModelUnavailable: fail(.speechModelMissing, code: code)
            default: fail(.microphoneUnavailable, code: code)
            }
            Task { [weak self] in await self?.stopEngine() }
        }
    }

    private var acceptsTranscripts: Bool {
        switch machine.state {
        case .idle(.wakeWord), .listening: true
        default: false
        }
    }

    private func apply(_ events: [UtteranceAssembler.Event]) {
        for event in events {
            switch event {
            case .wakePhraseDetected:
                if machine.handle(.wakeWordDetected) {
                    speechInput.setForcedListening(true)
                    lastReply = nil
                    liveTranscript = ""
                    play(.listening)
                    startTicking()
                }
            case .captureUpdated(let text):
                liveTranscript = text
            case .commandReady(let utterance, let trigger):
                stopTicking()
                speechInput.setForcedListening(false)
                guard machine.handle(.utteranceCaptured) else { continue }
                play(.done)
                liveTranscript = utterance.text
                let source: CommandSource = trigger == .wakePhrase ? .voiceWakeWord : .voicePushToTalk
                Task { [weak self] in
                    await self?.execute(utterance, source: source, speakReply: true)
                }
            case .captureEnded:
                stopTicking()
                speechInput.setForcedListening(false)
                liveTranscript = nil
                if machine.handle(.listeningCancelled) { play(.cancelled) }
                Task { [weak self] in await self?.reconcileListening() }
            }
        }
    }

    // MARK: - Выполнение

    private func execute(_ utterance: Utterance, source: CommandSource, speakReply: Bool) async {
        let context = CommandContext(
            locale: settings.voice.locale,
            personality: Personality(
                humor: settings.personality.humor,
                verbosity: settings.personality.verbosity,
                formality: settings.personality.formality
            ),
            confirmationPolicy: ConfirmationPolicy(
                confirmConsequentialActions: settings.confirmations.confirmConsequentialActions,
                allowVoiceConfirmationForDangerousActions: settings.confirmations.allowVoiceConfirmationForDangerousActions
            )
        )
        let outcome = await processor.handle(utterance, source: source, context: context)

        machine.handle(.planReady(requiresConfirmation: false))
        if case .setPrivacyMode(let enabled)? = outcome.directive {
            onPrivacyModeRequest?(enabled, source)
        }
        machine.handle(.executionFinished)
        if !outcome.executedActions.isEmpty { onActivityRecorded?() }

        liveTranscript = nil
        if !outcome.reply.isEmpty {
            lastReply = outcome.reply
            scheduleReplyClear()
        }

        if speakReply, settings.voice.speakResponses, !outcome.reply.isEmpty, machine.handle(.speechStarted) {
            await speechOutput.speak(outcome.reply, settings: SpeechOutputSettings(
                locale: settings.voice.locale,
                voiceIdentifier: settings.voice.voiceIdentifier,
                rate: settings.voice.speechRate,
                volume: settings.voice.speechVolume
            ))
            machine.handle(.speechFinished)
        }

        switch outcome.directive {
        case .disableAssistant?:
            await disable(source: source)
            return
        case .pauseMicrophone?:
            await pauseMicrophone(source: source)
        case .setPrivacyMode(_)?, nil:
            break
        }

        // Всё, что микрофон слышал во время ответа (в том числе наш собственный голос), забываем.
        if !assembler.isCapturing { assembler.cancel() }
        await reconcileListening()
    }

    // MARK: - Вспомогательное

    private func fail(_ newProblem: AssistantProblem, code: FailureCode) {
        log.error("Assistant problem", .token("code", Self.token(for: code)))
        problem = newProblem
        cancelCapture()
        if machine.state.isEnabled { machine.handle(.failed(code)) }
        play(.failure)
    }

    private func cancelCapture() {
        assembler.cancel()
        speechInput.setForcedListening(false)
        stopTicking()
        liveTranscript = nil
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// Проверка таймеров захвата. Вызывается циклом `startTicking`, в тестах — напрямую.
    func tick() {
        apply(assembler.tick(at: now()))
    }

    private func scheduleReplyClear() {
        replyClearTask?.cancel()
        let seconds = max(settings.privacy.conversationContextMinutes, 1) * 60
        replyClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.lastReply = nil
        }
    }

    private func play(_ cue: SoundCue) {
        guard settings.voice.playSounds else { return }
        sounds.play(cue)
    }

    private func record(_ action: ActionIdentifier, source: CommandSource) async {
        do {
            try await auditLog.record(AuditEvent(action: action, source: source))
        } catch {
            log.error("Audit record failed", .error(error))
        }
        onActivityRecorded?()
    }

    private static func token(for code: FailureCode) -> StaticString {
        switch code {
        case .microphoneUnavailable: "microphoneUnavailable"
        case .permissionDenied: "permissionDenied"
        case .speechModelUnavailable: "speechModelUnavailable"
        case .languageNotSupportedOnDevice: "languageNotSupportedOnDevice"
        case .speechRecognitionNotAuthorized: "speechRecognitionNotAuthorized"
        case .aiProviderUnavailable: "aiProviderUnavailable"
        case .internalError: "internalError"
        }
    }
}
