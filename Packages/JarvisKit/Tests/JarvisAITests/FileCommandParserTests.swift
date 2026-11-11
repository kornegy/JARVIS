import Testing
@testable import JarvisAI

@Suite("Разбор файловых команд")
struct FileCommandParserTests {
    private let parser = RuleIntentParser()

    @Test("Поиск файлов", arguments: [
        ("Найди последний PDF, который я скачал", FileQuery(kind: .pdf, location: .downloads, latest: true)),
        ("найди файл с названием диплом", FileQuery(name: "диплом")),
        ("найди презентацию про отпуск", FileQuery(name: "отпуск", kind: .presentation)),
        ("где лежит файл отчёт", FileQuery(name: "отчет")),
        ("найди скриншоты на рабочем столе", FileQuery(kind: .screenshot, location: .desktop)),
        ("покажи файлы за сегодня", FileQuery(period: .today)),
        ("что я скачал последним", FileQuery(location: .downloads, latest: true)),
        ("find the latest pdf I downloaded", FileQuery(kind: .pdf, location: .downloads, latest: true)),
        ("Найди все файлы, которые я изменял за последние три дня", FileQuery(period: .week, latest: true)),
        ("найди документы про отпуск", FileQuery(name: "отпуск", kind: .document)),
        ("найди картинки в загрузках", FileQuery(kind: .image, location: .downloads)),
        ("найди папку работа", FileQuery(name: "работа", kind: .folder)),
        ("последний скачанный pdf", FileQuery(kind: .pdf, location: .downloads, latest: true)),
    ])
    func find(text: String, query: FileQuery) {
        #expect(parser.parse(text) == .findFiles(query))
    }

    @Test("Без признаков файла «найди» — это поиск в интернете")
    func webStaysWeb() {
        #expect(parser.parse("найди рецепт блинов") == .webSearch("рецепт блинов"))
        #expect(parser.parse("найди в интернете pdf редактор") == .webSearch("pdf редактор"))
        #expect(parser.parse("найди") == .findFiles(FileQuery()))
    }

    @Test("Открыть: «его», «второй», папки, описание")
    func open() {
        #expect(parser.parse("открой его") == .openFile(.previous(0)))
        #expect(parser.parse("открой второй") == .openFile(.previous(1)))
        #expect(parser.parse("open the second one") == .openFile(.previous(1)))
        #expect(parser.parse("открой загрузки") == .openFile(.location(.downloads)))
        #expect(parser.parse("открой папку документы") == .openFile(.location(.documents)))
        #expect(parser.parse("открой рабочий стол") == .openFile(.location(.desktop)))
        #expect(parser.parse("открой последний скачанный pdf") == .openFile(.query(FileQuery(kind: .pdf, location: .downloads, latest: true))))
        #expect(parser.parse("открой файл отчёт") == .openFile(.query(FileQuery(name: "отчет"))))
        #expect(parser.parse("открой папку проекты") == .openFile(.query(FileQuery(name: "проекты", kind: .folder))))
    }

    @Test("Приложения с «файловыми» названиями остаются приложениями")
    func appsStayApps() {
        #expect(parser.parse("открой фото") == .openApp("фото"))
        #expect(parser.parse("открой Safari") == .openApp("safari"))
        #expect(parser.parse("открой excel") == .openApp("excel"))
        #expect(parser.parse("открой, пожалуйста, приложение заметки") == .openApp("заметки"))
    }

    @Test("Показать в Finder")
    func reveal() {
        #expect(parser.parse("покажи его в Finder") == .revealFile(.previous(0)))
        #expect(parser.parse("show it in finder") == .revealFile(.previous(0)))
        #expect(parser.parse("открой его в файндере") == .revealFile(.previous(0)))
        #expect(parser.parse("покажи в файндере последний скачанный файл") == .revealFile(.query(FileQuery(location: .downloads, latest: true))))
        #expect(parser.parse("reveal the latest download") == .revealFile(.query(FileQuery(location: .downloads, latest: true))))
    }

    @Test("Переместить: куда — стандартная папка или папка по названию")
    func move() {
        #expect(parser.parse("перемести его в документы") == .moveFile(.previous(0), .location(.documents)))
        #expect(parser.parse("перемести его на рабочий стол") == .moveFile(.previous(0), .location(.desktop)))
        #expect(parser.parse("move it to documents") == .moveFile(.previous(0), .location(.documents)))
        #expect(
            parser.parse("перемести последний скачанный pdf в папку работа")
                == .moveFile(.query(FileQuery(kind: .pdf, location: .downloads, latest: true)), .named("работа"))
        )
        #expect(
            parser.parse("перемести все pdf из загрузок в документы")
                == .moveFile(.all(FileQuery(kind: .pdf, location: .downloads)), .location(.documents))
        )
        #expect(parser.parse("move the report to the work folder") == .moveFile(.query(FileQuery(name: "report")), .named("work")))
        #expect(parser.parse("move them to the desktop") == .moveFile(.previousAll, .location(.desktop)))
        #expect(parser.parse("перемести файл отчёт") == .moveFile(.query(FileQuery(name: "отчет")), nil))
    }

    @Test("Переименовать: новое имя — с регистром букв, как сказано")
    func rename() {
        #expect(parser.parse("переименуй его в Итоги марта") == .renameFile(.previous(0), "Итоги марта"))
        #expect(parser.parse("переименуй его в «Итоги марта».") == .renameFile(.previous(0), "Итоги марта"))
        #expect(parser.parse("rename it to Summary") == .renameFile(.previous(0), "Summary"))
        #expect(
            parser.parse("переименуй последний скачанный pdf в Счёт")
                == .renameFile(.query(FileQuery(kind: .pdf, location: .downloads, latest: true)), "Счёт")
        )
        #expect(parser.parse("переименуй файл отчёт") == .renameFile(.query(FileQuery(name: "отчет")), nil))
    }

    @Test("Удалить — в Корзину")
    func trash() {
        #expect(parser.parse("удали его") == .trashFile(.previous(0)))
        #expect(parser.parse("delete it") == .trashFile(.previous(0)))
        #expect(parser.parse("отправь его в корзину") == .trashFile(.previous(0)))
        #expect(parser.parse("удали их") == .trashFile(.previousAll))
        #expect(parser.parse("удали все скриншоты с рабочего стола") == .trashFile(.all(FileQuery(kind: .screenshot, location: .desktop))))
        #expect(parser.parse("удали последний скриншот") == .trashFile(.query(FileQuery(kind: .screenshot, latest: true))))
    }

    @Test("Выбор из списка и отмена")
    func chooseAndUndo() {
        #expect(parser.parse("второй") == .chooseItem(1))
        #expect(parser.parse("второй файл") == .chooseItem(1))
        #expect(parser.parse("отмени") == .undo)
        #expect(parser.parse("верни как было") == .undo)
        #expect(parser.parse("отмени последнее действие") == .undo)
        #expect(parser.parse("undo") == .undo)
        // «Отмена» и «стоп» — это «ничего не делай», а не отмена сделанного.
        #expect(parser.parse("отмена") == .cancel)
        #expect(parser.parse("стоп") == .cancel)
    }

    @Test("Чужие области: почта, окна, несколько действий")
    func otherDomains() {
        #expect(parser.parse("найди письмо от Пети") == .notYetSupported(.mail))
        #expect(parser.parse("перемести окно влево") == .notYetSupported(.windows))
        #expect(parser.parse("закрой папку загрузки") == .notYetSupported(.windows))
        #expect(parser.parse("найди файл отчёт и открой его") == .notYetSupported(.multiStep))
        #expect(parser.parse("Создай папку для нового проекта") == .notYetSupported(.files))
    }
}

@Suite("Имена файлов и запросы")
struct FileQueryTests {
    @Test("Имя файла находится в разных падежах, с «ё» и латиницей")
    func nameMatching() {
        #expect(FileNameMatcher.score(fileName: "Отчёт за март.docx", query: "отчет за март") > 0)
        #expect(FileNameMatcher.score(fileName: "Диплом.docx", query: "диплома") > 0)
        #expect(FileNameMatcher.score(fileName: "otchet_mart.pdf", query: "отчёт") > 0)
        #expect(FileNameMatcher.score(fileName: "Фото кота.png", query: "отчет") == 0)
        #expect(FileNameMatcher.score(fileName: "любой.pdf", query: "") == 1)
    }

    @Test("Точное имя важнее начала, начало — важнее совпадения в середине")
    func ranking() {
        let exact = FileNameMatcher.score(fileName: "Отчет.pdf", query: "отчет")
        let prefix = FileNameMatcher.score(fileName: "Отчет за март.pdf", query: "отчет")
        let inside = FileNameMatcher.score(fileName: "Мой отчет.pdf", query: "отчет")
        #expect(exact > prefix)
        #expect(prefix > inside)
        #expect(inside > 0)
    }

    @Test("Слова для Spotlight: основа и латинская форма, служебные слова отброшены")
    func searchForms() {
        #expect(FileNameMatcher.searchForms("отчёта за март") == [["отче", "otche"], ["март", "mart"]])
        #expect(FileNameMatcher.searchForms("report") == [["repo"]])
    }

    @Test("Формы слова «файл»")
    func plural() {
        #expect(RussianPlural.files(1) == "1 файл")
        #expect(RussianPlural.files(3) == "3 файла")
        #expect(RussianPlural.files(5) == "5 файлов")
        #expect(RussianPlural.files(11) == "11 файлов")
        #expect(RussianPlural.files(21) == "21 файл")
        #expect(RussianPlural.files(112) == "112 файлов")
    }

    @Test("Пути стандартных папок")
    func locations() {
        #expect(FileLocation.downloads.path(inHome: "/Users/test") == "/Users/test/Downloads")
        #expect(FileLocation.desktop.path(inHome: "/Users/test/") == "/Users/test/Desktop")
        #expect(FileLocation.home.path(inHome: "/Users/test") == "/Users/test")
    }

    @Test("«Найди файл» без подробностей — искать нечего")
    func specific() {
        #expect(!FileQuery().isSpecific)
        #expect(FileQuery(kind: .pdf).isSpecific)
        #expect(FileQuery(latest: true).isSpecific)
    }
}
