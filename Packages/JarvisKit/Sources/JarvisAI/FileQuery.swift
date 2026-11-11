/// Тип файла, который назвал пользователь («PDF», «скриншот», «папка»).
public enum FileKind: String, Sendable, CaseIterable {
    case pdf
    case image
    case screenshot
    case video
    case audio
    case document
    case presentation
    case spreadsheet
    case archive
    case folder
}

/// Стандартная папка в домашней папке пользователя.
public enum FileLocation: String, Sendable, CaseIterable {
    case home
    case desktop
    case documents
    case downloads
    case pictures

    /// Имя папки на диске. В Finder она может называться по-русски («Загрузки»),
    /// но на диске имя всегда английское.
    public var folderName: String? {
        switch self {
        case .home: nil
        case .desktop: "Desktop"
        case .documents: "Documents"
        case .downloads: "Downloads"
        case .pictures: "Pictures"
        }
    }

    /// Абсолютный путь к папке внутри домашней папки `home`.
    public func path(inHome home: String) -> String {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard let folderName else { return base }
        return base + "/" + folderName
    }
}

/// За какой период искать («за сегодня», «вчерашний», «за неделю»).
public enum FilePeriod: String, Sendable, CaseIterable {
    case today
    case yesterday
    case week
}

/// Что за файл ищет пользователь. Все поля необязательны: «последний скачанный PDF» —
/// это тип, папка и «сначала новые», без названия.
public struct FileQuery: Sendable, Equatable {
    /// Слова из названия, как их сказал пользователь («отчет за март»).
    public var name: String?
    public var kind: FileKind?
    public var location: FileLocation?
    public var period: FilePeriod?
    /// «Последний», «самый свежий»: сначала самые новые, и если нужен один файл — берётся первый.
    public var latest: Bool

    public init(
        name: String? = nil,
        kind: FileKind? = nil,
        location: FileLocation? = nil,
        period: FilePeriod? = nil,
        latest: Bool = false
    ) {
        self.name = name
        self.kind = kind
        self.location = location
        self.period = period
        self.latest = latest
    }

    /// Есть хоть один признак, по которому можно искать. «Найди файл» без подробностей — нет.
    public var isSpecific: Bool {
        name != nil || kind != nil || location != nil || period != nil || latest
    }
}

/// О каком файле речь в команде.
public enum FileTarget: Sendable, Equatable {
    /// Файл по описанию («последний скачанный PDF», «файл отчет»).
    case query(FileQuery)
    /// Все файлы по описанию («все скриншоты с рабочего стола»).
    case all(FileQuery)
    /// Файл из последнего ответа: «открой его» — 0, «открой второй» — 1.
    case previous(Int)
    /// Все файлы из последнего ответа: «удали их».
    case previousAll
    /// Стандартная папка целиком («открой загрузки»).
    case location(FileLocation)
}

/// Куда переместить файл.
public enum FolderTarget: Sendable, Equatable {
    /// Стандартная папка («в Документы», «на рабочий стол»).
    case location(FileLocation)
    /// Папка по названию («в папку Работа»).
    case named(String)
}

/// Подходит ли имя файла к словам, которые сказал пользователь.
///
/// Распознавание речи пишет слова в разных падежах и иногда латиницей, а имена файлов —
/// как получится: «Отчёт за март.docx», «otchet_mart.pdf». Поэтому сравниваются основы
/// слов (без окончаний) — и в кириллице, и в латинской «форме» (как для фразы-активатора).
public enum FileNameMatcher {
    /// Значимые слова запроса: без коротких служебных («за», «в»), числа оставляются.
    public static func terms(_ name: String) -> [String] {
        TextNormalizer.words(name).filter { $0.count >= 3 || $0.allSatisfy(\.isNumber) }
    }

    /// Основа слова без окончания: «отчета» → «отче», «диплома» → «дипло».
    public static func stem(_ word: String) -> String {
        if word.allSatisfy(\.isNumber) { return word }
        switch word.count {
        case 6...: return String(word.prefix(word.count - 2))
        case 5: return String(word.prefix(4))
        default: return word
        }
    }

    /// Формы каждого значимого слова для поиска в Spotlight: основа и её латинская «форма»
    /// («отчета» → «отче», «otche»). Только буквы и цифры.
    public static func searchForms(_ name: String) -> [[String]] {
        terms(name).map { term in
            let base = stem(term)
            let latin = FuzzyWord.skeleton(base)
            return latin == base ? [base] : [base, latin]
        }
    }

    /// Оценка совпадения: 0 — не подходит. Чем выше, тем лучше: точное имя > начало имени >
    /// все слова где-то в имени. Пустой запрос подходит к любому имени (оценка 1).
    public static func score(fileName: String, query: String) -> Int {
        let queryTerms = terms(query)
        guard !queryTerms.isEmpty else { return 1 }
        let fullName = TextNormalizer.normalize(fileName)
        let baseName = TextNormalizer.normalize(withoutExtension(fileName))
        let phrase = TextNormalizer.normalize(query)
        let nameSkeleton = FuzzyWord.skeleton(fullName)

        var total = 100
        for term in queryTerms {
            if fullName.contains(term) {
                total += 10
            } else if fullName.contains(stem(term)) || nameSkeleton.contains(FuzzyWord.skeleton(stem(term))) {
                total += 5
            } else {
                return 0
            }
        }
        if baseName == phrase { return total + 200 }
        if baseName.hasPrefix(phrase) { return total + 100 }
        return total
    }

    private static func withoutExtension(_ fileName: String) -> String {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return fileName }
        return String(fileName[..<dot])
    }
}

/// Русские формы числительных: «1 файл», «3 файла», «12 файлов».
public enum RussianPlural {
    public static func form(_ count: Int, one: String, few: String, many: String) -> String {
        let lastTwo = abs(count) % 100
        let last = lastTwo % 10
        if (11...14).contains(lastTwo) { return many }
        switch last {
        case 1: return one
        case 2...4: return few
        default: return many
        }
    }

    /// «3 файла».
    public static func files(_ count: Int) -> String {
        "\(count) " + form(count, one: "файл", few: "файла", many: "файлов")
    }
}
