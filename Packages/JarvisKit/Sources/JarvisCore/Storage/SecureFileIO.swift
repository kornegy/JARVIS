import Foundation

/// Файловые операции с правами «только владелец» (папки 0700, файлы 0600).
public enum SecureFileIO {
    public static let privateDirectoryPermissions: Int = 0o700
    public static let privateFilePermissions: Int = 0o600

    public static func createPrivateDirectory(at url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: privateDirectoryPermissions]
        )
        // createDirectory не меняет права уже существующей папки — выставляем явно.
        try fileManager.setAttributes([.posixPermissions: privateDirectoryPermissions], ofItemAtPath: url.path(percentEncoded: false))
    }

    /// Атомарная запись: сначала во временный файл, затем переименование.
    /// Сбой посреди записи не оставит наполовину записанный файл.
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: privateFilePermissions], ofItemAtPath: url.path(percentEncoded: false))
    }

    /// Дописывает данные в конец файла (создаёт файл с правами 0600, если его нет).
    public static func append(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let path = url.path(percentEncoded: false)
        if !fileManager.fileExists(atPath: path) {
            guard fileManager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: privateFilePermissions]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    public static func posixPermissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }
}
