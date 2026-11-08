import Foundation
import Testing
import JarvisAI
import JarvisCore
@testable import JarvisAssistant

@Suite("Подсказка модели распознавания")
struct RecognitionVocabularyTests {
    @Test("Имя ассистента и фразы-активаторы, с заглавной буквы, без повторов")
    func vocabulary() {
        let words = RecognitionVocabulary.make(wakePhrases: ["привет джарвис", "hey jarvis", "  "])
        #expect(words == ["Джарвис", "Jarvis", "Привет Джарвис", "Hey Jarvis"])
    }
}

@Suite("Сборка команды из распознанной речи")
struct UtteranceAssemblerTests {
    private func makeAssembler() -> UtteranceAssembler {
        UtteranceAssembler(
            matcher: WakePhraseMatcher(phrases: ["привет джарвис", "hey jarvis"]),
            timing: UtteranceAssembler.Timing(endOfSpeechSilence: 1, followUpTimeout: 6, releaseGrace: 0.7, maxCaptureDuration: 20),
            locale: Locale(identifier: "ru_RU")
        )
    }

    private func command(_ events: [UtteranceAssembler.Event]) -> (String, UtteranceAssembler.Trigger)? {
        for event in events {
            if case .commandReady(let utterance, let trigger) = event { return (utterance.text, trigger) }
        }
        return nil
    }

    @Test("Фраза-активатор → захват → пауза → команда")
    func wakePhraseFlow() {
        var assembler = makeAssembler()
        let first = assembler.receive(text: "Привет, Джарвис, который", isFinal: false, at: 0, listeningForWakePhrase: true)
        #expect(first == [.wakePhraseDetected, .captureUpdated("который")])
        #expect(assembler.isCapturing)

        let second = assembler.receive(text: "Привет, Джарвис, который час?", isFinal: true, at: 0.5, listeningForWakePhrase: true)
        #expect(second == [.captureUpdated("который час")])

        #expect(assembler.tick(at: 1.2).isEmpty) // пауза ещё короткая
        let result = command(assembler.tick(at: 1.6))
        #expect(result?.0 == "который час")
        #expect(result?.1 == .wakePhrase)
        #expect(!assembler.isCapturing)
    }

    @Test("Фраза-активатор, разорванная между фрагментами")
    func wakePhraseSplitAcrossSegments() {
        var assembler = makeAssembler()
        #expect(assembler.receive(text: "ну привет", isFinal: true, at: 0, listeningForWakePhrase: true).isEmpty)
        let events = assembler.receive(text: "джарвис какое сегодня число", isFinal: false, at: 1, listeningForWakePhrase: true)
        #expect(events.first == .wakePhraseDetected)
        #expect(events.last == .captureUpdated("какое сегодня число"))
    }

    @Test("Обычная речь без фразы-активатора ничего не запускает")
    func ordinarySpeechIsIgnored() {
        var assembler = makeAssembler()
        let events = assembler.receive(
            text: "мы обсуждали длинный план на неделю и ещё много всего",
            isFinal: true,
            at: 0,
            listeningForWakePhrase: true
        )
        #expect(events.isEmpty)
        #expect(!assembler.isCapturing)
        #expect(assembler.tick(at: 100).isEmpty)
    }

    @Test("Без режима wake word текст в ожидании игнорируется")
    func ignoredWhenNotListeningForWakePhrase() {
        var assembler = makeAssembler()
        #expect(assembler.receive(text: "привет джарвис который час", isFinal: true, at: 0, listeningForWakePhrase: false).isEmpty)
        #expect(!assembler.isCapturing)
    }

    @Test("Только фраза-активатор без команды — ожидание и тихое завершение")
    func followUpTimeout() {
        var assembler = makeAssembler()
        _ = assembler.receive(text: "привет джарвис", isFinal: true, at: 0, listeningForWakePhrase: true)
        #expect(assembler.tick(at: 3).isEmpty)
        #expect(assembler.tick(at: 6.1) == [.captureEnded])
    }

    @Test("Push-to-Talk: слушаем, пока клавиша нажата, и чуть после отпускания")
    func pushToTalkHold() {
        var assembler = makeAssembler()
        assembler.beginCapture(trigger: .pushToTalkHold, at: 0)
        _ = assembler.receive(text: "Джарвис, который", isFinal: false, at: 0.5, listeningForWakePhrase: false)
        #expect(assembler.tick(at: 5).isEmpty) // пауза не завершает, пока клавиша нажата
        assembler.releaseCapture(at: 5)
        _ = assembler.receive(text: "Джарвис, который час", isFinal: true, at: 5.3, listeningForWakePhrase: false)
        #expect(assembler.tick(at: 5.8).isEmpty) // ждём последние слова
        let result = command(assembler.tick(at: 6.1))
        #expect(result?.0 == "который час")
        #expect(result?.1 == .pushToTalkHold)
    }

    @Test("Push-to-Talk без живого текста: после отпускания ждём окончательный текст")
    func pushToTalkWithoutLiveText() {
        var assembler = makeAssembler()
        assembler.beginCapture(trigger: .pushToTalkHold, at: 0)
        assembler.releaseCapture(at: 3)
        #expect(assembler.tick(at: 3.8).isEmpty) // текста ещё нет — не сдаёмся через 0,7 с
        _ = assembler.receive(text: "который час", isFinal: true, at: 4.2, listeningForWakePhrase: false)
        #expect(assembler.tick(at: 4.5).isEmpty)
        let result = command(assembler.tick(at: 4.95))
        #expect(result?.0 == "который час")
    }

    @Test("Push-to-Talk: промолчали — тихо заканчиваем после ожидания")
    func pushToTalkSilentRelease() {
        var assembler = makeAssembler()
        assembler.beginCapture(trigger: .pushToTalkHold, at: 0)
        assembler.releaseCapture(at: 1)
        #expect(assembler.tick(at: 3.0).isEmpty)
        #expect(assembler.tick(at: 3.6) == [.captureEnded])
    }

    @Test("Кнопка «Говорить»: команда завершается паузой")
    func manualTapEndsOnSilence() {
        var assembler = makeAssembler()
        assembler.beginCapture(trigger: .manualTap, at: 0)
        _ = assembler.receive(text: "что ты умеешь", isFinal: false, at: 0.4, listeningForWakePhrase: false)
        let result = command(assembler.tick(at: 1.5))
        #expect(result?.0 == "что ты умеешь")
        #expect(result?.1 == .manualTap)
    }

    @Test("Промежуточный текст заменяется, окончательный накапливается")
    func volatileAndFinalTranscripts() {
        var assembler = makeAssembler()
        assembler.beginCapture(trigger: .manualTap, at: 0)
        _ = assembler.receive(text: "открой", isFinal: false, at: 0.1, listeningForWakePhrase: false)
        _ = assembler.receive(text: "открой почту", isFinal: true, at: 0.2, listeningForWakePhrase: false)
        let events = assembler.receive(text: "и проверь", isFinal: false, at: 0.3, listeningForWakePhrase: false)
        #expect(events == [.captureUpdated("открой почту и проверь")])
    }

    @Test("Слишком длинная команда завершается по лимиту времени")
    func maxDuration() {
        var assembler = makeAssembler()
        assembler.beginCapture(trigger: .pushToTalkHold, at: 0)
        _ = assembler.receive(text: "очень длинная команда", isFinal: false, at: 1, listeningForWakePhrase: false)
        #expect(command(assembler.tick(at: 20.5))?.0 == "очень длинная команда")
    }

    @Test("Отмена сбрасывает захват")
    func cancel() {
        var assembler = makeAssembler()
        assembler.beginCapture(trigger: .manualTap, at: 0)
        assembler.cancel()
        #expect(!assembler.isCapturing)
        #expect(assembler.captureTrigger == nil)
    }
}
