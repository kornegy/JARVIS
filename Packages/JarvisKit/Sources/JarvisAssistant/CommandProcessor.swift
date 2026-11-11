import Foundation
import JarvisAI
import JarvisCore
import JarvisTools

/// Изменение состояния ассистента, которое просит команда.
public enum AssistantDirective: Sendable, Equatable {
    case disableAssistant
    case pauseMicrophone
    case setPrivacyMode(Bool)
}

/// Действие, которое ждёт подтверждения пользователя («Точно закрыть «Safari»?»).
///
/// Хранит уже проверенный вызов инструмента: после «да» выполняется **ровно то**, что
/// было показано, без повторного разбора команды.
public struct PendingAction: Sendable, Equatable {
    public let id: UUID
    /// Что именно будет сделано — для окна подтверждения («закрыть «Safari»»).
    public let summary: String
    /// `false` — подтвердить можно только кнопкой или клавишей (категория 3).
    public let allowsVoiceConfirmation: Bool
    public let isDangerous: Bool
    /// Имена файлов, которых касается действие, — окно подтверждения показывает их все
    /// (docs/Security.md §5: «какие файлы, куда»).
    public let items: [String]
    let call: PreparedToolCall
    let intent: Intent
    let source: CommandSource

    public static func == (lhs: PendingAction, rhs: PendingAction) -> Bool { lhs.id == rhs.id }
}

/// Почему действие не выполнено после вопроса.
public enum DeclineReason: Sendable, Equatable {
    /// Пользователь ответил «нет» или нажал «Нет»/Esc.
    case declined
    /// 30 секунд без ответа.
    case timedOut
    /// Ответ не распознан — безопасный вариант: ничего не делать.
    case notUnderstood
    /// Ассистент выключили, пока он ждал ответа.
    case cancelled
}

/// Результат обработки команды.
public struct CommandOutcome: Sendable, Equatable {
    public let intent: Intent
    /// Ответ пользователю (живёт только в памяти).
    public let reply: String
    public let directive: AssistantDirective?
    /// Какие инструменты были выполнены (для обновления журнала в интерфейсе).
    public let executedActions: [ActionIdentifier]
    /// Действие ждёт подтверждения — `reply` содержит вопрос.
    public let pendingAction: PendingAction?

    public init(
        intent: Intent,
        reply: String,
        directive: AssistantDirective? = nil,
        executedActions: [ActionIdentifier] = [],
        pendingAction: PendingAction? = nil
    ) {
        self.intent = intent
        self.reply = reply
        self.directive = directive
        self.executedActions = executedActions
        self.pendingAction = pendingAction
    }
}

/// Настройки, с которыми обрабатывается команда.
public struct CommandContext: Sendable {
    public var locale: Locale
    public var personality: Personality
    public var confirmationPolicy: ConfirmationPolicy
    /// Поисковая система для «найди в интернете» (`google`, `yandex`, `duckduckgo`, `bing`).
    public var searchEngine: String

    public init(
        locale: Locale,
        personality: Personality = Personality(),
        confirmationPolicy: ConfirmationPolicy = ConfirmationPolicy(),
        searchEngine: String = "google"
    ) {
        self.locale = locale
        self.personality = personality
        self.confirmationPolicy = confirmationPolicy
        self.searchEngine = searchEngine
    }
}

/// Превращает фразу в действие и ответ.
///
/// Цепочка: правила → намерение → инструмент из реестра → проверка аргументов →
/// политика подтверждения (если нужно — вопрос пользователю) → выполнение → журнал → ответ.
/// Текст команды никуда не записывается: в журнал попадает только идентификатор действия.
@MainActor
public final class CommandProcessor {
    /// Шаг громкости для «громче» / «тише», проценты.
    public static let volumeStep = 10

    /// Сколько файлов JARVIS запоминает из одного поиска («открой пятый»).
    public static let listLimit = 20
    /// Через сколько секунд «его» и «второй» забываются.
    public static let recentFilesLifetime: TimeInterval = 600

    private let parser = RuleIntentParser()
    private let registry: ToolRegistry
    private let validator: ArgumentValidator
    private let auditLog: AuditLog
    private let permissions: (any PermissionChecking)?
    private let now: () -> Date
    private var composer: ResponseComposer
    private let log = JarvisLogger(category: "commands")

    /// Файлы из последнего ответа — для «открой его», «открой второй». Только в памяти.
    private var recentFiles: [String] = []
    private var recentFilesUpdatedAt: Date?
    /// Действие, которое ждёт выбора файла из списка («Какой из них?» → «второй»).
    private var pendingChoice: FileAction?

    public init(
        registry: ToolRegistry,
        auditLog: AuditLog,
        validator: ArgumentValidator = ArgumentValidator(),
        permissions: (any PermissionChecking)? = nil,
        random: any RandomNumberGenerator = SystemRandomNumberGenerator(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.registry = registry
        self.auditLog = auditLog
        self.validator = validator
        self.permissions = permissions
        self.now = now
        self.composer = ResponseComposer(random: random)
    }

    /// Забыть найденные файлы и незаконченный выбор (ассистент выключен).
    public func forgetContext() {
        recentFiles = []
        recentFilesUpdatedAt = nil
        pendingChoice = nil
    }

    public func handle(_ utterance: Utterance, source: CommandSource, context: CommandContext) async -> CommandOutcome {
        configureComposer(context)
        let intent = parser.parse(utterance.text)
        log.info("Command interpreted", .token("parser", "rules"), .bool("recognized", intent != .unknown))
        // Вопрос «какой из них?» действует только до следующей команды.
        let choice = pendingChoice
        pendingChoice = nil

        switch intent {
        case .currentTime:
            return await perform(BuiltInTools.currentTime, intent: intent, source: source, context: context)
        case .currentDate:
            return await perform(BuiltInTools.currentDate, intent: intent, source: source, context: context)
        case .openApp(let name):
            let attempt = await self.attempt(StandardTools.openApp, ["name": .string(name)], intent: intent, source: source, context: context)
            // Приложения нет, но это известный сайт («открой ютуб») — открываем сайт.
            if case .failed(.notFound(_), _) = attempt, let url = SiteDirectory.url(for: name) {
                return await perform(
                    StandardTools.openWebsite,
                    ["url": .string(url.absoluteString)],
                    intent: .openWebsite(name),
                    source: source,
                    context: context
                )
            }
            return finish(attempt, intent: intent)
        case .quitApp(let name):
            return await perform(StandardTools.quitApp, ["name": .string(name)], intent: intent, source: source, context: context)
        case .openWebsite(let site):
            guard let url = SiteDirectory.url(for: site) else {
                return CommandOutcome(intent: intent, reply: composer.text(for: .siteNotFound(site)))
            }
            return await perform(StandardTools.openWebsite, ["url": .string(url.absoluteString)], intent: intent, source: source, context: context)
        case .webSearch(let query):
            let arguments: [String: ArgumentValue] = ["query": .string(query), "engine": .string(context.searchEngine)]
            return await perform(StandardTools.webSearch, arguments, intent: intent, source: source, context: context)
        case .setVolume(let level):
            return await perform(StandardTools.setVolume, ["level": .integer(level)], intent: intent, source: source, context: context)
        case .changeVolume(let direction):
            let delta = direction == .up ? Self.volumeStep : -Self.volumeStep
            return await perform(StandardTools.changeVolume, ["delta": .integer(delta)], intent: intent, source: source, context: context)
        case .setMuted(let muted):
            return await perform(StandardTools.setMuted, ["muted": .boolean(muted)], intent: intent, source: source, context: context)
        case .findFiles(let query):
            guard query.isSpecific else { return CommandOutcome(intent: intent, reply: composer.text(for: .needFileDescription)) }
            return await perform(StandardTools.findFiles, Self.findArguments(query, limit: Self.listLimit), intent: intent, source: source, context: context)
        case .openFile(let target):
            return await fileAction(.open, target, intent: intent, source: source, context: context)
        case .revealFile(let target):
            return await fileAction(.reveal, target, intent: intent, source: source, context: context)
        case .moveFile(let target, let destination):
            return await fileAction(.move(destination), target, intent: intent, source: source, context: context)
        case .renameFile(let target, let newName):
            return await fileAction(.rename(newName), target, intent: intent, source: source, context: context)
        case .trashFile(let target):
            return await fileAction(.trash, target, intent: intent, source: source, context: context)
        case .chooseItem(let index):
            // «Второй» без вопроса, но после списка — открыть.
            guard let action = choice ?? (currentRecentFiles().isEmpty ? nil : .open) else {
                return CommandOutcome(intent: intent, reply: composer.text(for: .noRecentFiles))
            }
            let target = FileTarget.previous(index)
            return await fileAction(action, target, intent: action.intent(target), source: source, context: context)
        case .undo:
            return await perform(StandardTools.undo, intent: intent, source: source, context: context)
        case .disableAssistant:
            return CommandOutcome(intent: intent, reply: composer.reply(to: intent), directive: .disableAssistant)
        case .pauseMicrophone:
            return CommandOutcome(intent: intent, reply: composer.reply(to: intent), directive: .pauseMicrophone)
        case .setPrivacyMode(let enabled):
            return CommandOutcome(intent: intent, reply: composer.reply(to: intent), directive: .setPrivacyMode(enabled))
        case .empty, .greeting, .attention, .thanks, .capabilities, .cancel, .notYetSupported, .unknown:
            return CommandOutcome(intent: intent, reply: composer.reply(to: intent))
        }
    }

    /// Пользователь позвал ассистента, но команды не сказал («Привет, Джарвис», «Джарвис?»).
    /// Откликаемся, а не молчим: на приветствие — приветствием, на имя — «Слушаю».
    public func acknowledgeAddress(_ utterance: Utterance, context: CommandContext) -> CommandOutcome {
        configureComposer(context)
        let intent: Intent = parser.parse(utterance.text) == .greeting ? .greeting : .attention
        return CommandOutcome(intent: intent, reply: composer.reply(to: intent))
    }

    /// Пользователь подтвердил: выполняется ровно тот вызов, который был показан.
    public func confirm(_ pending: PendingAction, context: CommandContext) async -> CommandOutcome {
        configureComposer(context)
        let result = await execute(pending.call, intent: pending.intent, source: pending.source, context: context, confirmed: true)
        return finish(result, intent: pending.intent)
    }

    /// Пользователь отказался (или не ответил): ничего не выполняется, в журнале — «отменено».
    public func decline(_ pending: PendingAction, reason: DeclineReason, context: CommandContext) async -> CommandOutcome {
        configureComposer(context)
        await record(pending.call.descriptor, source: pending.source, outcome: .cancelledByUser, confirmationRequired: true)
        let reply: ActionReply = switch reason {
        case .declined, .cancelled: .declined
        case .timedOut: .timedOut
        case .notUnderstood: .answerNotUnderstood
        }
        return CommandOutcome(intent: pending.intent, reply: composer.text(for: reply))
    }

    // MARK: - Выполнение

    private enum Attempt {
        case done(CommandOutcome)
        case failed(ToolFailure, ToolName)
    }

    private func perform(
        _ name: ToolName,
        _ arguments: [String: ArgumentValue] = [:],
        intent: Intent,
        source: CommandSource,
        context: CommandContext,
        affectedItemCount: Int = 1
    ) async -> CommandOutcome {
        let result = await attempt(name, arguments, intent: intent, source: source, context: context, affectedItemCount: affectedItemCount)
        return finish(result, intent: intent)
    }

    private func attempt(
        _ name: ToolName,
        _ arguments: [String: ArgumentValue],
        intent: Intent,
        source: CommandSource,
        context: CommandContext,
        affectedItemCount: Int = 1
    ) async -> Attempt {
        let prepared: PreparedToolCall
        do {
            prepared = try registry.prepare(ToolCall(toolName: name.rawValue, arguments: arguments), validator: validator)
        } catch {
            log.error("Tool preparation failed", .error(error))
            return .done(CommandOutcome(intent: intent, reply: composer.text(for: .failure)))
        }

        let descriptor = prepared.descriptor
        // Нужное разрешение точно не выдано — не спрашиваем и не выполняем, а говорим, где его дать.
        if let missing = deniedPermission(for: descriptor) {
            return .failed(.permissionDenied(missing), descriptor.name)
        }
        // Массовая операция (больше 10 файлов) политика поднимет до категории 3.
        let plan = PlanContext(source: source, affectedItemCount: affectedItemCount)
        let requirement = context.confirmationPolicy.requirement(for: descriptor, context: plan)
        guard case .required(let request) = requirement else {
            return await execute(prepared, intent: intent, source: source, context: context, confirmed: false)
        }

        // Сначала выясняем, что именно будет сделано (и существует ли цель), потом спрашиваем.
        let summary: String
        do {
            summary = try await prepared.tool.describe(prepared.arguments, context: ToolContext(source: source, locale: context.locale))
        } catch let failure as ToolFailure {
            return .failed(failure, descriptor.name)
        } catch {
            log.error("Tool description failed", .error(error))
            return .done(CommandOutcome(intent: intent, reply: composer.text(for: .failure)))
        }

        let pending = PendingAction(
            id: UUID(),
            summary: summary,
            allowsVoiceConfirmation: request.allowsVoiceConfirmation,
            isDangerous: request.reasons.contains(.dangerousAction) || request.reasons.contains(.bulkOperation),
            items: Self.itemNames(prepared.arguments),
            call: prepared,
            intent: intent,
            source: source
        )
        let question: ActionReply = request.allowsVoiceConfirmation
            ? .confirmationQuestion(summary)
            : .confirmationRequiredPhysically(summary)
        log.notice("Confirmation requested", .bool("voiceAllowed", request.allowsVoiceConfirmation))
        return .done(CommandOutcome(intent: intent, reply: composer.text(for: question), pendingAction: pending))
    }

    private func execute(
        _ prepared: PreparedToolCall,
        intent: Intent,
        source: CommandSource,
        context: CommandContext,
        confirmed: Bool
    ) async -> Attempt {
        let descriptor = prepared.descriptor
        do {
            let outcome = try await prepared.tool.run(prepared.arguments, context: ToolContext(source: source, locale: context.locale))
            await record(descriptor, source: source, outcome: .succeeded, confirmationRequired: confirmed, detail: outcome.auditDetail)
            if let files = outcome.files { remember(files) }
            return .done(CommandOutcome(
                intent: intent,
                reply: composer.reply(to: intent, value: outcome.message),
                executedActions: [descriptor.name]
            ))
        } catch let failure as ToolFailure {
            await record(descriptor, source: source, outcome: .failed, confirmationRequired: confirmed)
            return .failed(failure, descriptor.name)
        } catch {
            log.error("Tool failed", .error(error))
            await record(descriptor, source: source, outcome: .failed, confirmationRequired: confirmed)
            return .done(CommandOutcome(intent: intent, reply: composer.text(for: .failure)))
        }
    }

    private func finish(_ attempt: Attempt, intent: Intent) -> CommandOutcome {
        switch attempt {
        case .done(let outcome):
            return outcome
        case .failed(let failure, let tool):
            return CommandOutcome(intent: intent, reply: composer.text(for: Self.reply(for: failure, tool: tool)))
        }
    }

    static func reply(for failure: ToolFailure, tool: ToolName) -> ActionReply {
        let isFileTool = StandardTools.fileTools.contains(tool)
        switch failure {
        case .notFound(let target):
            if tool == StandardTools.openWebsite { return .siteNotFound(target) }
            return isFileTool ? .fileNotFound(target) : .appNotFound(target)
        case .notRunning(let target): return .notRunning(target)
        case .protectedTarget(let target): return isFileTool ? .protectedFile(target) : .protectedApp(target)
        case .actionFailed(let target): return isFileTool ? .fileActionFailed(target) : .actionFailed(target)
        case .unsupported: return .unsupported
        case .alreadyExists(let target): return .alreadyExists(target)
        case .accessDenied(let target): return .noFolderAccess(target)
        case .permissionDenied(let kind): return .permissionNeeded(pane(for: kind))
        case .unsafeToOpen(let target): return .unsafeToOpen(target)
        case .nothingToUndo: return .nothingToUndo
        }
    }

    static func pane(for kind: PermissionKind) -> SettingsPane {
        switch kind {
        case .microphone: .microphone
        case .speechRecognition: .speechRecognition
        case .accessibility: .accessibility
        case .appleEvents: .automation
        case .filesAndFolders: .filesAndFolders
        case .calendars, .reminders, .notifications, .location: .privacy
        }
    }

    private func deniedPermission(for descriptor: ToolDescriptor) -> PermissionKind? {
        guard let permissions else { return nil }
        return descriptor.requiredPermissions
            .sorted { $0.rawValue < $1.rawValue }
            .first { permissions.status(for: $0) == .denied }
    }

    // MARK: - Файлы

    /// Что сделать с файлом, когда станет ясно, с каким.
    enum FileAction: Equatable {
        case open
        case reveal
        case move(FolderTarget?)
        case rename(String?)
        case trash

        func intent(_ target: FileTarget) -> Intent {
            switch self {
            case .open: .openFile(target)
            case .reveal: .revealFile(target)
            case .move(let destination): .moveFile(target, destination)
            case .rename(let name): .renameFile(target, name)
            case .trash: .trashFile(target)
            }
        }

        /// Действие только над одним файлом.
        var needsSingleFile: Bool {
            switch self {
            case .open, .rename: true
            case .reveal, .move, .trash: false
            }
        }
    }

    private enum Resolution {
        case files([String])
        case reply(CommandOutcome)
    }

    /// Файловая команда: понять, о каких файлах речь (найти, взять из прошлого ответа),
    /// и вызвать инструмент с точными путями. После подтверждения выполняются ровно эти пути.
    private func fileAction(
        _ action: FileAction,
        _ target: FileTarget,
        intent: Intent,
        source: CommandSource,
        context: CommandContext
    ) async -> CommandOutcome {
        // Сначала — чего не хватает в самой команде, чтобы не искать зря.
        if case .move(.none) = action { return CommandOutcome(intent: intent, reply: composer.text(for: .needDestination)) }
        if case .rename(.none) = action { return CommandOutcome(intent: intent, reply: composer.text(for: .needNewName)) }

        let files: [String]
        switch await resolve(target, for: action, intent: intent, source: source, context: context) {
        case .files(let found): files = found
        case .reply(let outcome): return outcome
        }
        guard let first = files.first else { return CommandOutcome(intent: intent, reply: composer.text(for: .noRecentFiles)) }
        if action.needsSingleFile, files.count > 1 {
            return CommandOutcome(intent: intent, reply: composer.text(for: .onlyOneFile))
        }
        let pathList = ArgumentValue.list(files.map { .string($0) })

        switch action {
        case .open:
            return await perform(StandardTools.openFile, ["path": .string(first)], intent: intent, source: source, context: context)
        case .reveal:
            return await perform(StandardTools.revealFiles, ["paths": pathList], intent: intent, source: source, context: context)
        case .move(let destination?):
            let folder: String
            switch await resolveFolder(destination, intent: intent, source: source, context: context) {
            case .files(let found):
                guard let path = found.first else { return CommandOutcome(intent: intent, reply: composer.text(for: .failure)) }
                folder = path
            case .reply(let outcome):
                return outcome
            }
            return await perform(
                StandardTools.moveFiles,
                ["paths": pathList, "destination": .string(folder)],
                intent: intent,
                source: source,
                context: context,
                affectedItemCount: files.count
            )
        case .rename(let newName?):
            return await perform(
                StandardTools.renameFile,
                ["path": .string(first), "newName": .string(String(newName.prefix(200)))],
                intent: intent,
                source: source,
                context: context
            )
        case .trash:
            return await perform(StandardTools.trashFiles, ["paths": pathList], intent: intent, source: source, context: context, affectedItemCount: files.count)
        case .move(.none), .rename(.none):
            return CommandOutcome(intent: intent, reply: composer.text(for: .failure))
        }
    }

    private func resolve(
        _ target: FileTarget,
        for action: FileAction,
        intent: Intent,
        source: CommandSource,
        context: CommandContext
    ) async -> Resolution {
        switch target {
        case .location(let location):
            return .files([location.path(inHome: validator.homeDirectory)])

        case .previous(let index):
            let recent = currentRecentFiles()
            guard !recent.isEmpty else { return .reply(CommandOutcome(intent: intent, reply: composer.text(for: .noRecentFiles))) }
            guard recent.indices.contains(index) else {
                return .reply(CommandOutcome(intent: intent, reply: composer.text(for: .noSuchItem(available: recent.count))))
            }
            return .files([recent[index]])

        case .previousAll:
            let recent = currentRecentFiles()
            guard !recent.isEmpty else { return .reply(CommandOutcome(intent: intent, reply: composer.text(for: .noRecentFiles))) }
            return .files(recent)

        case .query(let query):
            guard Self.canSearch(query) else {
                return .reply(CommandOutcome(intent: intent, reply: composer.text(for: .needFileDescription)))
            }
            let found = await find(query, limit: Self.listLimit, intent: intent, source: source, context: context)
            guard case .files(let paths) = found, let first = paths.first else { return found }
            remember(paths)
            if paths.count == 1 || query.latest { return .files([first]) }
            // Несколько подходящих, а действие над одним файлом — спрашиваем, какой.
            pendingChoice = action
            let names = paths.prefix(3).map(Self.displayName)
            return .reply(CommandOutcome(
                intent: intent,
                reply: composer.text(for: .whichFile(names: Array(names), total: paths.count)),
                executedActions: [StandardTools.findFiles]
            ))

        case .all(let query):
            guard Self.canSearch(query) else {
                return .reply(CommandOutcome(intent: intent, reply: composer.text(for: .needFileDescription)))
            }
            let limit = StandardTools.maxFilesPerAction
            let found = await find(query, limit: limit + 1, intent: intent, source: source, context: context)
            guard case .files(let paths) = found else { return found }
            guard paths.count <= limit else {
                return .reply(CommandOutcome(intent: intent, reply: composer.text(for: .tooManyFiles(limit: limit)), executedActions: [StandardTools.findFiles]))
            }
            remember(paths)
            return .files(paths)
        }
    }

    /// Папка назначения: стандартная — по пути, остальные — поиском папки по названию.
    private func resolveFolder(
        _ destination: FolderTarget,
        intent: Intent,
        source: CommandSource,
        context: CommandContext
    ) async -> Resolution {
        switch destination {
        case .location(let location):
            return .files([location.path(inHome: validator.homeDirectory)])
        case .named(let name):
            return await find(
                FileQuery(name: name, kind: .folder),
                limit: 5,
                intent: intent,
                source: source,
                context: context,
                notFound: .folderNotFound(name)
            )
        }
    }

    /// Поиск как шаг другой команды: результат — пути, а не ответ пользователю.
    private func find(
        _ query: FileQuery,
        limit: Int,
        intent: Intent,
        source: CommandSource,
        context: CommandContext,
        notFound: ActionReply? = nil
    ) async -> Resolution {
        let prepared: PreparedToolCall
        do {
            let call = ToolCall(toolName: StandardTools.findFiles.rawValue, arguments: Self.findArguments(query, limit: limit))
            prepared = try registry.prepare(call, validator: validator)
        } catch {
            log.error("Tool preparation failed", .error(error))
            return .reply(CommandOutcome(intent: intent, reply: composer.text(for: .failure)))
        }
        let descriptor = prepared.descriptor
        if let missing = deniedPermission(for: descriptor) {
            return .reply(CommandOutcome(intent: intent, reply: composer.text(for: .permissionNeeded(Self.pane(for: missing)))))
        }
        do {
            let outcome = try await prepared.tool.run(prepared.arguments, context: ToolContext(source: source, locale: context.locale))
            await record(descriptor, source: source, outcome: .succeeded, detail: outcome.auditDetail)
            let paths = outcome.files ?? []
            guard !paths.isEmpty else {
                return .reply(CommandOutcome(intent: intent, reply: composer.text(for: notFound ?? .fileNotFound(query.name ?? ""))))
            }
            return .files(paths)
        } catch let failure as ToolFailure {
            await record(descriptor, source: source, outcome: .failed)
            let reply: ActionReply = if case .notFound = failure, let notFound {
                notFound
            } else {
                Self.reply(for: failure, tool: descriptor.name)
            }
            return .reply(CommandOutcome(intent: intent, reply: composer.text(for: reply), executedActions: [descriptor.name]))
        } catch {
            log.error("Tool failed", .error(error))
            await record(descriptor, source: source, outcome: .failed)
            return .reply(CommandOutcome(intent: intent, reply: composer.text(for: .failure)))
        }
    }

    /// Достаточно ли описания, чтобы искать: «открой папку» без названия — нет.
    static func canSearch(_ query: FileQuery) -> Bool {
        guard query.isSpecific else { return false }
        if query.kind == .folder, query.name == nil, query.location == nil, !query.latest, query.period == nil { return false }
        return true
    }

    static func findArguments(_ query: FileQuery, limit: Int) -> [String: ArgumentValue] {
        var arguments: [String: ArgumentValue] = ["limit": .integer(limit)]
        if let name = query.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            arguments["name"] = .string(String(name.prefix(100)))
        }
        if let kind = query.kind { arguments["kind"] = .string(kind.rawValue) }
        if let location = query.location { arguments["location"] = .string(location.rawValue) }
        if let period = query.period { arguments["period"] = .string(period.rawValue) }
        if query.latest { arguments["latest"] = .boolean(true) }
        return arguments
    }

    /// Имена файлов из аргументов — для окна подтверждения.
    static func itemNames(_ arguments: ValidatedArguments) -> [String] {
        var paths: [String] = []
        if let path = arguments.text("path") { paths.append(path) }
        for value in arguments.list("paths") ?? [] {
            if case .string(let path) = value { paths.append(path) }
        }
        return paths.map(displayName)
    }

    /// Имя файла для ответа: без управляющих символов и не длиннее 80 знаков.
    static func displayName(_ path: String) -> String {
        let name = URL(filePath: path).lastPathComponent
        let cleaned = String(String.UnicodeScalarView(name.unicodeScalars.map { scalar in
            let category = scalar.properties.generalCategory
            return category == .control || category == .format ? " " : scalar
        }))
        return cleaned.count > 80 ? String(cleaned.prefix(79)) + "…" : cleaned
    }

    private func remember(_ files: [String]) {
        recentFiles = files
        recentFilesUpdatedAt = files.isEmpty ? nil : now()
    }

    private func currentRecentFiles() -> [String] {
        guard let updated = recentFilesUpdatedAt, now().timeIntervalSince(updated) < Self.recentFilesLifetime else { return [] }
        return recentFiles
    }

    private func configureComposer(_ context: CommandContext) {
        composer.personality = context.personality
        composer.language = ResponseLanguage(locale: context.locale)
    }

    private func record(
        _ descriptor: ToolDescriptor,
        source: CommandSource,
        outcome: AuditOutcome,
        confirmationRequired: Bool = false,
        detail: AuditDetail? = nil
    ) async {
        do {
            try await auditLog.record(AuditEvent(
                action: descriptor.name,
                source: source,
                risk: descriptor.risk,
                outcome: outcome,
                confirmationRequired: confirmationRequired,
                detail: detail
            ))
        } catch {
            log.error("Audit record failed", .error(error))
        }
    }
}
