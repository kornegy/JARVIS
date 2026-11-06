/// Тип параметра инструмента и его ограничения.
public indirect enum ParameterType: Sendable, Equatable {
    /// Строка. `multiline: false` запрещает переводы строк и любые управляющие символы.
    case text(maxLength: Int, multiline: Bool = false)
    case integer(ClosedRange<Int>)
    case number(ClosedRange<Double>)
    case boolean
    /// Одно значение из фиксированного списка.
    case choice([String])
    /// Абсолютный путь к файлу или папке (`~` раскрывается). Проверка корней и
    /// симлинков — в политике путей исполнителя (Phase 3).
    case filePath
    /// Веб-адрес, только `http`/`https`.
    case webURL
    case list(ParameterType, maxCount: Int)
}

/// Описание одного параметра инструмента.
public struct ParameterSpec: Sendable, Equatable {
    public let name: String
    public let summary: String
    public let type: ParameterType
    public let isRequired: Bool

    public init(name: String, summary: String, type: ParameterType, isRequired: Bool = true) {
        self.name = name
        self.summary = summary
        self.type = type
        self.isRequired = isRequired
    }

    /// Имя параметра: латинская буква, затем буквы/цифры (`path`, `appName`), до 32 символов.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 32 else { return false }
        let isLetter: (Unicode.Scalar) -> Bool = { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }
        guard isLetter(first) else { return false }
        return name.unicodeScalars.allSatisfy { isLetter($0) || ("0"..."9").contains($0) }
    }
}

/// Значение аргумента, как его предложила модель (ещё не проверено).
public indirect enum ArgumentValue: Sendable, Equatable {
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case list([ArgumentValue])
}

/// Вызов инструмента, предложенный моделью или правилом. **Недоверенные данные.**
public struct ToolCall: Sendable, Equatable {
    public let toolName: String
    public let arguments: [String: ArgumentValue]

    public init(toolName: String, arguments: [String: ArgumentValue] = [:]) {
        self.toolName = toolName
        self.arguments = arguments
    }
}

/// Аргументы, прошедшие валидацию. Создаются только `ArgumentValidator`.
public struct ValidatedArguments: Sendable, Equatable {
    public let values: [String: ArgumentValue]

    init(values: [String: ArgumentValue]) {
        self.values = values
    }

    public func text(_ name: String) -> String? {
        if case .string(let value)? = values[name] { return value }
        return nil
    }

    public func integer(_ name: String) -> Int? {
        if case .integer(let value)? = values[name] { return value }
        return nil
    }

    public func number(_ name: String) -> Double? {
        if case .number(let value)? = values[name] { return value }
        return nil
    }

    public func boolean(_ name: String) -> Bool? {
        if case .boolean(let value)? = values[name] { return value }
        return nil
    }

    public func list(_ name: String) -> [ArgumentValue]? {
        if case .list(let value)? = values[name] { return value }
        return nil
    }
}
