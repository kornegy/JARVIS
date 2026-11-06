import Foundation

/// Резервные копии файлов данных перед миграцией или при обнаружении повреждения.
///
/// Имена: `<name>.<label>.<unix-time>.json`, например `settings.v1.1730900000.json`.
/// Хранится не больше `keep` последних копий для каждого имени.
public struct FileBackups: Sendable {
    public let directory: URL
    public let keep: Int

    public init(directory: URL, keep: Int = 10) {
        self.directory = directory
        self.keep = max(1, keep)
    }

    /// Копирует файл в папку резервных копий и удаляет самые старые копии сверх лимита.
    @discardableResult
    public func backUp(_ file: URL, name: String, label: String, at date: Date) throws -> URL {
        try SecureFileIO.createPrivateDirectory(at: directory)
        let timestamp = Int(date.timeIntervalSince1970)
        var destination = directory.appending(path: "\(name).\(label).\(timestamp).json", directoryHint: .notDirectory)
        var attempt = 1
        while FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            attempt += 1
            destination = directory.appending(path: "\(name).\(label).\(timestamp)-\(attempt).json", directoryHint: .notDirectory)
        }
        let data = try Data(contentsOf: file)
        try SecureFileIO.writeAtomically(data, to: destination)
        try prune(name: name)
        return destination
    }

    /// Резервные копии для имени, от новых к старым (порядок — по времени в имени файла).
    public func backups(name: String) throws -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path(percentEncoded: false)) else { return [] }
        let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return files
            .filter { $0.lastPathComponent.hasPrefix(name + ".") && $0.pathExtension == "json" }
            .map { (url: $0, order: FileBackups.sortKey(of: $0)) }
            .sorted { lhs, rhs in
                if lhs.order.timestamp != rhs.order.timestamp { return lhs.order.timestamp > rhs.order.timestamp }
                return lhs.order.attempt > rhs.order.attempt
            }
            .map { $0.url }
    }

    /// Достаёт `<unix-time>[-<attempt>]` из `<name>.<label>.<unix-time>[-<attempt>].json`.
    static func sortKey(of url: URL) -> (timestamp: Int, attempt: Int) {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let last = stem.split(separator: ".").last else { return (0, 0) }
        let parts = last.split(separator: "-")
        let timestamp = parts.first.flatMap { Int($0) } ?? 0
        let attempt = parts.count > 1 ? (Int(parts[1]) ?? 0) : 1
        return (timestamp, attempt)
    }

    private func prune(name: String) throws {
        let all = try backups(name: name)
        for url in all.dropFirst(keep) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
