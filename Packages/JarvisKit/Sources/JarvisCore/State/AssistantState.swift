/// Как ассистент ждёт команду, когда включён.
public enum ListeningMode: String, Codable, Sendable, CaseIterable {
    /// Микрофон открыт, ассистент ждёт фразу-активатор («Привет, Джарвис»).
    case wakeWord
    /// Микрофон закрыт до нажатия горячей клавиши (Push-to-Talk).
    case pushToTalk
}

/// Подсостояние ожидания.
public enum IdleMode: Sendable, Equatable {
    case wakeWord
    case pushToTalk
    /// Пользователь поставил микрофон на паузу: пассивного прослушивания нет.
    case microphonePaused
}

/// Почему ассистент перешёл в состояние ошибки. Только коды — без текста команд.
public enum FailureCode: String, Codable, Sendable, CaseIterable {
    case microphoneUnavailable
    case permissionDenied
    case speechModelUnavailable
    case languageNotSupportedOnDevice
    case speechRecognitionNotAuthorized
    case aiProviderUnavailable
    case internalError

    /// Короткое сообщение для пользователя.
    public var userMessage: String {
        switch self {
        case .microphoneUnavailable: "Микрофон недоступен"
        case .permissionDenied: "Нет нужного разрешения macOS"
        case .speechModelUnavailable: "Модель распознавания речи не загружена"
        case .languageNotSupportedOnDevice: "Язык не поддерживается для локального распознавания"
        case .speechRecognitionNotAuthorized: "Нет разрешения на распознавание речи"
        case .aiProviderUnavailable: "AI-провайдер недоступен"
        case .internalError: "Внутренняя ошибка"
        }
    }
}

/// Состояние ассистента (см. docs/Architecture.md §8).
public enum AssistantState: Sendable, Equatable {
    case disabled
    case idle(IdleMode)
    case listening
    case processing
    case executing
    case awaitingConfirmation
    case speaking
    case failed(FailureCode)

    public var isEnabled: Bool { self != .disabled }
}
