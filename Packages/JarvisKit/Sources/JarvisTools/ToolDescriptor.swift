import JarvisCore

/// Имя инструмента — тот же формат, что у идентификатора действия в журнале (`apps.open`).
public typealias ToolName = ActionIdentifier

/// Системное разрешение macOS, которое нужно инструменту (docs/Security.md §4).
public enum PermissionKind: String, Codable, Sendable, CaseIterable {
    case microphone
    case speechRecognition
    case accessibility
    case appleEvents
    case filesAndFolders
    case calendars
    case reminders
    case notifications
    case location
}

/// Побочные эффекты инструмента.
public enum ToolEffect: String, Sendable, CaseIterable {
    /// Только читает (найти файл, узнать время).
    case readOnly
    /// Меняет что-то на этом Mac (открыть приложение, переместить файл).
    case local
    /// Действует за пределами Mac (отправить письмо, опубликовать).
    case external
}

/// Описание инструмента: всё, что нужно AI, исполнителю, политике подтверждения и журналу.
public struct ToolDescriptor: Sendable, Equatable {
    public let name: ToolName
    /// Описание для модели и интерфейса. Пишет разработчик; без пользовательских данных.
    public let summary: String
    public let parameters: [ParameterSpec]
    public let risk: RiskLevel
    public let requiredPermissions: Set<PermissionKind>
    public let effect: ToolEffect
    /// Можно ли отменить действие («Джарвис, отмени»).
    public let isUndoable: Bool
    /// Результат содержит внешний контент (файлы, письма, страницы) — он считается
    /// недоверенным, и план после него «испачкан» (docs/Security.md §6).
    public let producesUntrustedContent: Bool

    public init(
        name: ToolName,
        summary: String,
        parameters: [ParameterSpec] = [],
        risk: RiskLevel,
        requiredPermissions: Set<PermissionKind> = [],
        effect: ToolEffect,
        isUndoable: Bool = false,
        producesUntrustedContent: Bool = false
    ) {
        self.name = name
        self.summary = summary
        self.parameters = parameters
        self.risk = risk
        self.requiredPermissions = requiredPermissions
        self.effect = effect
        self.isUndoable = isUndoable
        self.producesUntrustedContent = producesUntrustedContent
    }

    public func parameter(named name: String) -> ParameterSpec? {
        parameters.first { $0.name == name }
    }
}

/// Контекст выполнения инструмента.
public struct ToolContext: Sendable {
    public let source: CommandSource

    public init(source: CommandSource) {
        self.source = source
    }
}

/// Текст из внешнего источника (файл, письмо, страница). Это **данные, а не инструкции**:
/// AI Layer передаёт его модели только внутри размеченного блока данных.
/// При печати не раскрывается.
public struct UntrustedText: Sendable, Equatable, CustomStringConvertible {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var description: String { "UntrustedText(<redacted>, \(text.count) chars)" }
}

/// Результат инструмента.
public struct ToolOutcome: Sendable {
    /// Короткий результат для ответа пользователю (живёт только в RAM).
    public let message: String
    /// Внешний контент, если инструмент его прочитал.
    public let untrustedContent: UntrustedText?
    /// Описание цели для подробного режима журнала.
    public let auditDetail: AuditDetail?

    public init(message: String, untrustedContent: UntrustedText? = nil, auditDetail: AuditDetail? = nil) {
        self.message = message
        self.untrustedContent = untrustedContent
        self.auditDetail = auditDetail
    }
}

/// Инструмент — единственный способ, которым JARVIS что-то делает на Mac.
///
/// Модель не вызывает инструменты сама: она предлагает `ToolCall`, а исполнитель
/// (Phase 3) находит инструмент в `ToolRegistry`, проверяет аргументы, разрешения и
/// политику подтверждения и только потом вызывает `run`.
public protocol Tool: Sendable {
    var descriptor: ToolDescriptor { get }
    func run(_ arguments: ValidatedArguments, context: ToolContext) async throws -> ToolOutcome
}
