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
        #expect(first == [.wakePhraseDetected, .captureUpdated("Привет, Джарвис, который")])
        #expect(assembler.isCapturing)

        let second = assembler.receive(text: "Привет, Джарвис, который час?", isFinal: true, at: 0.5, listeningForWakePhrase: true)
        #expect(second == [.captureUpdated("Привет, Джарвис, который час?")])

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
        // На экране — с фразы-активатора; слово «ну» до неё не показываем.
        #expect(events.last == .captureUpdated("привет джарвис какое сегодня число"))
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

    @Test("Обращение не стирается с экрана: видно всё, что услышано")
    func addressStaysVisible() {
        var assembler = makeAssembler()
        assembler.beginCapture(trigger: .manualTap, at: 0)
        #expect(assembler.receive(text: "Привет", isFinal: false, at: 0.3, listeningForWakePhrase: false) == [.captureUpdated("Привет")])
        #expect(assembler.receive(text: "Привет, Джар", isFinal: false, at: 0.6, listeningForWakePhrase: false) == [.captureUpdated("Привет, Джар")])
        // Раньше здесь текст исчезал: обращение вырезалось и из того, что показано на экране.
        #expect(assembler.receive(text: "Привет, Джарвис", isFinal: false, at: 0.9, listeningForWakePhrase: false) == [.captureUpdated("Привет, Джарвис")])
    }

    @Test("Кнопка «Говорить» и только «Привет, Джарвис» — отклик после паузы, а не молчание")
    func addressOnlyByButton() {
        var assembler = makeAssembler()
        assembler.beginCapture(trigger: .manualTap, at: 0)
        _ = assembler.receive(text: "Привет, Джарвис", isFinal: true, at: 1, listeningForWakePhrase: false)
        #expect(assembler.tick(at: 2.5).isEmpty) // вдруг команду ещё договаривают
        let events = assembler.tick(at: 3.1)
        #expect(events == [.addressedOnly(Utterance(text: "привет джарвис", locale: Locale(identifier: "ru_RU")), .manualTap)])
        #expect(!assembler.isCapturing)
    }

    @Test("Push-to-Talk и только имя — отклик сразу после отпускания клавиши")
    func addressOnlyByPushToTalk() {
        var assembler = makeAssembler()
        assembler.beginCapture(trigger: .pushToTalkHold, at: 0)
        _ = assembler.receive(text: "Джарвис", isFinal: true, at: 1, listeningForWakePhrase: false)
        assembler.releaseCapture(at: 1.5)
        #expect(assembler.tick(at: 2.0).isEmpty)
        let events = assembler.tick(at: 2.3)
        #expect(events == [.addressedOnly(Utterance(text: "джарвис", locale: Locale(identifier: "ru_RU")), .pushToTalkHold)])
    }

    @Test("Обращение и команда после паузы — выполняется команда")
    func addressThenCommand() {
        var assembler = makeAssembler()
        assembler.beginCapture(trigger: .manualTap, at: 0)
        _ = assembler.receive(text: "Джарвис", isFinal: true, at: 1, listeningForWakePhrase: false)
        _ = assembler.receive(text: "который час", isFinal: false, at: 2.5, listeningForWakePhrase: false)
        let result = command(assembler.tick(at: 3.6))
        #expect(result?.0 == "который час")
    }

    @Test("Перезапуск распознавания не стирает уже услышанное")
    func restartKeepsHeardText() {
        var assembler = makeAssembler()
        assembler.beginCapture(trigger: .manualTap, at: 0)
        _ = assembler.receive(text: "Привет, Джар", isFinal: false, at: 0.5, listeningForWakePhrase: false)
        assembler.commitVolatile()
        let events = assembler.receive(text: "вис, который час", isFinal: false, at: 1.5, listeningForWakePhrase: false)
        #expect(events == [.captureUpdated("Привет, Джар вис, который час")])
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
