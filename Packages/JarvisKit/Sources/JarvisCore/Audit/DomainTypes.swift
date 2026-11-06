/// Откуда пришла команда.
public enum CommandSource: String, Codable, Sendable, CaseIterable {
    /// Голос после фразы-активатора.
    case voiceWakeWord
    /// Голос по горячей клавише Push-to-Talk.
    case voicePushToTalk
    /// Текст, набранный пользователем.
    case typedText
    /// Сценарий автоматизации.
    case automation
    /// Явное действие в интерфейсе JARVIS (кнопка, переключатель).
    case userInterface
}

/// Уровень риска действия (docs/Security.md §5).
public enum RiskLevel: Int, Codable, Sendable, CaseIterable, Comparable {
    /// Категория 1: безопасно, выполняется сразу (открыть приложение, найти файл).
    case safe = 1
    /// Категория 2: есть последствия, подтверждение по настройке (переместить файл).
    case consequential = 2
    /// Категория 3: опасно или необратимо, подтверждение всегда (удалить, отправить письмо).
    case dangerous = 3

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Насколько подробно вести журнал аудита.
public enum AuditDetailLevel: String, Codable, Sendable, CaseIterable {
    /// Только действие, время, источник, результат, подтверждение.
    case minimal
    /// Плюс короткое санитизированное описание цели (например, имя приложения).
    case detailed
}
