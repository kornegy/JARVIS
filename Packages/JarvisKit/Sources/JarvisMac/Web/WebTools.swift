import AppKit
import JarvisCore
import JarvisTools

/// Открыть ссылку в браузере по умолчанию. JARVIS сам в сеть не ходит.
@MainActor
enum Browser {
    static func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

/// «Открой сайт github», «зайди на ютуб». Категория 1.
/// Адрес уже проверен валидатором: только `http`/`https`, без логина и пароля в ссылке.
struct OpenWebsiteTool: Tool {
    var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: StandardTools.openWebsite,
            summary: "Открыть сайт в браузере по умолчанию.",
            parameters: [ParameterSpec(name: "url", summary: "Адрес сайта (http или https)", type: .webURL)],
            risk: .safe,
            effect: .local
        )
    }

    func run(_ arguments: ValidatedArguments, context: ToolContext) async throws -> ToolOutcome {
        guard let text = arguments.text("url"), let url = URL(string: text) else {
            throw ToolFailure.notFound(target: arguments.text("url") ?? "")
        }
        let host = Self.displayHost(url)
        guard await Browser.open(url) else { throw ToolFailure.actionFailed(target: host) }
        return ToolOutcome(message: host, auditDetail: AuditDetail(host))
    }

    /// «www.youtube.com» → «youtube.com».
    static func displayHost(_ url: URL) -> String {
        let host = url.host() ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// «Найди в интернете …». Категория 1: открывает страницу поиска в браузере.
struct WebSearchTool: Tool {
    var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: StandardTools.webSearch,
            summary: "Открыть поиск в интернете в браузере по умолчанию.",
            parameters: [
                ParameterSpec(name: "query", summary: "Что искать", type: .text(maxLength: 200)),
                ParameterSpec(
                    name: "engine",
                    summary: "Поисковая система",
                    type: .choice(StandardTools.searchEngines),
                    isRequired: false
                ),
            ],
            risk: .safe,
            effect: .local
        )
    }

    func run(_ arguments: ValidatedArguments, context: ToolContext) async throws -> ToolOutcome {
        let query = arguments.text("query") ?? ""
        guard let url = Self.url(for: query, engine: arguments.text("engine") ?? "google") else {
            throw ToolFailure.notFound(target: query)
        }
        guard await Browser.open(url) else { throw ToolFailure.actionFailed(target: query) }
        // В журнал — только поисковая система, не запрос.
        return ToolOutcome(message: query, auditDetail: AuditDetail(OpenWebsiteTool.displayHost(url)))
    }

    /// Адрес страницы поиска. Запрос кодируется как параметр — его нельзя «вставить» в адрес:
    /// символы `& = + ? # /` тоже кодируются, иначе «a & b» разделился бы на два параметра.
    static func url(for query: String, engine: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#/")
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }

        let (base, parameter): (String, String) = switch engine {
        case "yandex": ("https://yandex.ru/search/", "text")
        case "duckduckgo": ("https://duckduckgo.com/", "q")
        case "bing": ("https://www.bing.com/search", "q")
        default: ("https://www.google.com/search", "q")
        }
        guard var components = URLComponents(string: base) else { return nil }
        components.percentEncodedQueryItems = [URLQueryItem(name: parameter, value: encoded)]
        return components.url
    }
}
