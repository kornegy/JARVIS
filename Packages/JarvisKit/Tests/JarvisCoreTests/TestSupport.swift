import Foundation

/// Временная папка для теста; удаляется вызовом `remove()`.
struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "JarvisCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Фиксированная дата: 2026-11-06 12:00:00 UTC плюс `days` суток.
func fixedDate(daysFromBase days: Int = 0, seconds: Int = 0) -> Date {
    Date(timeIntervalSince1970: 1_793_966_400 + TimeInterval(days * 86_400 + seconds))
}
