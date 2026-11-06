import Foundation
import JarvisAI
import JarvisCore

/// Собирает команду из потока распознанного текста.
///
/// Решает три задачи:
/// 1. **Wake word.** В режиме ожидания ищет фразу-активатор. Всё, что не содержит её,
///    сразу отбрасывается — в памяти остаются максимум три последних слова (на случай,
///    если «привет» и «джарвис» попали в разные фрагменты).
/// 2. **Захват команды** после фразы-активатора, по Push-to-Talk или по кнопке.
/// 3. **Конец фразы:** пауза в речи, отпускание клавиши или лимит времени.
///
/// Чистая логика без таймеров: время передаётся параметром, поэтому всё тестируется.
public struct UtteranceAssembler: Sendable {
    public struct Timing: Sendable, Equatable {
        /// Пауза после слов команды, после которой команда считается законченной.
        public var endOfSpeechSilence: TimeInterval
        /// Сколько ждать команду после одной только фразы-активатора.
        public var followUpTimeout: TimeInterval
        /// Сколько ждать последние слова после отпускания Push-to-Talk.
        public var releaseGrace: TimeInterval
        /// Максимальная длительность одной команды.
        public var maxCaptureDuration: TimeInterval

        public init(
            endOfSpeechSilence: TimeInterval = 1.0,
            followUpTimeout: TimeInterval = 6,
            releaseGrace: TimeInterval = 0.7,
            maxCaptureDuration: TimeInterval = 20
        ) {
            self.endOfSpeechSilence = endOfSpeechSilence
            self.followUpTimeout = followUpTimeout
            self.releaseGrace = releaseGrace
            self.maxCaptureDuration = maxCaptureDuration
        }
    }

    /// Чем начат захват команды.
    public enum Trigger: Sendable, Equatable {
        case wakePhrase
        /// Клавиша Push-to-Talk: слушаем, пока она нажата.
        case pushToTalkHold
        /// Кнопка «Говорить»: слушаем до паузы.
        case manualTap
    }

    public enum Event: Sendable, Equatable {
        case wakePhraseDetected
        case captureUpdated(String)
        case commandReady(Utterance, Trigger)
        /// Захват закончился без команды (сказали только «Привет, Джарвис» или промолчали).
        case captureEnded
    }

    private struct Capture: Sendable {
        var trigger: Trigger
        var startedAt: TimeInterval
        var lastActivityAt: TimeInterval
        var releasedAt: TimeInterval?
        var finalized = ""
        var volatile = ""
        var lastCommand = ""

        var raw: String {
            [finalized, volatile].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    private enum Phase: Sendable {
        case waiting(tail: [String])
        case capturing(Capture)
    }

    public var matcher: WakePhraseMatcher
    public var timing: Timing
    public var locale: Locale
    private var phase: Phase = .waiting(tail: [])

    public init(matcher: WakePhraseMatcher, timing: Timing = Timing(), locale: Locale) {
        self.matcher = matcher
        self.timing = timing
        self.locale = locale
    }

    public var isCapturing: Bool {
        if case .capturing(_) = phase { return true }
        return false
    }

    public var captureTrigger: Trigger? {
        if case .capturing(let capture) = phase { return capture.trigger }
        return nil
    }

    /// Начать захват команды без фразы-активатора (Push-to-Talk или кнопка).
    public mutating func beginCapture(trigger: Trigger, at now: TimeInterval) {
        phase = .capturing(Capture(trigger: trigger, startedAt: now, lastActivityAt: now))
    }

    /// Клавиша Push-to-Talk отпущена: ждём последние слова и завершаем.
    public mutating func releaseCapture(at now: TimeInterval) {
        guard case .capturing(var capture) = phase, capture.releasedAt == nil else { return }
        capture.releasedAt = now
        phase = .capturing(capture)
    }

    /// Сбросить всё, включая хвост из последних слов.
    public mutating func cancel() {
        phase = .waiting(tail: [])
    }

    /// Новый фрагмент распознанного текста.
    public mutating func receive(text: String, isFinal: Bool, at now: TimeInterval, listeningForWakePhrase: Bool) -> [Event] {
        switch phase {
        case .waiting(let tail):
            guard listeningForWakePhrase else {
                phase = .waiting(tail: [])
                return []
            }
            let words = TextNormalizer.words(text)
            let candidate = (tail + words).joined(separator: " ")
            guard matcher.remainder(afterWakePhraseIn: candidate) != nil else {
                if isFinal { phase = .waiting(tail: Array(words.suffix(3))) }
                return []
            }
            var capture = Capture(trigger: .wakePhrase, startedAt: now, lastActivityAt: now)
            if isFinal { capture.finalized = candidate } else { capture.volatile = candidate }
            var events: [Event] = [.wakePhraseDetected]
            let command = commandText(for: capture)
            if !command.isEmpty {
                capture.lastCommand = command
                events.append(.captureUpdated(command))
            }
            phase = .capturing(capture)
            return events

        case .capturing(var capture):
            let before = capture.raw
            if isFinal {
                capture.finalized = [capture.finalized, text].filter { !$0.isEmpty }.joined(separator: " ")
                capture.volatile = ""
            } else {
                capture.volatile = text
            }
            if capture.raw != before { capture.lastActivityAt = now }
            let command = commandText(for: capture)
            var events: [Event] = []
            if command != capture.lastCommand {
                capture.lastCommand = command
                events.append(.captureUpdated(command))
            }
            phase = .capturing(capture)
            return events
        }
    }

    /// Проверка таймеров (вызывается периодически, пока идёт захват).
    public mutating func tick(at now: TimeInterval) -> [Event] {
        guard case .capturing(let capture) = phase else { return [] }
        let command = commandText(for: capture)
        let elapsed = now - capture.startedAt

        if let releasedAt = capture.releasedAt {
            return now - max(releasedAt, capture.lastActivityAt) >= timing.releaseGrace ? finish(capture) : []
        }
        if elapsed >= timing.maxCaptureDuration {
            return finish(capture)
        }
        switch capture.trigger {
        case .pushToTalkHold:
            return []
        case .wakePhrase, .manualTap:
            if !command.isEmpty, now - capture.lastActivityAt >= timing.endOfSpeechSilence {
                return finish(capture)
            }
            if command.isEmpty, elapsed >= timing.followUpTimeout {
                return finish(capture)
            }
            return []
        }
    }

    private mutating func finish(_ capture: Capture) -> [Event] {
        phase = .waiting(tail: [])
        let command = commandText(for: capture)
        guard !command.isEmpty else { return [.captureEnded] }
        return [.commandReady(Utterance(text: command, locale: locale), capture.trigger)]
    }

    private func commandText(for capture: Capture) -> String {
        switch capture.trigger {
        case .wakePhrase:
            matcher.command(afterAddressIn: capture.raw)
        case .pushToTalkHold, .manualTap:
            matcher.strippingAddress(from: capture.raw)
        }
    }
}
