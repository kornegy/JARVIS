import Foundation

/// Ошибка регистрации инструмента — это ошибка разработчика, ловится тестами.
public enum ToolRegistrationError: Error, Sendable, Equatable {
    case duplicateName(ToolName)
    case emptySummary(ToolName)
    case invalidParameterName(ToolName)
    case duplicateParameter(ToolName)
    /// Действие за пределами Mac не может быть «безопасным» (категория 1).
    case externalEffectMustNotBeSafe(ToolName)
}

/// Вызов, прошедший проверку: инструмент найден, аргументы валидны.
public struct PreparedToolCall: Sendable {
    public let tool: any Tool
    public let arguments: ValidatedArguments

    public var descriptor: ToolDescriptor { tool.descriptor }
}

/// Реестр инструментов — каталог всего, что JARVIS умеет делать.
///
/// Новая возможность = новый тип, реализующий `Tool`, + одна строка регистрации.
/// AI Layer берёт отсюда описания (`descriptors`) для модели, а исполнитель — проверенные
/// вызовы (`prepare`). Ядро AI Layer при этом не меняется.
public struct ToolRegistry: Sendable {
    private var toolsByName: [ToolName: any Tool] = [:]

    public init() {}

    public mutating func register(_ tool: any Tool) throws {
        let descriptor = tool.descriptor
        let name = descriptor.name
        guard toolsByName[name] == nil else { throw ToolRegistrationError.duplicateName(name) }
        guard !descriptor.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolRegistrationError.emptySummary(name)
        }
        let parameterNames = descriptor.parameters.map(\.name)
        guard parameterNames.allSatisfy({ ParameterSpec.isValidName($0) }) else {
            throw ToolRegistrationError.invalidParameterName(name)
        }
        guard Set(parameterNames).count == parameterNames.count else {
            throw ToolRegistrationError.duplicateParameter(name)
        }
        if descriptor.effect == .external, descriptor.risk == .safe {
            throw ToolRegistrationError.externalEffectMustNotBeSafe(name)
        }
        toolsByName[name] = tool
    }

    public var count: Int { toolsByName.count }

    /// Описания всех инструментов в стабильном порядке (по имени) — одинаковый порядок
    /// важен для кеширования промпта у облачных провайдеров.
    public var descriptors: [ToolDescriptor] {
        toolsByName.values.map { $0.descriptor }.sorted { $0.name < $1.name }
    }

    public func tool(named rawName: String) -> (any Tool)? {
        guard let name = ToolName(rawName) else { return nil }
        return toolsByName[name]
    }

    /// Находит инструмент и проверяет аргументы. Всё, что не прошло проверку, отклоняется.
    public func prepare(_ call: ToolCall, validator: ArgumentValidator = ArgumentValidator()) throws -> PreparedToolCall {
        guard let tool = tool(named: call.toolName) else { throw ToolCallError.unknownTool }
        let arguments = try validator.validate(call.arguments, against: tool.descriptor)
        return PreparedToolCall(tool: tool, arguments: arguments)
    }
}
