import Foundation

/// Разбор команд про файлы: найти, открыть, показать в Finder, переместить,
/// переименовать, удалить в Корзину (русский и английский).
///
/// Правила намеренно осторожные: «открой фото» — это приложение «Фото», а не поиск
/// фотографий, «найди рецепт борща» — поиск в интернете. Команда считается файловой, только
/// если в ней есть признаки файла: слово «файл»/«папка», тип («PDF», «скриншот»), папка
/// («в Загрузках»), «скачанный», «последний», «его» и т.п.
enum FileCommandParser {
    static func parse(_ sentence: Sentence, rawText: String) -> Intent? {
        let words = sentence.words
        // Письма, календарь, напоминания, музыка и окна — не файлы.
        if words.contains(where: { word in FileLexicon.otherDomains.contains { word.hasPrefix($0) } }) { return nil }
        if sentence.contains(any: Lexicon.webMarkers) { return nil }

        guard let found = verb(in: sentence) else { return intentWithoutVerb(words) }
        let rest = Array(words[(found.index + 1)...])
        guard let result = intent(for: found.verb, rest: rest, sentence: sentence, rawText: rawText) else { return nil }
        // «Найди отчёт и открой его» — несколько действий одной командой пока не умею.
        if found.verb != .rename, let conjunction = rest.firstIndex(where: { Lexicon.conjunctions.contains($0) }),
           conjunction + 1 < rest.count {
            return .notYetSupported(.multiStep)
        }
        return result
    }

    // MARK: - Глаголы

    private enum Verb {
        case find
        case open
        case reveal
        case move
        case rename
        case trash
    }

    private static func verb(in sentence: Sentence) -> (verb: Verb, index: Int)? {
        let words = sentence.words
        let toTrash = sentence.contains(any: FileLexicon.toTrash)
        for (index, word) in words.enumerated() {
            if FileLexicon.trashVerbs.contains(word) { return (.trash, index) }
            if toTrash, FileLexicon.sendVerbs.contains(word) || FileLexicon.moveVerbs.contains(word) { return (.trash, index) }
            if FileLexicon.renameVerbs.contains(word) { return (.rename, index) }
            if FileLexicon.moveVerbs.contains(word) { return (.move, index) }
            if FileLexicon.revealVerbs.contains(word) { return (.reveal, index) }
            if FileLexicon.showVerbs.contains(word) { return (.reveal, index) }
            if FileLexicon.openVerbs.contains(word) { return (.open, index) }
            if FileLexicon.findVerbs.contains(word) { return (.find, index) }
        }
        return nil
    }

    private static func intent(for verb: Verb, rest: [String], sentence: Sentence, rawText: String) -> Intent? {
        switch verb {
        case .find:
            let target = describe(rest)
            guard target.isFileLike else { return nil }
            return .findFiles(target.query)

        case .open:
            // «Открой его в Finder» — это «покажи в Finder».
            if rest.contains(where: { word in FileLexicon.finder.contains { word.hasPrefix($0) } }) {
                return intent(for: .reveal, rest: rest, sentence: sentence, rawText: rawText)
            }
            if let location = wholeLocation(rest) { return .openFile(.location(location)) }
            let target = describe(rest)
            guard target.isFileLike, !target.isBareKind else { return nil }
            return .openFile(target.fileTarget(defaultToPrevious: false) ?? .query(target.query))

        case .reveal:
            let mentionsFinder = rest.contains { word in FileLexicon.finder.contains { word.hasPrefix($0) } }
            let words = rest.filter { word in !FileLexicon.finder.contains { word.hasPrefix($0) } }
            if let location = wholeLocation(trimmed(words)) { return .revealFile(.location(location)) }
            let target = describe(words)
            let explicitReveal = mentionsFinder || sentence.words.contains { FileLexicon.revealVerbs.contains($0) }
            if explicitReveal || target.reference != nil {
                guard let fileTarget = target.fileTarget(defaultToPrevious: true) else { return nil }
                return .revealFile(fileTarget)
            }
            // «Покажи последний скачанный PDF» — без Finder это просьба найти.
            guard target.isFileLike else { return nil }
            return .findFiles(target.query)

        case .move:
            let (fileWords, destination) = splitDestination(rest)
            guard let fileTarget = describe(fileWords).fileTarget(defaultToPrevious: true) else { return nil }
            return .moveFile(fileTarget, to: destination)

        case .rename:
            let (fileWords, newName) = splitNewName(rest, rawText: rawText)
            guard let fileTarget = describe(fileWords).fileTarget(defaultToPrevious: true) else { return nil }
            return .renameFile(fileTarget, to: newName)

        case .trash:
            let words = removingPhrases(FileLexicon.toTrash, from: rest)
            guard let fileTarget = describe(words).fileTarget(defaultToPrevious: true) else { return nil }
            return .trashFile(fileTarget)
        }
    }

    /// Без глагола: «последний скачанный PDF», «что я скачал последним», «второй».
    private static func intentWithoutVerb(_ words: [String]) -> Intent? {
        let target = describe(words)
        if case .previous(let index)? = target.reference, target.query == FileQuery(), !target.isBulk {
            // Только порядковое слово («второй», «второй файл») — выбор из списка.
            if words.contains(where: { ordinal($0) != nil }) { return .chooseItem(index) }
        }
        let downloaded = words.contains { word in FileLexicon.downloaded.contains { word.hasPrefix($0) } }
        if downloaded || (target.query.latest && (target.query.kind != nil || target.mentionsFile)) {
            return .findFiles(target.query)
        }
        return nil
    }

    // MARK: - Описание файла

    /// Что удалось понять о файле из слов команды.
    private struct Description {
        var query = FileQuery()
        var reference: FileTarget?
        var isBulk = false
        var mentionsFile = false
        /// Тип назван одним словом, и больше ничего («открой фото» — это приложение).
        var isBareKind = false

        var isFileLike: Bool {
            mentionsFile || reference != nil || query.kind != nil || query.location != nil
                || query.period != nil || query.latest
        }

        func fileTarget(defaultToPrevious: Bool) -> FileTarget? {
            if let reference { return reference }
            if isBulk { return .all(query) }
            if query.isSpecific || mentionsFile { return .query(query) }
            return defaultToPrevious ? .previous(0) : nil
        }
    }

    private static func describe(_ input: [String]) -> Description {
        var description = Description()
        var words = input

        // Папка: «в загрузках», «с рабочего стола», «из папки документы».
        if let found = locationPhrase(in: words) {
            description.query.location = found.location
            words.removeSubrange(found.range)
        }
        if words.contains(where: { word in FileLexicon.downloaded.contains { word.hasPrefix($0) } }) {
            description.query.location = description.query.location ?? .downloads
            words.removeAll { word in FileLexicon.downloaded.contains { word.hasPrefix($0) } }
        }
        // «Последний», «самый свежий».
        if words.contains(where: isLatestWord) {
            description.query.latest = true
            words.removeAll(where: isLatestWord)
        }
        // Период: «сегодня», «вчерашний», «за неделю», «за последние три дня».
        if let found = period(in: words) {
            description.query.period = found
            words.removeAll { word in
                FileLexicon.periodWords.contains { word.hasPrefix($0) } || FileLexicon.numberWords.contains(word)
                    || word.allSatisfy(\.isNumber)
            }
        }
        // «Все PDF», «all screenshots».
        if words.contains(where: { FileLexicon.all.contains($0) }) {
            description.isBulk = true
            words.removeAll { FileLexicon.all.contains($0) }
        }
        // «Снимки экрана» — два слова.
        if let range = phraseRange(of: FileLexicon.screenshotPhrases, in: words) {
            description.query.kind = .screenshot
            words.removeSubrange(range)
        }
        // Слово «файл» само по себе — только признак.
        if words.contains(where: isFileWord) {
            description.mentionsFile = true
            words.removeAll(where: isFileWord)
        }
        let contentBeforeKind = words.filter { !isFiller($0) }
        if description.query.kind == nil, let index = words.firstIndex(where: { kind(of: $0) != nil }) {
            description.query.kind = kind(of: words[index])
            words.remove(at: index)
            description.isBareKind = contentBeforeKind.count == 1 && !description.mentionsFile
                && description.query.location == nil && !description.query.latest && description.query.period == nil
                && description.query.kind != .pdf && description.query.kind != .folder
        }

        let content = words.filter { !isFiller($0) }
        if !content.isEmpty, content.allSatisfy({ FileLexicon.pronouns.contains($0) }) {
            let plural = content.contains { FileLexicon.pluralPronouns.contains($0) }
            description.reference = (plural || description.isBulk) ? FileTarget.previousAll : FileTarget.previous(0)
        } else if content.isEmpty, description.isBulk, !description.mentionsFile, !description.query.isSpecific {
            // «Удали все» сразу после поиска — все найденные файлы.
            description.reference = .previousAll
        } else if !content.isEmpty, content.allSatisfy({ ordinal($0) != nil || FileLexicon.choiceWords.contains($0) }),
                  let index = content.lazy.compactMap(ordinal).first {
            description.reference = .previous(index)
        } else {
            let name = trimmed(words.filter { !FileLexicon.innerFillers.contains($0) })
            if !name.isEmpty { description.query.name = name.joined(separator: " ") }
        }
        if description.reference != nil {
            description.isBareKind = false
        }
        return description
    }

    // MARK: - Куда и как назвать

    /// «…в документы», «…в папку работа», «…на рабочий стол», «…to the work folder».
    private static func splitDestination(_ words: [String]) -> ([String], FolderTarget?) {
        guard let index = words.lastIndex(where: { FileLexicon.destinationPrepositions.contains($0) }) else {
            return (words, nil)
        }
        let tail = Array(words[(index + 1)...])
        let head = Array(words[..<index])
        if let location = wholeLocation(trimmed(tail)) { return (head, .location(location)) }
        var name = tail.filter { word in !FileLexicon.folderWords.contains { word.hasPrefix($0) } }
        name = trimmed(name.filter { !FileLexicon.innerFillers.contains($0) })
        guard !name.isEmpty else { return (words, nil) }
        return (head, .named(name.joined(separator: " ")))
    }

    /// Новое имя берётся из исходного текста — с регистром букв, как распознано
    /// («переименуй его в Итоги марта» → «Итоги марта»).
    private static func splitNewName(_ words: [String], rawText: String) -> ([String], String?) {
        guard let index = words.lastIndex(where: { FileLexicon.renameSeparators.contains($0) }) else {
            return (words, nil)
        }
        let head = Array(words[..<index])
        let separator = words[index]
        guard let range = rawText.range(of: " \(separator) ", options: [.caseInsensitive, .backwards]) else {
            let tail = words[(index + 1)...].joined(separator: " ")
            return (head, tail.isEmpty ? nil : tail)
        }
        let quotes: Set<Character> = ["«", "»", "\"", "“", "”", "'", "„", ".", ",", "!", "?", ":", ";"]
        var name = rawText[range.upperBound...]
        while let first = name.first, first.isWhitespace || quotes.contains(first) { name.removeFirst() }
        while let last = name.last, last.isWhitespace || quotes.contains(last) { name.removeLast() }
        return (head, name.isEmpty ? nil : String(name))
    }

    // MARK: - Слова

    /// Папка, названная целиком: «загрузки», «папку документы», «рабочий стол».
    private static func wholeLocation(_ words: [String]) -> FileLocation? {
        let content = words.filter { !isFiller($0) }
        let withoutFolderWord = content.filter { word in !FileLexicon.folderWords.contains { word.hasPrefix($0) } }
        guard !content.isEmpty else { return nil }
        for (location, forms) in FileLexicon.locations {
            for form in forms where form == content || form == withoutFolderWord {
                return location
            }
        }
        return nil
    }

    /// Папка где-то в описании. Возвращает и диапазон слов, которые её называют
    /// (вместе с предлогом и словом «папка»).
    private static func locationPhrase(in words: [String]) -> (location: FileLocation, range: Range<Int>)? {
        for (location, forms) in FileLexicon.locations {
            for form in forms {
                guard let start = index(of: form, in: words) else { continue }
                var lower = start
                if lower > 0, FileLexicon.folderWords.contains(where: { words[lower - 1].hasPrefix($0) }) { lower -= 1 }
                if lower > 0, FileLexicon.locationPrepositions.contains(words[lower - 1]) { lower -= 1 }
                // «Документы», «изображения» без предлога и слова «папка» — это тип файла
                // («найди документы про отпуск»), а не папка.
                let ambiguous = (location == .documents || location == .pictures) && form.count == 1
                if ambiguous, lower == start { continue }
                return (location, lower..<(start + form.count))
            }
        }
        return nil
    }

    private static func period(in words: [String]) -> FilePeriod? {
        for word in words {
            if FileLexicon.today.contains(where: { word.hasPrefix($0) }) { return .today }
            if FileLexicon.yesterday.contains(where: { word.hasPrefix($0) }) { return .yesterday }
            if FileLexicon.week.contains(where: { word.hasPrefix($0) }) { return .week }
        }
        return nil
    }

    private static func kind(of word: String) -> FileKind? {
        for (kind, prefixes) in FileLexicon.kinds where prefixes.contains(where: { word.hasPrefix($0) }) {
            return kind
        }
        return nil
    }

    static func ordinal(_ word: String) -> Int? {
        FileLexicon.ordinals.firstIndex { $0.contains(word) }
    }

    private static func isLatestWord(_ word: String) -> Bool {
        FileLexicon.latestExact.contains(word) || FileLexicon.latestPrefixes.contains { word.hasPrefix($0) }
    }

    private static func isFileWord(_ word: String) -> Bool {
        FileLexicon.fileWords.contains { word.hasPrefix($0) }
    }

    private static func isFiller(_ word: String) -> Bool {
        Lexicon.fillers.contains(word) || FileLexicon.fillers.contains(word) || FileLexicon.innerFillers.contains(word)
    }

    /// Без служебных слов в начале и в конце.
    private static func trimmed(_ words: [String]) -> [String] {
        var result = words
        while let first = result.first, isFiller(first) { result.removeFirst() }
        while let last = result.last, isFiller(last) { result.removeLast() }
        return result
    }

    private static func index(of phrase: [String], in words: [String]) -> Int? {
        guard !phrase.isEmpty, words.count >= phrase.count else { return nil }
        return (0...(words.count - phrase.count)).first { Array(words[$0..<($0 + phrase.count)]) == phrase }
    }

    private static func phraseRange(of phrases: [[String]], in words: [String]) -> Range<Int>? {
        for phrase in phrases {
            if let start = index(of: phrase, in: words) { return start..<(start + phrase.count) }
        }
        return nil
    }

    private static func removingPhrases(_ phrases: [String], from words: [String]) -> [String] {
        var result = words
        for phrase in phrases.map(TextNormalizer.words) {
            while let start = index(of: phrase, in: result) {
                result.removeSubrange(start..<(start + phrase.count))
            }
        }
        return result
    }
}

/// Словарь файловых команд. Формы слов — уже нормализованные (нижний регистр, «е» вместо «ё»).
enum FileLexicon {
    static let otherDomains = [
        "почт", "письм", "писем", "календар", "встреч", "напомн", "напоминан", "музык", "песн", "трек", "плейлист",
        "окн", "mail", "email", "calendar", "meeting", "remind", "music", "song", "playlist", "window",
    ]

    static let findVerbs: Set<String> = [
        "найди", "найти", "поищи", "поискать", "ищи", "где", "find", "search", "locate", "where",
    ]
    static let openVerbs: Set<String> = ["открой", "открыть", "откройте", "open"]
    static let revealVerbs: Set<String> = ["reveal"]
    static let showVerbs: Set<String> = ["покажи", "показать", "покажите", "show"]
    static let moveVerbs: Set<String> = [
        "перемести", "переместить", "переместите", "перенеси", "перенести", "переложи", "переложить", "move",
    ]
    static let sendVerbs: Set<String> = ["отправь", "отправить", "убери", "кинь", "закинь", "выкинь", "send", "put"]
    static let renameVerbs: Set<String> = ["переименуй", "переименовать", "переименуйте", "rename"]
    static let trashVerbs: Set<String> = [
        "удали", "удалить", "удалите", "выбрось", "выкинь", "delete", "remove", "trash",
    ]
    static let toTrash = ["в корзину", "в корзине", "to the trash", "to trash", "in the trash", "into the trash", "to the bin"]

    static let finder = ["finder", "файндер", "финдер", "файнд"]

    static let fileWords = ["файл", "file"]
    static let folderWords = ["папк", "folder", "каталог", "директори"]

    static let downloaded = ["скачан", "скачал", "загружен", "download"]
    static let latestPrefixes = ["последн", "свеж", "новейш"]
    static let latestExact: Set<String> = ["latest", "last", "newest", "recent", "самый", "самую", "самое", "самые", "most"]

    static let today = ["сегодня", "сегодняшн", "today"]
    static let yesterday = ["вчера", "вчерашн", "yesterday"]
    static let week = ["недел", "week", "дня", "дней", "days"]
    /// Слова, которые убираются вместе с периодом: «за», «на этой», «последние три».
    static let periodWords = ["сегодня", "сегодняшн", "today", "вчера", "вчерашн", "yesterday", "недел", "week", "дня", "дней", "days"]
    static let numberWords: Set<String> = [
        "за", "эту", "этой", "этот", "this", "past", "два", "две", "три", "четыре", "пять", "шесть", "семь",
        "two", "three", "four", "five", "six", "seven",
    ]

    static let all: Set<String> = ["все", "всех", "всё", "all", "every", "each"]

    static let pronouns: Set<String> = [
        "его", "ее", "это", "этот", "эту", "эти", "их", "него", "нее", "них", "it", "that", "this", "them", "those", "these",
    ]
    static let pluralPronouns: Set<String> = ["эти", "их", "них", "them", "those", "these"]
    /// «Второй», «второй вариант», «второй из них», «the second one».
    static let choiceWords: Set<String> = ["вариант", "номер", "из", "них", "one", "of", "them"]
    static let ordinals: [Set<String>] = [
        ["первый", "первого", "первую", "первое", "первым", "первой", "первая", "first"],
        ["второй", "второго", "вторую", "второе", "вторым", "вторая", "second"],
        ["третий", "третьего", "третью", "третье", "третьим", "третья", "third"],
        ["четвертый", "четвертого", "четвертую", "четвертое", "четвертым", "четвертая", "fourth"],
        ["пятый", "пятого", "пятую", "пятое", "пятым", "пятая", "fifth"],
    ]

    static let screenshotPhrases: [[String]] = [
        ["снимок", "экрана"], ["снимки", "экрана"], ["снимков", "экрана"], ["снимка", "экрана"], ["screen", "shot"], ["screen", "shots"],
    ]
    static let kinds: [(FileKind, [String])] = [
        (.pdf, ["pdf", "пдф"]),
        (.screenshot, ["скриншот", "скрин", "screenshot"]),
        (.image, ["картинк", "изображен", "фото", "фотк", "фотограф", "image", "picture", "photo", "png", "jpg", "jpeg", "heic"]),
        (.video, ["видео", "ролик", "video", "movie", "mp4"]),
        (.audio, ["аудио", "audio", "mp3", "m4a", "wav"]),
        (.presentation, ["презентац", "presentation", "keynote", "pptx", "ppt"]),
        (.spreadsheet, ["таблиц", "spreadsheet", "excel", "xlsx", "xls", "csv"]),
        (.archive, ["архив", "zip", "rar", "archive"]),
        (.document, ["документ", "docx", "doc", "document", "текстов"]),
        (.folder, ["папк", "folder", "каталог", "директори"]),
    ]

    /// Формы названий стандартных папок (каждая — последовательность слов).
    static let locations: [(FileLocation, [[String]])] = [
        (.downloads, [["загрузки"], ["загрузках"], ["загрузок"], ["загрузку"], ["downloads"]]),
        (.desktop, [
            ["рабочий", "стол"], ["рабочем", "столе"], ["рабочего", "стола"], ["рабочему", "столу"], ["рабочий", "столе"],
            ["desktop"],
        ]),
        (.documents, [["документы"], ["документах"], ["документов"], ["documents"]]),
        (.pictures, [["изображения"], ["изображениях"], ["изображений"], ["pictures"]]),
        (.home, [
            ["домашняя", "папка"], ["домашней", "папке"], ["домашнюю", "папку"], ["домашней", "папки"], ["home", "folder"],
            ["home"],
        ]),
    ]
    static let locationPrepositions: Set<String> = ["в", "во", "из", "на", "с", "со", "in", "from", "on", "at"]
    static let destinationPrepositions: Set<String> = ["в", "во", "на", "to", "into"]
    static let renameSeparators: Set<String> = ["в", "на", "to", "as"]

    /// Служебные слова вокруг описания файла.
    static let fillers: Set<String> = [
        "мой", "мою", "мои", "мое", "моего", "моих", "my", "a", "an", "i", "я", "который", "которые", "которую", "которое",
        "что", "где", "лежит", "лежат", "is", "are", "файлик", "там", "тут", "здесь", "with", "from", "по", "in", "on", "at",
    ]
    /// Слова, которые не входят в название: «с названием», «под названием», «изменял».
    static let innerFillers: Set<String> = [
        "с", "со", "под", "названием", "называется", "именем", "named", "called", "изменял", "изменяла", "изменил",
        "изменила", "менял", "меняла", "редактировал", "редактировала", "сохранял", "сохранил", "сохранила", "открывал",
        "открывала", "создал", "создала", "modified", "changed", "edited", "saved", "created", "opened", "one",
    ]
}
