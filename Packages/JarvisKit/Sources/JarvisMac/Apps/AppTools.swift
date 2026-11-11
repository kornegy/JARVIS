import AppKit
import JarvisAI
import JarvisCore
import JarvisTools

/// Запущенное приложение (только то, что нужно для поиска и ответа).
struct RunningAppInfo: Sendable, Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let name: String
    let names: [String]
}

/// Политика приложений (docs/Security.md §7): что JARVIS не закрывает никогда.
enum AppPolicy {
    /// Без этих процессов macOS работает неправильно.
    static let protectedBundleIdentifiers: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver",
        "com.apple.WindowManager", "com.apple.controlcenter", "com.apple.notificationcenterui",
        "com.apple.Spotlight", "com.apple.SecurityAgent",
    ]

    static func isProtected(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        if protectedBundleIdentifiers.contains(bundleIdentifier) { return true }
        // Себя JARVIS тоже не закрывает: для этого есть «выключись».
        return bundleIdentifier == Bundle.main.bundleIdentifier
    }
}

/// Работа с приложениями через NSWorkspace. Разрешений macOS не требует, кроме закрытия
/// чужого приложения: macOS может спросить «Автоматизацию» для каждого приложения.
/// AppKit — на главном потоке; наружу отдаются только простые значения.
@MainActor
enum Workspace {
    /// Обычные (с иконкой в Dock) запущенные приложения.
    static func runningApps() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .compactMap { app in
                let fileName = app.bundleURL?.deletingPathExtension().lastPathComponent
                let names = [app.localizedName, fileName].compactMap { $0 }.filter { !$0.isEmpty }
                guard let name = names.first else { return nil }
                return RunningAppInfo(
                    processIdentifier: app.processIdentifier,
                    bundleIdentifier: app.bundleIdentifier,
                    name: name,
                    names: names
                )
            }
    }

    static func findRunning(_ spokenName: String) -> RunningAppInfo? {
        let running = runningApps()
        let candidates = running.map { AppNameCandidate(id: String($0.processIdentifier), names: $0.names) }
        guard let best = AppNameMatcher.bestMatch(for: spokenName, in: candidates) else { return nil }
        return running.first { String($0.processIdentifier) == best.id }
    }

    /// Открыть (или вывести на передний план) приложение. `false` — приложения уже нет на диске.
    ///
    /// Без обработчика завершения: замыкание, созданное на главном потоке, macOS вызвала бы
    /// с другого потока, а Swift 6 считает это нарушением изоляции и завершает приложение.
    static func launch(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
        return true
    }

    /// Попросить приложение завершиться (как ⌘Q: оно может спросить о несохранённом).
    static func terminate(_ processIdentifier: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: processIdentifier)?.terminate() ?? false
    }

    /// Браузер по умолчанию.
    static func defaultBrowser() -> URL? {
        guard let probe = URL(string: "https://www.apple.com") else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: probe)
    }
}

/// Язык фраз для подтверждения и ответов.
enum Phrasing {
    static func isEnglish(_ locale: Locale) -> Bool {
        locale.language.languageCode?.identifier == "en"
    }

    static func quoted(_ name: String, _ locale: Locale) -> String {
        isEnglish(locale) ? "“\(name)”" : "«\(name)»"
    }
}

/// «Открой Safari», «переключись на Telegram». Категория 1: выполняется сразу.
struct OpenAppTool: Tool {
    let catalog: AppCatalog

    static let browserWords: Set<String> = ["браузер", "браузеры", "browser", "web browser"]

    var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: StandardTools.openApp,
            summary: "Открыть приложение или переключиться на него.",
            parameters: [ParameterSpec(name: "name", summary: "Название приложения", type: .text(maxLength: 100))],
            risk: .safe,
            effect: .local
        )
    }

    func describe(_ arguments: ValidatedArguments, context: ToolContext) async throws -> String {
        let app = try await resolve(arguments)
        let name = Phrasing.quoted(app.name, context.locale)
        return Phrasing.isEnglish(context.locale) ? "open \(name)" : "открыть \(name)"
    }

    func run(_ arguments: ValidatedArguments, context: ToolContext) async throws -> ToolOutcome {
        let app = try await resolve(arguments)
        guard await Workspace.launch(app.url) else { throw ToolFailure.actionFailed(target: app.name) }
        return ToolOutcome(message: app.name, auditDetail: AuditDetail(app.name))
    }

    private func resolve(_ arguments: ValidatedArguments) async throws -> (url: URL, name: String) {
        let spoken = arguments.text("name") ?? ""
        if Self.browserWords.contains(TextNormalizer.normalize(spoken)), let browser = await Workspace.defaultBrowser() {
            let name = (FileManager.default.displayName(atPath: browser.path) as NSString).deletingPathExtension
            return (browser, name)
        }
        guard let app = catalog.find(spoken) else { throw ToolFailure.notFound(target: spoken) }
        return (app.url, app.displayName)
    }
}

/// «Закрой Safari». Категория 2: по умолчанию с подтверждением, системные приложения — никогда.
struct QuitAppTool: Tool {
    let catalog: AppCatalog

    var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: StandardTools.quitApp,
            summary: "Закрыть приложение (как ⌘Q).",
            parameters: [ParameterSpec(name: "name", summary: "Название приложения", type: .text(maxLength: 100))],
            risk: .consequential,
            requiredPermissions: [.appleEvents],
            effect: .local
        )
    }

    func describe(_ arguments: ValidatedArguments, context: ToolContext) async throws -> String {
        let app = try await resolve(arguments)
        let name = Phrasing.quoted(app.name, context.locale)
        return Phrasing.isEnglish(context.locale) ? "quit \(name)" : "закрыть \(name)"
    }

    func run(_ arguments: ValidatedArguments, context: ToolContext) async throws -> ToolOutcome {
        let app = try await resolve(arguments)
        guard await Workspace.terminate(app.processIdentifier) else { throw ToolFailure.actionFailed(target: app.name) }
        return ToolOutcome(message: app.name, auditDetail: AuditDetail(app.name))
    }

    /// Находит запущенное приложение и проверяет политику — ещё до вопроса пользователю.
    private func resolve(_ arguments: ValidatedArguments) async throws -> RunningAppInfo {
        let spoken = arguments.text("name") ?? ""
        guard let app = await Workspace.findRunning(spoken) else {
            if let installed = catalog.find(spoken) {
                throw ToolFailure.notRunning(target: installed.displayName)
            }
            throw ToolFailure.notFound(target: spoken)
        }
        if AppPolicy.isProtected(bundleIdentifier: app.bundleIdentifier) {
            throw ToolFailure.protectedTarget(target: app.name)
        }
        return app
    }
}
