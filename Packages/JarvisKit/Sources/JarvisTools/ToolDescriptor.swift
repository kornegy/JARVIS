import Foundation
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
    /// Язык ответа пользователю (форматирование дат, чисел).
    public let locale: Locale

    public init(source: CommandSource, locale: Locale = Locale(identifier: "ru_RU")) {
        self.source = source
        self.locale = locale
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
    /// Пути к файлам, о которых результат (найденные, перемещённые) — чтобы потом можно было
    /// сказать «открой его» или «открой второй». `nil` — список не меняется, пустой — забыть.
    /// Живут только в памяти.
    public let files: [String]?

    public init(
        message: String,
        untrustedContent: UntrustedText? = nil,
        auditDetail: AuditDetail? = nil,
        files: [String]? = nil
    ) {
        self.message = message
        self.untrustedContent = untrustedContent
        self.auditDetail = auditDetail
        self.files = files
    }
}

/// Инструмент — единственный способ, которым JARVIS что-то делает на Mac.
///
/// Модель не вызывает инструменты сама: она предлагает `ToolCall`, а исполнитель
/// (Phase 3) находит инструмент в `ToolRegistry`, проверяет аргументы, разрешения и
/// политику подтверждения и только потом вызывает `run`.
public protocol Tool: Sendable {
    var descriptor: ToolDescriptor { get }

    /// Что именно будет сделано — для окна подтверждения («закрыть «Safari»»).
    /// Здесь же инструмент может проверить, что цель существует, и бросить `ToolFailure`
    /// ещё до вопроса пользователю. По умолчанию — краткое описание инструмента.
    func describe(_ arguments: ValidatedArguments, context: ToolContext) async throws -> String

    func run(_ arguments: ValidatedArguments, context: ToolContext) async throws -> ToolOutcome
}

extension Tool {
    public func describe(_ arguments: ValidatedArguments, context: ToolContext) async throws -> String {
        descriptor.summary
    }
}

/// Понятная причина, по которой инструмент не выполнил действие.
///
/// `target` — то, что назвал пользователь или нашёл инструмент («Safari»). Это пользовательские
/// данные: они показываются в ответе, но **никогда не пишутся в лог** (логгер записывает
/// только тип и код ошибки).
public enum ToolFailure: Error, Sendable, Equatable {
    /// Не нашлось (приложение, сайт, файл).
    case notFound(target: String)
    /// Приложение не запущено — закрывать нечего.
    case notRunning(target: String)
    /// Цель защищена политикой (системное приложение, запрещённая папка).
    case protectedTarget(target: String)
    /// macOS не дала выполнить действие (нет разрешения, приложение не ответило).
    case actionFailed(target: String)
    /// Устройство или система не поддерживает действие.
    case unsupported
    /// Там уже есть объект с таким именем — ничего не перезаписывается.
    case alreadyExists(target: String)
    /// macOS не дала доступ к папке (разрешение «Файлы и папки»).
    case accessDenied(target: String)
    /// Нет системного разрешения, которое нужно инструменту.
    case permissionDenied(PermissionKind)
    /// Файл запускает программу (скрипт, установщик) — открывать его JARVIS не будет.
    case unsafeToOpen(target: String)
    /// Отменять нечего.
    case nothingToUndo
}

/// Состояние системного разрешения, как его видит JARVIS.
public enum PermissionStatus: Sendable, Equatable {
    case granted
    case denied
    /// macOS ещё не спрашивала.
    case notDetermined
    /// Узнать заранее нельзя: macOS спросит при первом обращении (папки, автоматизация).
    case unknown
}

/// Проверка разрешений перед выполнением инструмента (docs/Security.md §4).
///
/// Исполнитель не выполняет инструмент, если нужное ему разрешение точно не выдано, —
/// и говорит пользователю, где его дать. Обходить отказ JARVIS не пытается.
@MainActor
public protocol PermissionChecking: AnyObject {
    func status(for kind: PermissionKind) -> PermissionStatus
}
