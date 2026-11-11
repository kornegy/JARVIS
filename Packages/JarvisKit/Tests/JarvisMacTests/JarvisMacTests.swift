import Foundation
import Testing
import JarvisCore
import JarvisTools
@testable import JarvisMac

@Suite("Каталог приложений")
struct AppCatalogTests {
    private let catalog = AppCatalog()

    @Test("Стандартные приложения macOS находятся по разным названиям", arguments: [
        ("калькулятор", "Calculator"), ("Calculator", "Calculator"), ("finder", "Finder"),
        ("TextEdit", "TextEdit"), ("текстэдит", "TextEdit"), ("заметки", "Notes"),
    ])
    func findsSystemApps(spoken: String, bundleName: String) {
        let app = catalog.find(spoken)
        #expect(app != nil)
        #expect(app?.url.deletingPathExtension().lastPathComponent == bundleName)
    }

    /// Safari есть не во всех образах macOS для CI; где он есть — должен находиться,
    /// в том числе по ссылке в /Applications или в системном «криптексе».
    @Test(
        "Safari находится, где бы он ни лежал",
        .enabled(if: ["/Applications/Safari.app", "/System/Cryptexes/App/System/Applications/Safari.app"]
            .contains { FileManager.default.fileExists(atPath: $0) })
    )
    func findsSafari() {
        #expect(catalog.find("сафари")?.url.deletingPathExtension().lastPathComponent == "Safari")
        #expect(catalog.find("Safari") != nil)
    }

    @Test("Выдуманное приложение не находится")
    func unknownApp() {
        #expect(catalog.find("совершенно несуществующее приложение") == nil)
    }

    @Test("У каждого приложения есть имя для ответа")
    func displayNames() {
        let apps = catalog.apps()
        #expect(apps.count > 5)
        #expect(apps.allSatisfy { !$0.displayName.isEmpty && !$0.names.isEmpty })
    }
}

@Suite("Инструменты macOS")
struct MacToolsTests {
    private func registry() throws -> ToolRegistry {
        var registry = ToolRegistry()
        try MacTools.register(into: &registry)
        return registry
    }

    @Test("Регистрируются все инструменты Phase 3a и 3b с правильным уровнем риска")
    func registration() throws {
        let registry = try registry()
        #expect(registry.count == 14)
        let risks = Dictionary(uniqueKeysWithValues: registry.descriptors.map { ($0.name, $0.risk) })
        #expect(risks[StandardTools.openApp] == .safe)
        #expect(risks[StandardTools.quitApp] == .consequential)
        #expect(risks[StandardTools.openWebsite] == .safe)
        #expect(risks[StandardTools.webSearch] == .safe)
        #expect(risks[StandardTools.setVolume] == .safe)
        #expect(risks[StandardTools.changeVolume] == .safe)
        #expect(risks[StandardTools.setMuted] == .safe)
        #expect(risks[StandardTools.findFiles] == .safe)
        #expect(risks[StandardTools.openFile] == .safe)
        #expect(risks[StandardTools.revealFiles] == .safe)
        #expect(risks[StandardTools.moveFiles] == .consequential)
        #expect(risks[StandardTools.renameFile] == .consequential)
        #expect(risks[StandardTools.trashFiles] == .dangerous)
        #expect(risks[StandardTools.undo] == .consequential)
        let find = try #require(registry.descriptors.first { $0.name == StandardTools.findFiles })
        #expect(find.effect == .readOnly)
        #expect(find.producesUntrustedContent)
        #expect(registry.descriptors.filter(\.isUndoable).map(\.name).sorted() == [
            StandardTools.moveFiles, StandardTools.renameFile, StandardTools.trashFiles,
        ].sorted())
    }

    @Test("Подтверждение закрытия называет приложение; не запущенное — понятная ошибка")
    func quitDescribe() async throws {
        let registry = try registry()
        // Калькулятор на машине CI не запущен.
        let prepared = try registry.prepare(ToolCall(toolName: "apps.quit", arguments: ["name": .string("калькулятор")]))
        await #expect(throws: ToolFailure.self) {
            _ = try await prepared.tool.describe(prepared.arguments, context: ToolContext(source: .typedText))
        }
        let open = try registry.prepare(ToolCall(toolName: "apps.open", arguments: ["name": .string("калькулятор")]))
        let summary = try await open.tool.describe(open.arguments, context: ToolContext(source: .typedText))
        #expect(summary.hasPrefix("открыть «"))
    }

    @Test("Сайт: в адресе нельзя ничего, кроме http/https")
    func websiteValidation() throws {
        let registry = try registry()
        #expect(throws: ToolCallError.self) {
            _ = try registry.prepare(ToolCall(toolName: "web.open", arguments: ["url": .string("file:///etc/passwd")]))
        }
        #expect(throws: ToolCallError.self) {
            _ = try registry.prepare(ToolCall(toolName: "web.open", arguments: ["url": .string("javascript:alert(1)")]))
        }
    }
}

@Suite("Поиск в интернете и политика приложений")
struct WebAndPolicyTests {
    @Test("Запрос кодируется как параметр поиска")
    func searchURL() {
        let google = WebSearchTool.url(for: "рецепт борща & блины", engine: "google")
        #expect(google?.host() == "www.google.com")
        #expect(google?.absoluteString.contains("q=") == true)
        #expect(google?.absoluteString.contains(" ") == false)
        #expect(google?.absoluteString.contains("&%20") == false)
        #expect(WebSearchTool.url(for: "cats", engine: "yandex")?.host() == "yandex.ru")
        #expect(WebSearchTool.url(for: "cats", engine: "duckduckgo")?.host() == "duckduckgo.com")
        #expect(WebSearchTool.url(for: "   ", engine: "google") == nil)
    }

    @Test("Имя сайта для ответа — без www")
    func displayHost() throws {
        let url = try #require(URL(string: "https://www.youtube.com/watch"))
        #expect(OpenWebsiteTool.displayHost(url) == "youtube.com")
    }

    @Test("Системные приложения и сам JARVIS защищены от закрытия")
    func protectedApps() {
        #expect(AppPolicy.isProtected(bundleIdentifier: "com.apple.finder"))
        #expect(AppPolicy.isProtected(bundleIdentifier: "com.apple.dock"))
        #expect(!AppPolicy.isProtected(bundleIdentifier: "com.apple.Safari"))
        #expect(!AppPolicy.isProtected(bundleIdentifier: nil))
    }

    @Test("Проценты громкости по-русски и по-английски")
    func volumeFormat() {
        #expect(SystemVolume.format(40, locale: Locale(identifier: "ru_RU")) == "40 %")
        #expect(SystemVolume.format(40, locale: Locale(identifier: "en_US")) == "40%")
    }
}
