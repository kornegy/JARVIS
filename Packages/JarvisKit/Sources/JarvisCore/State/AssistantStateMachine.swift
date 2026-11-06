/// Событие, которое может изменить состояние ассистента.
public enum AssistantEvent: Sendable, Equatable {
    case enable
    case disable
    case setListeningMode(ListeningMode)
    case pauseMicrophone
    case resumeMicrophone
    case wakeWordDetected
    case pushToTalkPressed
    case utteranceCaptured
    case listeningCancelled
    case planReady(requiresConfirmation: Bool)
    case confirmationResolved(approved: Bool)
    case executionFinished
    case speechStarted
    case speechFinished
    case failed(FailureCode)
    case recover
}

/// Машина состояний ассистента.
///
/// Это чистая логика без побочных эффектов: она только решает, допустим ли переход.
/// Оркестратор (Phase 2) реагирует на новое состояние — открывает микрофон, запускает
/// распознавание и т.д. Благодаря этому все правила переходов покрываются юнит-тестами.
///
/// Главные правила:
/// * `disable` допустим из **любого** состояния — пользователь всегда может выключить JARVIS;
/// * недопустимый переход отклоняется (`handle` возвращает `false`) и ничего не меняет;
/// * пауза микрофона — флаг, а не состояние: после выполнения команды ассистент
///   вернётся в ожидание с выключенным микрофоном.
public struct AssistantStateMachine: Sendable, Equatable {
    public private(set) var state: AssistantState = .disabled
    public private(set) var listeningMode: ListeningMode
    public private(set) var isMicrophonePaused = false

    public init(listeningMode: ListeningMode = .pushToTalk) {
        self.listeningMode = listeningMode
    }

    /// Состояние ожидания, в которое ассистент возвращается после команды.
    public var idleState: AssistantState {
        if isMicrophonePaused { return .idle(.microphonePaused) }
        switch listeningMode {
        case .wakeWord: return .idle(.wakeWord)
        case .pushToTalk: return .idle(.pushToTalk)
        }
    }

    /// Допустимо ли событие сейчас (ничего не меняет). Удобно, чтобы включать/выключать кнопки.
    public func canHandle(_ event: AssistantEvent) -> Bool {
        var copy = self
        return copy.handle(event)
    }

    /// Применяет событие. Возвращает `false`, если переход недопустим (состояние не меняется).
    @discardableResult
    public mutating func handle(_ event: AssistantEvent) -> Bool {
        switch (event, state) {
        case (.disable, _):
            state = .disabled

        case (.enable, .disabled):
            state = idleState

        case (.setListeningMode(let mode), _):
            listeningMode = mode
            if case .idle(_) = state { state = idleState }

        case (.pauseMicrophone, let current) where current != .disabled:
            isMicrophonePaused = true
            switch current {
            case .idle(_), .listening: state = idleState
            default: break
            }

        case (.resumeMicrophone, let current) where current != .disabled:
            isMicrophonePaused = false
            if case .idle(_) = current { state = idleState }

        case (.wakeWordDetected, .idle(.wakeWord)):
            state = .listening

        // Push-to-Talk — явное действие пользователя, поэтому работает и при паузе
        // пассивного прослушивания, и во время ответа (перебивание).
        case (.pushToTalkPressed, .idle(_)), (.pushToTalkPressed, .speaking):
            state = .listening

        case (.utteranceCaptured, .listening):
            state = .processing

        case (.listeningCancelled, .listening):
            state = idleState

        case (.planReady(requiresConfirmation: let needsConfirmation), .processing),
             (.planReady(requiresConfirmation: let needsConfirmation), .executing):
            state = needsConfirmation ? .awaitingConfirmation : .executing

        case (.confirmationResolved(approved: let approved), .awaitingConfirmation):
            state = approved ? .executing : idleState

        case (.executionFinished, .executing):
            state = idleState

        case (.speechStarted, .processing), (.speechStarted, .executing), (.speechStarted, .idle(_)):
            state = .speaking

        case (.speechFinished, .speaking):
            state = idleState

        case (.failed(let code), let current) where current != .disabled:
            state = .failed(code)

        case (.recover, .failed(_)):
            state = idleState

        default:
            return false
        }
        return true
    }
}
