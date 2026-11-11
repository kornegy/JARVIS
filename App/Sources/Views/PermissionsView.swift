import AppKit
import SwiftUI
import JarvisAI
import JarvisMac
import JarvisTools

/// Вкладка «Разрешения»: что JARVIS может делать, зачем ему каждое разрешение и что будет без
/// него. Разрешения запрашиваются по кнопке, без кнопки — только когда понадобятся.
struct PermissionsView: View {
    let manager: PermissionManager

    var body: some View {
        // Чтение `revision` подписывает вид на обновления статусов.
        let _ = manager.revision
        Form {
            Section {
                PermissionRowView(
                    title: "Микрофон",
                    icon: "mic",
                    purpose: "Слушать «Привет, Джарвис» и команды. Звук обрабатывается только на этом Mac и не сохраняется.",
                    withoutIt: "Без него — только текстовые команды.",
                    status: manager.status(for: .microphone),
                    action: { Task { await manager.request(.microphone) } }
                )
                PermissionRowView(
                    title: "Распознавание речи",
                    icon: "waveform",
                    purpose: "Нужно, только если macOS требует его для распознавания речи на этом Mac.",
                    withoutIt: "Без него, если macOS его требует, — только текстовые команды.",
                    status: manager.status(for: .speechRecognition),
                    action: { Task { await manager.request(.speechRecognition) } }
                )
            } header: {
                Text("Голос")
            }

            Section {
                ForEach(FolderAccessMonitor.protectedLocations, id: \.self) { location in
                    FolderRowView(
                        name: Self.folderName(location),
                        state: manager.folderStatus(location),
                        check: { Task { await manager.checkFolder(location) } },
                        openSettings: { manager.openSystemSettings(for: .filesAndFolders) }
                    )
                }
                Text("Чтобы находить и перемещать файлы в этих папках. macOS спрашивает о каждой папке при первом обращении. Остальная домашняя папка доступна без запроса; «Библиотеки», скрытые папки и системные файлы JARVIS не трогает никогда.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Файлы и папки")
            }

            Section {
                PermissionRowView(
                    title: "Автоматизация",
                    icon: "gearshape.2",
                    purpose: "Закрывать приложения по команде «закрой …». macOS спрашивает отдельно для каждого приложения — при первом закрытии.",
                    withoutIt: "Без него JARVIS не сможет закрыть это приложение.",
                    status: manager.status(for: .appleEvents),
                    unknownText: "Спрашивается для каждого приложения",
                    actionTitle: "Открыть настройки",
                    action: { manager.openSystemSettings(for: .appleEvents) }
                )
                PermissionRowView(
                    title: "Универсальный доступ",
                    icon: "accessibility",
                    purpose: "Понадобится для управления окнами в следующей версии. Сейчас JARVIS его не просит.",
                    withoutIt: "Сейчас ни на что не влияет.",
                    status: manager.status(for: .accessibility),
                    notDeterminedText: "Пока не нужно",
                    actionTitle: "Открыть настройки",
                    action: { manager.openSystemSettings(for: .accessibility) }
                )
            } header: {
                Text("Управление Mac")
            }

            Section {
                Text("JARVIS никогда не просит «Полный доступ к диску» и «Запись экрана» и не обходит отказы macOS: если доступа нет, он скажет, где его дать, и остановится.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { manager.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            manager.refresh()
        }
    }

    static func folderName(_ location: FileLocation) -> String {
        switch location {
        case .desktop: "Рабочий стол"
        case .documents: "Документы"
        case .downloads: "Загрузки"
        case .pictures: "Изображения"
        case .home: "Домашняя папка"
        }
    }
}

/// Строка разрешения: название, зачем, статус и кнопка.
private struct PermissionRowView: View {
    let title: String
    let icon: String
    let purpose: String
    let withoutIt: String
    let status: PermissionStatus
    var unknownText = "Спросит при первой необходимости"
    var notDeterminedText = "Ещё не спрашивали"
    var actionTitle: String?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: icon)
                    .font(.headline)
                Spacer()
                StatusBadge(text: statusText, color: statusColor)
                if let buttonTitle {
                    Button(buttonTitle, action: action)
                        .accessibilityIdentifier("permissions.\(title)")
                }
            }
            Text(purpose)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Text(withoutIt)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        switch status {
        case .granted: "Разрешено"
        case .denied: "Запрещено"
        case .notDetermined: notDeterminedText
        case .unknown: unknownText
        }
    }

    private var statusColor: Color {
        switch status {
        case .granted: .green
        case .denied: .red
        case .notDetermined, .unknown: .secondary
        }
    }

    private var buttonTitle: String? {
        if let actionTitle { return actionTitle }
        switch status {
        case .granted: return nil
        case .notDetermined: return "Разрешить"
        case .denied, .unknown: return "Открыть настройки"
        }
    }
}

/// Строка папки: «Документы — разрешено / запрещено / спросит при первом обращении».
private struct FolderRowView: View {
    let name: String
    let state: FolderAccessState
    let check: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack {
            Label(name, systemImage: "folder")
            Spacer()
            switch state {
            case .granted:
                StatusBadge(text: "Разрешено", color: .green)
            case .denied:
                StatusBadge(text: "Запрещено", color: .red)
                Button("Открыть настройки", action: openSettings)
            case .unknown:
                StatusBadge(text: "Спросит при первом обращении", color: .secondary)
                Button("Проверить", action: check)
                    .help("JARVIS прочитает список файлов папки. Если macOS ещё не спрашивала, она покажет запрос.")
            }
        }
    }
}

private struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
    }
}
