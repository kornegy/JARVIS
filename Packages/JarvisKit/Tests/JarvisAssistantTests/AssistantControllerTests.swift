import Foundation
import Testing
import JarvisAI
import JarvisCore
import JarvisSettings
@testable import JarvisAssistant

/// Интеграционные тесты оркестратора: настоящие сборщик команд, правила, инструменты и
/// журнал; подделаны только микрофон, распознавание и синтез речи.
@MainActor
@Suite("Оркестратор ассистента")
struct AssistantControllerTests {
    struct Harness {
        let controller: AssistantController
        let input: FakeSpeechInput
        let output: FakeSpeechOutput
        let microphone: FakePermission
        let sounds: FakeSounds
        let clock: ManualClock
        let audit: AuditLog
        let directory: TemporaryDirectory
    }

    private func makeHarness(
        mode: ListeningMode = .pushToTalk,
        microphone: FakePermission = FakePermission(),
        modelStatus: SpeechModelStatus = .installed
    ) throws -> Harness {
        var settings = JarvisSettings()
        settings.voice.listeningMode = mode
        settings.personality.humor = 0
        let directory = try TemporaryDirectory()
        let audit = AuditLog(directory: directory.url)
        let utc = TimeZone(identifier: "UTC") ?? .current
        let processor = CommandProcessor(
            registry: try BuiltInTools.makeRegistry(now: { fixedNoon }, timeZone: utc),
            auditLog: audit,
            random: SeededRandomNumberGenerator(seed: 3)
        )
        let input = FakeSpeechInput()
        input.status = modelStatus
        let output = FakeSpeechOutput()
        let sounds = FakeSounds()
        let clock = ManualClock()
        let controller = AssistantController(
            settings: settings,
            speechInput: input,
            speechOutput: output,
            microphone: microphone,
            speechRecognition: FakePermission(),
            sounds: sounds,
            processor: processor,
            auditLog: audit,
            now: { clock.time }
        )
        return Harness(
            controller: controller, input: input, output: output, microphone: microphone,
            sounds: sounds, clock: clock, audit: audit, directory: directory
        )
    }

    @Test("Push-to-Talk: включение не трогает микрофон")
    func enablingPushToTalkDoesNotCapture() async throws {
        let h = try makeHarness(mode: .pushToTalk, microphone: FakePermission(state: .notDetermined))
        defer { h.directory.remove() }

        await h.controller.enable()

        #expect(h.controller.state == .idle(.pushToTalk))
        #expect(h.input.startCount == 0)
        #expect(h.microphone.requestCount == 0)
        #expect(!h.controller.isMicrophoneCapturing)
        let entries = try await h.audit.recentEntries()
        #expect(entries.map(\.action.rawValue) == ["assistant.enable"])
    }

    @Test("Текстовая команда: ответ без голоса и запись в журнал")
    func typedCommand() async throws {
        let h = try makeHarness()
        defer { h.directory.remove() }
        await h.controller.enable()

        await h.controller.submitTypedCommand("Джарвис, который час?")

        #expect(h.controller.lastReply == "Сейчас 12:00.")
        #expect(h.controller.state == .idle(.pushToTalk))
        #expect(h.output.spoken.isEmpty)
        let entries = try await h.audit.recentEntries()
        #expect(entries.first?.action == BuiltInTools.currentTime)
        #expect(entries.first?.source == .typedText)
    }

    @Test("Текстовая команда игнорируется, когда ассистент выключен")
    func typedCommandWhenDisabled() async throws {
        let h = try makeHarness()
        defer { h.directory.remove() }
        await h.controller.submitTypedCommand("который час")
        #expect(h.controller.lastReply == nil)
        #expect(h.controller.state == .disabled)
    }

    @Test("Push-to-Talk: нажал — говорю — отпустил — ответ голосом — микрофон закрыт")
    func pushToTalkFlow() async throws {
        let h = try makeHarness(mode: .pushToTalk, microphone: FakePermission(state: .notDetermined))
        defer { h.directory.remove() }
        await h.controller.enable()

        await h.controller.pushToTalkPressed()
        #expect(h.microphone.requestCount == 1)
        #expect(h.controller.state == .listening)
        #expect(h.controller.isMicrophoneCapturing)
        #expect(h.sounds.played.contains(.listening))
        #expect(h.input.lastConfiguration?.continuous == false)
        #expect(h.input.forcedListening) // явная команда — тихую речь не отсекаем

        h.input.say("Джарвис, какое сегодня число", isFinal: false)
        #expect(await waitUntil { h.controller.liveTranscript == "какое сегодня число" })

        h.controller.pushToTalkReleased()
        #expect(await waitUntil { h.input.finalizeCount == 1 })
        h.clock.advance(1)
        h.controller.tick()
        #expect(!h.input.forcedListening)

        #expect(await waitUntil { h.output.spoken.count == 1 })
        #expect(h.output.spoken.first?.hasPrefix("Сегодня") == true)
        #expect(await waitUntil { !h.input.isCapturing })
        #expect(h.controller.state == .idle(.pushToTalk))
        #expect(!h.controller.isMicrophoneCapturing)
        let entries = try await h.audit.recentEntries()
        #expect(entries.first?.source == .voicePushToTalk)
    }

    @Test("Wake word: микрофон слушает постоянно, команда после фразы-активатора")
    func wakeWordFlow() async throws {
        let h = try makeHarness(mode: .wakeWord)
        defer { h.directory.remove() }
        await h.controller.enable()
        #expect(h.input.startCount == 1)
        #expect(h.controller.isMicrophoneCapturing)
        #expect(h.input.lastConfiguration?.continuous == true)
        #expect(!h.input.forcedListening) // в ожидании тишина отсекается

        h.input.say("обычный разговор рядом с компьютером")
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.controller.state == .idle(.wakeWord))

        h.input.say("Привет, Джарвис, который час")
        #expect(await waitUntil { h.controller.state == .listening })
        #expect(h.input.forcedListening) // после фразы-активатора слушаем всё
        h.clock.advance(1.2)
        h.controller.tick()

        #expect(await waitUntil { h.output.spoken == ["Сейчас 12:00."] })
        #expect(await waitUntil { h.controller.state == .idle(.wakeWord) })
        #expect(h.input.isCapturing) // в режиме wake word микрофон остаётся включён
    }

    @Test("Только фраза-активатор: тихое завершение по таймауту")
    func wakePhraseWithoutCommand() async throws {
        let h = try makeHarness(mode: .wakeWord)
        defer { h.directory.remove() }
        await h.controller.enable()

        h.input.say("Привет, Джарвис")
        #expect(await waitUntil { h.controller.state == .listening })
        h.clock.advance(7)
        h.controller.tick()

        #expect(h.controller.state == .idle(.wakeWord))
        #expect(h.sounds.played.contains(.cancelled))
        #expect(h.output.spoken.isEmpty)
    }

    @Test("Голосовая команда «выключись» выключает ассистента и закрывает микрофон")
    func voiceDisable() async throws {
        let h = try makeHarness(mode: .wakeWord)
        defer { h.directory.remove() }
        await h.controller.enable()

        h.input.say("привет джарвис выключись")
        #expect(await waitUntil { h.controller.state == .listening })
        h.clock.advance(1.5)
        h.controller.tick()

        #expect(await waitUntil { h.controller.state == .disabled })
        #expect(!h.input.isCapturing)
        let entries = try await h.audit.recentEntries()
        #expect(entries.first?.action.rawValue == "assistant.disable")
        #expect(entries.first?.source == .voiceWakeWord)
    }

    @Test("Голосовой Privacy Mode передаётся приложению с источником команды")
    func privacyModeRequest() async throws {
        let h = try makeHarness()
        defer { h.directory.remove() }
        var requests: [(Bool, CommandSource)] = []
        h.controller.onPrivacyModeRequest = { enabled, source in requests.append((enabled, source)) }
        await h.controller.enable()

        await h.controller.submitTypedCommand("включи приватный режим")

        #expect(requests.count == 1)
        #expect(requests.first?.0 == true)
        #expect(requests.first?.1 == .typedText)
    }

    @Test("Нет доступа к микрофону — понятная проблема, захват не запускается")
    func microphoneDenied() async throws {
        let h = try makeHarness(mode: .wakeWord, microphone: FakePermission(state: .denied))
        defer { h.directory.remove() }

        await h.controller.enable()

        #expect(h.controller.problem == .microphoneDenied)
        #expect(h.controller.state == .failed(.permissionDenied))
        #expect(h.input.startCount == 0)
    }

    @Test("Нет модели языка — предложение скачать, после скачивания всё работает")
    func modelDownload() async throws {
        let h = try makeHarness(mode: .wakeWord, modelStatus: .needsDownload)
        defer { h.directory.remove() }

        await h.controller.enable()
        #expect(h.controller.problem == .speechModelMissing)
        #expect(h.input.startCount == 0)

        await h.controller.downloadSpeechModel()

        #expect(h.controller.problem == nil)
        #expect(h.controller.state == .idle(.wakeWord))
        #expect(h.input.isCapturing)
    }

    @Test("Пауза микрофона останавливает захват, снятие паузы — возобновляет")
    func pauseAndResume() async throws {
        let h = try makeHarness(mode: .wakeWord)
        defer { h.directory.remove() }
        await h.controller.enable()

        await h.controller.toggleMicrophonePause()
        #expect(h.controller.state == .idle(.microphonePaused))
        #expect(!h.input.isCapturing)
        #expect(!h.controller.isMicrophoneCapturing)

        await h.controller.toggleMicrophonePause()
        #expect(h.controller.state == .idle(.wakeWord))
        #expect(h.input.isCapturing)
    }

    @Test("Смена языка в настройках перезапускает захват с новым языком")
    func languageChangeRestartsCapture() async throws {
        let h = try makeHarness(mode: .wakeWord)
        defer { h.directory.remove() }
        await h.controller.enable()

        var settings = JarvisSettings()
        settings.voice.listeningMode = .wakeWord
        settings.voice.recognitionLocale = "en_US"
        await h.controller.apply(settings: settings)

        #expect(h.input.startCount == 2)
        #expect(h.input.lastConfiguration?.locale.identifier == "en_US")

        settings.voice.recognitionModel = .dictation
        await h.controller.apply(settings: settings)
        #expect(h.input.startCount == 3)
        #expect(h.input.lastConfiguration?.modelPreference == .dictation)
    }

    @Test("Ошибка распознавания — проблема показана, микрофон закрыт")
    func recognitionFailure() async throws {
        let h = try makeHarness(mode: .wakeWord)
        defer { h.directory.remove() }
        await h.controller.enable()

        h.input.emit(.failed(.speechRecognitionNotAuthorized))

        #expect(await waitUntil { h.controller.problem == .speechRecognitionDenied })
        #expect(await waitUntil { !h.input.isCapturing })
        #expect(h.controller.state == .failed(.speechRecognitionNotAuthorized))
    }

    @Test("Выключение из любого состояния останавливает всё")
    func disableStopsEverything() async throws {
        let h = try makeHarness(mode: .wakeWord)
        defer { h.directory.remove() }
        await h.controller.enable()
        h.input.say("Привет, Джарвис")
        #expect(await waitUntil { h.controller.state == .listening })

        await h.controller.disable()

        #expect(h.controller.state == .disabled)
        #expect(!h.input.isCapturing)
        #expect(h.controller.liveTranscript == nil)
    }
}
