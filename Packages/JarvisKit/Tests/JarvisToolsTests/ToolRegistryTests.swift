import Testing
import JarvisCore
@testable import JarvisTools

/// Инструмент-заглушка для тестов реестра: ничего не делает.
struct FakeTool: Tool {
    let descriptor: ToolDescriptor

    init(
        _ name: ToolName,
        summary: String = "Тестовый инструмент",
        parameters: [ParameterSpec] = [],
        risk: RiskLevel = .safe,
        effect: ToolEffect = .local
    ) {
        descriptor = ToolDescriptor(name: name, summary: summary, parameters: parameters, risk: risk, effect: effect)
    }

    func run(_ arguments: ValidatedArguments, context: ToolContext) async throws -> ToolOutcome {
        ToolOutcome(message: "ok")
    }
}

@Suite("Реестр инструментов")
struct ToolRegistryTests {
    private func makeRegistry() throws -> ToolRegistry {
        var registry = ToolRegistry()
        try registry.register(FakeTool("apps.open", parameters: [
            ParameterSpec(name: "appName", summary: "Название приложения", type: .text(maxLength: 100)),
        ]))
        try registry.register(FakeTool("files.find", parameters: [
            ParameterSpec(name: "query", summary: "Что искать", type: .text(maxLength: 200)),
            ParameterSpec(name: "limit", summary: "Сколько результатов", type: .integer(1...50), isRequired: false),
        ], effect: .readOnly))
        return registry
    }

    @Test("Описания отдаются в стабильном порядке по имени")
    func descriptorsAreSorted() throws {
        let registry = try makeRegistry()
        #expect(registry.count == 2)
        #expect(registry.descriptors.map(\.name.rawValue) == ["apps.open", "files.find"])
    }

    @Test("Повторная регистрация имени запрещена")
    func duplicateNames() throws {
        var registry = try makeRegistry()
        #expect(throws: ToolRegistrationError.duplicateName("apps.open")) {
            try registry.register(FakeTool("apps.open"))
        }
    }

    @Test("Некорректные описания отклоняются")
    func invalidDescriptors() {
        var registry = ToolRegistry()
        #expect(throws: ToolRegistrationError.emptySummary("a.b")) {
            try registry.register(FakeTool("a.b", summary: "  "))
        }
        #expect(throws: ToolRegistrationError.invalidParameterName("a.c")) {
            try registry.register(FakeTool("a.c", parameters: [ParameterSpec(name: "bad name", summary: "x", type: .boolean)]))
        }
        #expect(throws: ToolRegistrationError.duplicateParameter("a.d")) {
            try registry.register(FakeTool("a.d", parameters: [
                ParameterSpec(name: "x", summary: "x", type: .boolean),
                ParameterSpec(name: "x", summary: "x", type: .boolean),
            ]))
        }
        #expect(throws: ToolRegistrationError.externalEffectMustNotBeSafe("mail.send")) {
            try registry.register(FakeTool("mail.send", risk: .safe, effect: .external))
        }
        #expect(registry.count == 0)
    }

    @Test("Неизвестный инструмент отклоняется, его имя не попадает в ошибку")
    func unknownTool() throws {
        let registry = try makeRegistry()
        #expect(throws: ToolCallError.unknownTool) {
            try registry.prepare(ToolCall(toolName: "shell.run", arguments: ["command": .string("rm -rf ~")]))
        }
        #expect(throws: ToolCallError.unknownTool) {
            try registry.prepare(ToolCall(toolName: "не инструмент"))
        }
    }

    @Test("Корректный вызов проходит проверку")
    func validCall() throws {
        let registry = try makeRegistry()
        let prepared = try registry.prepare(ToolCall(toolName: "files.find", arguments: ["query": .string("диплом"), "limit": .number(5)]))
        #expect(prepared.descriptor.name == "files.find")
        #expect(prepared.arguments.text("query") == "диплом")
        #expect(prepared.arguments.integer("limit") == 5)
    }

    @Test("Лишний аргумент от модели отклоняется")
    func unexpectedArgument() throws {
        let registry = try makeRegistry()
        #expect(throws: ToolCallError.unexpectedArgument) {
            try registry.prepare(ToolCall(toolName: "apps.open", arguments: ["appName": .string("Mail"), "force": .boolean(true)]))
        }
    }
}
