import Foundation
import JarvisAI
import Synchronization

/// Есть ли у JARVIS доступ к папке, которую защищает macOS («Файлы и папки»).
public enum FolderAccessState: Sendable, Equatable {
    /// JARVIS ещё не обращался к папке — macOS спросит при первом обращении.
    case unknown
    case granted
    case denied
}

/// Что JARVIS знает о доступе к «Рабочему столу», «Документам» и «Загрузкам».
///
/// У macOS нет способа узнать это заранее, не обратившись к папке (а обращение может
/// показать системный запрос). Поэтому состояние запоминается по ходу работы — когда JARVIS
/// сам ищет или перемещает файлы — и проверяется явно только по кнопке в настройках.
/// Хранится только в памяти.
public final class FolderAccessMonitor: Sendable {
    /// Папки, доступ к которым спрашивает macOS.
    public static let protectedLocations: [FileLocation] = [.desktop, .documents, .downloads]

    private let states = Mutex<[FileLocation: FolderAccessState]>([:])

    public init() {}

    public func state(for location: FileLocation) -> FolderAccessState {
        states.withLock { $0[location] ?? .unknown }
    }

    /// Запомнить результат обращения к папке (или к чему-то внутри неё).
    func record(_ url: URL, policy: PathPolicy, state: FolderAccessState) {
        guard let location = Self.location(of: url, policy: policy) else { return }
        states.withLock { $0[location] = state }
    }

    /// Проверить доступ: прочитать список файлов папки. macOS может показать запрос —
    /// поэтому вызывается только по явному действию пользователя (кнопка «Проверить»).
    public func probe(_ location: FileLocation, policy: PathPolicy = PathPolicy()) -> FolderAccessState {
        let url = policy.url(for: location.folderName)
        let state: FolderAccessState
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
            state = .granted
        } catch {
            state = DirectoryScanner.isPermissionError(error) ? .denied : .unknown
        }
        states.withLock { $0[location] = state }
        return state
    }

    /// Стандартная папка, внутри которой лежит путь.
    static func location(of url: URL, policy: PathPolicy) -> FileLocation? {
        let parts = PathPolicy.components(of: url.standardizedFileURL, under: policy.home)
            ?? PathPolicy.components(of: url.resolvingSymlinksInPath().standardizedFileURL, under: policy.home.resolvingSymlinksInPath().standardizedFileURL)
        guard let first = parts?.first?.lowercased() else { return nil }
        return FileLocation.allCases.first { $0.folderName?.lowercased() == first }
    }
}
