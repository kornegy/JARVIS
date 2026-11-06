import SwiftUI
import JarvisCore
import JarvisSettings

/// Окно настроек (⌘,). Здесь только настройки, которые уже на что-то влияют;
/// голос, AI и личность появятся вместе с соответствующими модулями.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            Tab("Основные", systemImage: "gearshape") {
                GeneralSettingsView(model: model)
            }
            Tab("Приватность", systemImage: "lock.shield") {
                PrivacySettingsView(model: model)
            }
            Tab("О программе", systemImage: "info.circle") {
                AboutView(model: model)
            }
        }
        .frame(width: 540, height: 460)
    }
}

private struct GeneralSettingsView: View {
    let model: AppModel
    @State private var nameDraft = ""

    var body: some View {
        Form {
            Section("Ассистент") {
                TextField("Имя", text: $nameDraft)
                    .onSubmit { commitName() }
                Text("Имя используется в интерфейсе и ответах. Фраза-активатор настраивается отдельно (появится вместе с голосом).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Запуск") {
                Toggle(
                    "Запускать JARVIS при входе в систему",
                    isOn: Binding(get: { model.loginItem.isEnabled }, set: { model.loginItem.setEnabled($0) })
                )
                .disabled(!model.loginItem.isManaged)
                if model.loginItem.requiresApproval {
                    HStack {
                        Text("Нужно разрешить в «Системные настройки → Основные → Объекты входа».")
                            .font(.caption)
                        Button("Открыть") { model.loginItem.openSystemSettings() }
                    }
                }
                if let message = model.loginItem.lastErrorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                }
                Toggle("Показывать окно JARVIS при запуске", isOn: model.binding(\.general.showMainWindowAtLaunch))
            }
        }
        .formStyle(.grouped)
        .onAppear { nameDraft = model.settings.general.assistantName }
        .onDisappear { commitName() }
    }

    private func commitName() {
        model.update { $0.general.assistantName = nameDraft }
        nameDraft = model.settings.general.assistantName
    }
}

private struct PrivacySettingsView: View {
    let model: AppModel
    @State private var isConfirmingClear = false

    var body: some View {
        Form {
            Section("Режим приватности") {
                Toggle("Privacy Mode", isOn: model.binding(\.privacy.privacyMode))
                Text("Запрещает любую сетевую обработку голоса и AI, даже если облачный провайдер настроен. Работают только локальные функции.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Журнал действий") {
                Picker("Подробность", selection: model.binding(\.privacy.auditDetail)) {
                    ForEach(AuditDetailLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                Stepper(value: model.binding(\.privacy.auditRetentionDays), in: 1...365) {
                    Text("Хранить записи: \(model.settings.privacy.auditRetentionDays) дн.")
                }
                Text("В журнал никогда не записываются текст команд, аудио, ответы AI, пароли и содержимое файлов.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Очистить журнал…", role: .destructive) {
                    isConfirmingClear = true
                }
            }
            Section("Данные") {
                LabeledContent("Папка данных") {
                    Text(model.directories.root.path(percentEncoded: false))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Button("Показать в Finder") { model.revealDataFolder() }
                Text("Голос и расшифровки команд не сохраняются нигде — ни в этой папке, ни в системных логах.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Очистить журнал действий?", isPresented: $isConfirmingClear) {
            Button("Очистить", role: .destructive) {
                Task { await model.clearActivity() }
            }
        } message: {
            Text("Все записи будут удалены с диска без возможности восстановления.")
        }
    }
}

private struct AboutView: View {
    let model: AppModel
    private static let repositoryURL = URL(string: "https://github.com/kornegy/JARVIS")

    var body: some View {
        Form {
            Section {
                LabeledContent("Версия", value: Bundle.main.versionDescription)
                LabeledContent("Этап разработки", value: "Phase 1 — фундамент проекта")
            }
            Section("Что уже работает") {
                Text("Строка меню и окно статуса, включение/выключение, пауза микрофона, Privacy Mode, настройки с резервными копиями, журнал действий без текста команд, автозапуск.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Что дальше") {
                Text("Phase 2 — голос: «Привет, Джарвис», Push-to-Talk, локальное распознавание речи и ответы голосом.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let url = AboutView.repositoryURL {
                Link("Исходный код и документация", destination: url)
            }
        }
        .formStyle(.grouped)
    }
}
