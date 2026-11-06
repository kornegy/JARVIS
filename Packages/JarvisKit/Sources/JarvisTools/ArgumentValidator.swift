import Foundation

/// Почему аргумент отклонён.
public enum InvalidArgumentReason: String, Error, Sendable, Equatable {
    case wrongType
    case empty
    case tooLong
    case controlCharacters
    case outOfRange
    case notAllowedValue
    case relativePath
    case unsupportedScheme
    case malformedURL
    case credentialsInURL
    case tooManyItems
}

/// Ошибка подготовки вызова инструмента.
///
/// Значения аргументов и имена, придуманные моделью, сюда **не попадают** — это
/// недоверенные данные. Указываются только имена параметров из описания инструмента.
public enum ToolCallError: Error, Sendable, Equatable {
    case unknownTool
    case unexpectedArgument
    case missingArgument(parameter: String)
    case invalidArgument(parameter: String, reason: InvalidArgumentReason)
}

/// Строгая проверка аргументов по описанию инструмента.
///
/// * лишние аргументы — ошибка (модель не может «подсунуть» параметр);
/// * обязательные должны присутствовать;
/// * строки без управляющих символов (если не `multiline`), с ограничением длины;
/// * пути — только абсолютные, нормализованные (без `..`);
/// * URL — только `http`/`https`, без логина/пароля в адресе.
public struct ArgumentValidator: Sendable {
    public static let maxPathLength = 1024
    public static let maxURLLength = 2048

    /// Домашняя папка — для раскрытия `~` (в тестах подменяется).
    public let homeDirectory: String

    public init(homeDirectory: String = NSHomeDirectory()) {
        self.homeDirectory = homeDirectory
    }

    public func validate(_ arguments: [String: ArgumentValue], against descriptor: ToolDescriptor) throws -> ValidatedArguments {
        let known = Set(descriptor.parameters.map(\.name))
        guard arguments.keys.allSatisfy({ known.contains($0) }) else { throw ToolCallError.unexpectedArgument }

        var validated: [String: ArgumentValue] = [:]
        for spec in descriptor.parameters {
            guard let value = arguments[spec.name] else {
                if spec.isRequired { throw ToolCallError.missingArgument(parameter: spec.name) }
                continue
            }
            do {
                validated[spec.name] = try normalize(value, as: spec.type)
            } catch let reason as InvalidArgumentReason {
                throw ToolCallError.invalidArgument(parameter: spec.name, reason: reason)
            }
        }
        return ValidatedArguments(values: validated)
    }

    // MARK: - Проверка по типам

    private typealias Reason = InvalidArgumentReason

    private func normalize(_ value: ArgumentValue, as type: ParameterType) throws -> ArgumentValue {
        switch type {
        case .text(let maxLength, let multiline):
            guard case .string(let text) = value else { throw Reason.wrongType }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Reason.empty }
            guard text.count <= maxLength else { throw Reason.tooLong }
            if ArgumentValidator.containsForbiddenControlCharacters(text, allowNewlines: multiline) { throw Reason.controlCharacters }
            return .string(text)

        case .integer(let range):
            let integer: Int
            switch value {
            case .integer(let number):
                integer = number
            case .number(let number) where number.rounded() == number && abs(number) < 1e15:
                integer = Int(number)
            default:
                throw Reason.wrongType
            }
            guard range.contains(integer) else { throw Reason.outOfRange }
            return .integer(integer)

        case .number(let range):
            let number: Double
            switch value {
            case .number(let double): number = double
            case .integer(let integer): number = Double(integer)
            default: throw Reason.wrongType
            }
            guard number.isFinite, range.contains(number) else { throw Reason.outOfRange }
            return .number(number)

        case .boolean:
            guard case .boolean(_) = value else { throw Reason.wrongType }
            return value

        case .choice(let options):
            guard case .string(let text) = value else { throw Reason.wrongType }
            guard options.contains(text) else { throw Reason.notAllowedValue }
            return value

        case .filePath:
            guard case .string(let text) = value else { throw Reason.wrongType }
            return .string(try normalizePath(text))

        case .webURL:
            guard case .string(let text) = value else { throw Reason.wrongType }
            return .string(try normalizeWebURL(text))

        case .list(let elementType, let maxCount):
            guard case .list(let items) = value else { throw Reason.wrongType }
            guard items.count <= maxCount else { throw Reason.tooManyItems }
            var normalized: [ArgumentValue] = []
            for item in items {
                normalized.append(try normalize(item, as: elementType))
            }
            return .list(normalized)
        }
    }

    func normalizePath(_ raw: String) throws -> String {
        guard !raw.isEmpty else { throw Reason.empty }
        guard raw.count <= ArgumentValidator.maxPathLength else { throw Reason.tooLong }
        if ArgumentValidator.containsForbiddenControlCharacters(raw, allowNewlines: false) { throw Reason.controlCharacters }

        var path = raw
        if path == "~" {
            path = homeDirectory
        } else if path.hasPrefix("~/") {
            path = homeDirectory + String(path.dropFirst(1))
        }
        guard path.hasPrefix("/") else { throw Reason.relativePath }

        // Лексическая нормализация: убираем «.», «..» и повторные «/».
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    func normalizeWebURL(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw Reason.empty }
        guard trimmed.count <= ArgumentValidator.maxURLLength else { throw Reason.tooLong }
        if ArgumentValidator.containsForbiddenControlCharacters(trimmed, allowNewlines: false) { throw Reason.controlCharacters }
        guard !trimmed.contains(where: \.isWhitespace) else { throw Reason.malformedURL }

        // «youtube.com» → «https://youtube.com». Строку с двоеточием, но без «://»
        // («javascript:…», «file:…») считаем адресом со схемой и проверяем схему.
        let candidate = trimmed.contains(":") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased() else { throw Reason.malformedURL }
        guard scheme == "http" || scheme == "https" else { throw Reason.unsupportedScheme }
        guard let host = url.host(), !host.isEmpty else { throw Reason.malformedURL }
        guard url.user() == nil, url.password() == nil else { throw Reason.credentialsInURL }
        return url.absoluteString
    }

    static func containsForbiddenControlCharacters(_ text: String, allowNewlines: Bool) -> Bool {
        text.unicodeScalars.contains { scalar in
            if allowNewlines, scalar == "\n" || scalar == "\r" || scalar == "\t" { return false }
            return scalar.properties.generalCategory == .control
                || scalar.properties.generalCategory == .format && scalar.value != 0x200D // разрешаем ZWJ в эмодзи
                || scalar == "\u{2028}" || scalar == "\u{2029}"
        }
    }
}
