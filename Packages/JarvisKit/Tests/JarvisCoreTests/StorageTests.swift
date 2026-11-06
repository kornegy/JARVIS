import Foundation
import Testing
@testable import JarvisCore

@Suite("Хранилище файлов")
struct StorageTests {
    @Test("Папки данных создаются с правами 0700")
    func directoriesArePrivate() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let directories = AppDirectories(root: temp.url.appending(path: "JARVIS", directoryHint: .isDirectory))

        try directories.prepare()

        for url in [directories.root, directories.auditDirectory, directories.backupsDirectory] {
            #expect(try SecureFileIO.posixPermissions(of: url) == 0o700)
        }
        #expect(directories.settingsFile.lastPathComponent == "settings.json")
    }

    @Test("Атомарная запись создаёт файл с правами 0600")
    func atomicWrite() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let file = temp.url.appending(path: "data.json")

        try SecureFileIO.writeAtomically(Data("{}".utf8), to: file)
        try SecureFileIO.writeAtomically(Data("{\"a\":1}".utf8), to: file)

        #expect(try String(contentsOf: file, encoding: .utf8) == "{\"a\":1}")
        #expect(try SecureFileIO.posixPermissions(of: file) == 0o600)
    }

    @Test("Резервные копии: новые первыми, старые сверх лимита удаляются")
    func backupsArePruned() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let source = temp.url.appending(path: "settings.json")
        try SecureFileIO.writeAtomically(Data("{}".utf8), to: source)
        let backups = FileBackups(directory: temp.url.appending(path: "backups", directoryHint: .isDirectory), keep: 3)

        for day in 0..<5 {
            try backups.backUp(source, name: "settings", label: "v1", at: fixedDate(daysFromBase: day))
        }

        let names = try backups.backups(name: "settings").map(\.lastPathComponent)
        #expect(names.count == 3)
        #expect(names.first == "settings.v1.\(Int(fixedDate(daysFromBase: 4).timeIntervalSince1970)).json")
    }

    @Test("Две копии в одну секунду не перезаписывают друг друга")
    func backupsWithSameTimestamp() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let source = temp.url.appending(path: "settings.json")
        try SecureFileIO.writeAtomically(Data("{}".utf8), to: source)
        let backups = FileBackups(directory: temp.url.appending(path: "backups", directoryHint: .isDirectory))

        let first = try backups.backUp(source, name: "settings", label: "corrupt", at: fixedDate())
        let second = try backups.backUp(source, name: "settings", label: "corrupt", at: fixedDate())

        #expect(first.lastPathComponent != second.lastPathComponent)
        // Сравниваем имена, а не URL: каталог может вернуться как /private/var/… вместо /var/….
        let newest = try backups.backups(name: "settings").first?.lastPathComponent
        #expect(newest == second.lastPathComponent)
    }
}
