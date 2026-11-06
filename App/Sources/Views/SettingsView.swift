import SwiftUI
import JarvisAssistant
import JarvisCore
import JarvisSettings
import JarvisVoice

/// Окно настроек (⌘,). Здесь только настройки, которые уже на что-то влияют;
/// AI-провайдеры и память появятся вместе с соответствующими модулями.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            Tab("Основные", systemImage: "gearshape") {
                GeneralSettingsView(model: model)
            }
            Tab("Голос", systemImage: "waveform") {
                VoiceSettingsView(model: model)
            }
            Tab("Личность", systemImage: "face.smiling") {
                PersonalitySettingsView(model: model)
            }
            Tab("Приватность", systemImage: "lock.shield") {
                PrivacySettingsView(model: model)
            }
            Tab("О программе", systemImage: "info.circle") {
                AboutView(model: model)
            }
        }
        .frame(width: 560, height: 560)
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
                Text("Имя используется в интерфейсе. Фразы-активаторы — на вкладке «Голос».")
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

private struct VoiceSettingsView: View {
    let model: AppModel
    @State private var phrasesDraft = ""
    @State private var devices: [AudioInputDevice] = []
    @State private var voices: [VoiceOption] = []
    @State private var modelStatus: SpeechModelStatus?

    var body: some View {
        Form {
            Section("Как обращаться к JARVIS") {
                Picker("Режим", selection: model.binding(\.voice.listeningMode)) {
                    Text("Push-to-Talk — по клавише").tag(ListeningMode.pushToTalk)
                    Text("Фраза-активатор — «Привет, Джарвис»").tag(ListeningMode.wakeWord)
                }
                if model.settings.voice.listeningMode == .wakeWord {
                    Text("Микрофон включён постоянно — macOS покажет оранжевую точку. Звук не записывается и не покидает Mac; распознанный текст без фразы-активатора сразу забывается.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("Фразы-активаторы (через запятую)", text: $phrasesDraft)
                    .onSubmit { commitPhrases() }
                Picker("Клавиша Push-to-Talk", selection: model.binding(\.voice.pushToTalkShortcut)) {
                    ForEach(PushToTalkShortcut.allCases, id: \.self) { shortcut in
                        Text(shortcut.displayName).tag(shortcut)
                    }
                }
                if let hotKeyProblem = model.hotKeyProblem {
                    Text(hotKeyProblem)
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                }
            }
            Section("Распознавание речи (на этом Mac)") {
                Picker("Язык", selection: model.binding(\.voice.recognitionLocale)) {
                    Text("Русский").tag("ru_RU")
                    Text("English").tag("en_US")
                }
                LabeledContent("Модель языка") {
                    HStack {
                        Text(Self.statusText(modelStatus))
                            .foregroundStyle(.secondary)
                        if modelStatus == .needsDownload {
                            Button(model.assistant.isDownloadingModel ? "Скачивается…" : "Скачать") {
                                Task {
                                    await model.downloadSpeechModel()
                                    modelStatus = await model.speechModelStatus()
                                }
                            }
                            .disabled(model.assistant.isDownloadingModel)
                        }
                    }
                }
                Picker("Микрофон", selection: model.binding(\.voice.inputDeviceUID)) {
                    Text("Системный по умолчанию").tag(String?.none)
                    ForEach(devices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                CommittingSlider(title: "Чувствительность", model: model, keyPath: \.voice.microphoneSensitivity, range: 0...1) {
                    "\(Int(($0 * 100).rounded())) %"
                }
                CommittingSlider(title: "Пауза конца фразы", model: model, keyPath: \.voice.endOfSpeechSilenceSeconds, range: 0.5...3) {
                    String(format: "%.1f с", $0)
                }
            }
            Section("Ответы голосом") {
                Toggle("Отвечать голосом", isOn: model.binding(\.voice.speakResponses))
                Toggle("Звуковые сигналы", isOn: model.binding(\.voice.playSounds))
                Picker("Голос", selection: model.binding(\.voice.voiceIdentifier)) {
                    Text("Системный для языка").tag(String?.none)
                    ForEach(voices) { voice in
                        Text(voice.name).tag(String?.some(voice.id))
                    }
                }
                CommittingSlider(title: "Скорость", model: model, keyPath: \.voice.speechRate, range: 0...1) {
                    "\(Int(($0 * 100).rounded())) %"
                }
                CommittingSlider(title: "Громкость", model: model, keyPath: \.voice.speechVolume, range: 0...1) {
                    "\(Int(($0 * 100).rounded())) %"
                }
                Button("Проверить голос") { model.previewVoice() }
                Text("Больше голосов (в том числе улучшенные): «Системные настройки → Универсальный доступ → Устная речь».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            devices = AudioInputDevices.all()
            voices = SystemSpeechSynthesizer.voices(for: model.settings.voice.locale)
            phrasesDraft = model.settings.voice.wakePhrases.joined(separator: ", ")
        }
        .onChange(of: model.settings.voice.recognitionLocale) {
            voices = SystemSpeechSynthesizer.voices(for: model.settings.voice.locale)
        }
        .task(id: model.settings.voice.recognitionLocale) {
            modelStatus = await model.speechModelStatus()
        }
        .onDisappear { commitPhrases() }
    }

    private func commitPhrases() {
        let phrases = phrasesDraft
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        model.update { $0.voice.wakePhrases = phrases }
        phrasesDraft = model.settings.voice.wakePhrases.joined(separator: ", ")
    }

    private static func statusText(_ status: SpeechModelStatus?) -> String {
        switch status {
        case .installed?: "установлена"
        case .needsDownload?: "нужно скачать (один раз, у Apple)"
        case .downloading?: "скачивается…"
        case .unsupportedLanguage?: "язык не поддерживается на устройстве"
        case nil: "проверяю…"
        }
    }
}

private struct PersonalitySettingsView: View {
    let model: AppModel
    @State private var sample = ""

    var body: some View {
        Form {
            Section("Характер") {
                CommittingSlider(title: "Юмор", model: model, keyPath: \.personality.humor, range: 0...1) {
                    "\(Int(($0 * 100).rounded())) %"
                }
                CommittingSlider(title: "Разговорчивость", model: model, keyPath: \.personality.verbosity, range: 0...1) {
                    "\(Int(($0 * 100).rounded())) %"
                }
                CommittingSlider(title: "Официальность", model: model, keyPath: \.personality.formality, range: 0...1) {
                    "\(Int(($0 * 100).rounded())) %"
                }
                Text("Мало юмора — без шуток; мало разговорчивости — коротко; высокая официальность — на «вы».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Пример ответа на «Привет»") {
                Text(sample)
                Button("Ещё пример") { sample = model.sampleReply() }
            }
        }
        .formStyle(.grouped)
        .onAppear { sample = model.sampleReply() }
        .onChange(of: model.settings.personality) { sample = model.sampleReply() }
    }
}

/// Слайдер, который сохраняет значение, когда его отпустили (а не на каждом сдвиге).
private struct CommittingSlider: View {
    let title: String
    let model: AppModel
    let keyPath: WritableKeyPath<JarvisSettings, Double>
    let range: ClosedRange<Double>
    let format: (Double) -> String
    @State private var value = 0.0
    @State private var isEditing = false

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, onEditingChanged: { editing in
                    isEditing = editing
                    if !editing { commit() }
                })
                Text(format(value))
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
            }
        }
        .onAppear { value = model.settings[keyPath: keyPath] }
        .onChange(of: value) {
            if !isEditing { commit() }
        }
        .onChange(of: model.settings[keyPath: keyPath]) { _, newValue in
            if !isEditing { value = newValue }
        }
    }

    private func commit() {
        guard model.settings[keyPath: keyPath] != value else { return }
        model.update { $0[keyPath: keyPath] = value }
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
                LabeledContent("Этап разработки", value: "Phase 2 — голос")
            }
            Section("Что уже работает") {
                Text("«Привет, Джарвис» и Push-to-Talk, распознавание речи на этом Mac, ответы голосом с характером, текстовые команды, время и дата, пауза микрофона, Privacy Mode, журнал действий без текста команд.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Что дальше") {
                Text("Phase 3 — управление Mac: приложения, файлы, системные настройки, подтверждение опасных действий.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let url = AboutView.repositoryURL {
                Link("Исходный код и документация", destination: url)
            }
        }
        .formStyle(.grouped)
    }
}
