import Testing
import JarvisCore
@testable import JarvisTools

@Suite("Валидация аргументов")
struct ArgumentValidatorTests {
    private let validator = ArgumentValidator(homeDirectory: "/Users/tester")

    private func descriptor(_ parameters: ParameterSpec...) -> ToolDescriptor {
        ToolDescriptor(name: "test.tool", summary: "Тест", parameters: parameters, risk: .safe, effect: .readOnly)
    }

    private func reason(_ value: ArgumentValue, _ type: ParameterType) -> InvalidArgumentReason? {
        do {
            _ = try validator.validate(["value": value], against: descriptor(ParameterSpec(name: "value", summary: "x", type: type)))
            return nil
        } catch ToolCallError.invalidArgument(_, let found) {
            return found
        } catch {
            return nil
        }
    }

    // MARK: Обязательность

    @Test("Обязательный аргумент должен присутствовать, необязательный — нет")
    func requiredArguments() throws {
        let spec = descriptor(
            ParameterSpec(name: "query", summary: "x", type: .text(maxLength: 10)),
            ParameterSpec(name: "limit", summary: "x", type: .integer(1...5), isRequired: false)
        )
        #expect(throws: ToolCallError.missingArgument(parameter: "query")) {
            try validator.validate([:], against: spec)
        }
        let validated = try validator.validate(["query": .string("pdf")], against: spec)
        #expect(validated.integer("limit") == nil)
    }

    // MARK: Текст

    @Test("Текст: тип, пустота, длина, управляющие символы")
    func text() {
        let type = ParameterType.text(maxLength: 5)
        #expect(reason(.string("Mail"), type) == nil)
        #expect(reason(.integer(1), type) == .wrongType)
        #expect(reason(.string("   "), type) == .empty)
        #expect(reason(.string("слишком длинно"), type) == .tooLong)
        #expect(reason(.string("a\nb"), type) == .controlCharacters)
        #expect(reason(.string("a\u{0000}b"), type) == .controlCharacters)
        #expect(reason(.string("a\u{202E}b"), type) == .controlCharacters) // RTL override
    }

    @Test("Многострочный текст разрешает переводы строк, но не прочие управляющие символы")
    func multilineText() {
        let type = ParameterType.text(maxLength: 100, multiline: true)
        #expect(reason(.string("строка 1\nстрока 2\tтаб"), type) == nil)
        #expect(reason(.string("звонок\u{0007}"), type) == .controlCharacters)
    }

    @Test("Эмодзи с ZWJ допустимы")
    func emojiAllowed() {
        #expect(reason(.string("👨‍💻"), .text(maxLength: 10)) == nil)
    }

    // MARK: Числа

    @Test("Целые: диапазон и целые значения в виде числа с точкой")
    func integers() {
        let type = ParameterType.integer(0...100)
        #expect(reason(.integer(30), type) == nil)
        #expect(reason(.number(30.0), type) == nil)
        #expect(reason(.number(30.5), type) == .wrongType)
        #expect(reason(.integer(101), type) == .outOfRange)
        #expect(reason(.string("30"), type) == .wrongType)
    }

    @Test("Дробные: диапазон и конечность")
    func numbers() {
        let type = ParameterType.number(0...1)
        #expect(reason(.number(0.5), type) == nil)
        #expect(reason(.integer(1), type) == nil)
        #expect(reason(.number(.infinity), type) == .outOfRange)
        #expect(reason(.number(.nan), type) == .outOfRange)
        #expect(reason(.number(1.5), type) == .outOfRange)
    }

    @Test("Выбор из списка и логические значения")
    func choiceAndBoolean() {
        #expect(reason(.string("up"), .choice(["up", "down"])) == nil)
        #expect(reason(.string("UP"), .choice(["up", "down"])) == .notAllowedValue)
        #expect(reason(.boolean(true), .boolean) == nil)
        #expect(reason(.string("true"), .boolean) == .wrongType)
    }

    @Test("Списки: размер и проверка каждого элемента")
    func lists() {
        let type = ParameterType.list(.text(maxLength: 10), maxCount: 2)
        #expect(reason(.list([.string("a"), .string("b")]), type) == nil)
        #expect(reason(.list([.string("a"), .string("b"), .string("c")]), type) == .tooManyItems)
        #expect(reason(.list([.string("a\u{0000}")]), type) == .controlCharacters)
    }

    // MARK: Пути

    @Test("Пути: раскрытие ~ и нормализация", arguments: [
        ("~/Documents", "/Users/tester/Documents"),
        ("~", "/Users/tester"),
        ("/Users/tester/./Downloads//file.pdf", "/Users/tester/Downloads/file.pdf"),
        ("/Users/tester/Documents/../Downloads", "/Users/tester/Downloads"),
        ("/../../etc/passwd", "/etc/passwd"),
    ])
    func pathNormalization(input: String, expected: String) throws {
        #expect(try validator.normalizePath(input) == expected)
    }

    @Test("Пути: относительные и с управляющими символами отклоняются")
    func invalidPaths() {
        #expect(reason(.string("Documents/file.txt"), .filePath) == .relativePath)
        #expect(reason(.string("~user/file"), .filePath) == .relativePath)
        #expect(reason(.string(""), .filePath) == .empty)
        #expect(reason(.string("/tmp/a\nb"), .filePath) == .controlCharacters)
        #expect(reason(.string("/" + String(repeating: "a", count: 2000)), .filePath) == .tooLong)
    }

    // MARK: URL

    @Test("URL: http/https, адрес без схемы дополняется https", arguments: [
        ("https://example.com/path?q=1", "https://example.com/path?q=1"),
        ("http://example.com", "http://example.com"),
        ("youtube.com", "https://youtube.com"),
    ])
    func validURLs(input: String, expected: String) throws {
        #expect(try validator.normalizeWebURL(input) == expected)
    }

    @Test("URL: опасные схемы и формы отклоняются")
    func invalidURLs() {
        #expect(reason(.string("javascript:alert(1)"), .webURL) == .unsupportedScheme)
        #expect(reason(.string("file:///etc/passwd"), .webURL) == .unsupportedScheme)
        #expect(reason(.string("data:text/html,hi"), .webURL) == .unsupportedScheme)
        #expect(reason(.string("ftp://example.com"), .webURL) == .unsupportedScheme)
        #expect(reason(.string("https://user:pass@example.com"), .webURL) == .credentialsInURL)
        #expect(reason(.string("https://exa mple.com"), .webURL) == .malformedURL)
        #expect(reason(.string("https://"), .webURL) == .malformedURL)
    }
}
