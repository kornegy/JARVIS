import AppKit
import SwiftUI
import JarvisAssistant
import JarvisCore

/// Иконка и название текущего состояния + имя ассистента.
struct StatusHeader: View {
    let model: AppModel

    var body: some View {
        let presentation = model.state.presentation
        HStack(spacing: 12) {
            Image(systemName: presentation.symbolName)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(presentation.tone.color)
                // Без бесконечной анимации: она перерисовывает окно каждый кадр, пока JARVIS слушает.
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.settings.general.assistantName)
                    .font(.headline)
                Text(presentation.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("status.title")
            }
            Spacer()
            if model.settings.privacy.privacyMode {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(Color.green)
                    .help("Privacy Mode: сетевая обработка голоса и AI запрещена")
                    .accessibilityLabel(Text("Privacy Mode включён"))
            }
        }
    }
}

/// Честный индикатор микрофона: показывает, идёт ли захват звука на самом деле,
/// и уровень сигнала — видно, слышит ли JARVIS микрофон вообще.
struct MicrophoneIndicator: View {
    let isCapturing: Bool
    var level: Float?

    var body: some View {
        let title = isCapturing ? "Микрофон слушает — звук не сохраняется" : "Микрофон не используется"
        HStack(spacing: 8) {
            Label(title, systemImage: isCapturing ? "mic.fill" : "mic.slash")
                .font(.callout)
                .foregroundStyle(isCapturing ? Color.orange : Color.secondary)
                .accessibilityIdentifier("microphone.indicator")
            if isCapturing, let level {
                ProgressView(value: Self.meterValue(level))
                    .progressViewStyle(.linear)
                    .frame(width: 60)
                    .help("Уровень сигнала микрофона")
                    .accessibilityLabel(Text("Уровень микрофона"))
            }
        }
    }

    /// −60 dBFS и тише → 0, 0 dBFS → 1.
    static func meterValue(_ decibels: Float) -> Double {
        Double(min(max((decibels + 60) / 60, 0), 1))
    }
}

/// Кнопка включения/выключения ассистента.
struct PowerButton: View {
    let model: AppModel

    var body: some View {
        let title = model.isEnabled ? "Выключить" : "Включить"
        Button {
            model.setEnabled(!model.isEnabled)
        } label: {
            Label(title, systemImage: "power")
        }
        .keyboardShortcut("e", modifiers: [.command])
        .accessibilityIdentifier("assistant.power")
        .help(model.isEnabled ? "Выключить JARVIS (⌘E)" : "Включить JARVIS (⌘E)")
    }
}

/// Кнопка паузы микрофона.
struct MicrophonePauseButton: View {
    let model: AppModel

    var body: some View {
        let paused = model.isMicrophonePaused
        let title = paused ? "Снять паузу" : "Пауза микрофона"
        Button {
            model.toggleMicrophonePause()
        } label: {
            Label(title, systemImage: paused ? "mic" : "mic.slash")
        }
        .disabled(!model.canToggleMicrophonePause)
        .accessibilityIdentifier("microphone.pause")
    }
}

/// Плашка с уведомлением (например, «настройки восстановлены»).
struct NoticeBanner: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(Color.orange)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Закрыть уведомление"))
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Последние действия из журнала аудита (без текста команд — его там нет).
struct RecentActivityList: View {
    let entries: [AuditEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Последние действия")
                .font(.subheadline.weight(.semibold))
            if entries.isEmpty {
                Text("Пока пусто. Здесь появятся действия JARVIS — без текста ваших команд.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(entries) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: entry.outcome.symbolName)
                            .foregroundStyle(entry.outcome.color)
                            .accessibilityLabel(Text(entry.outcome.displayName))
                        Text(entry.action.displayName)
                            .lineLimit(1)
                        Spacer()
                        Text(entry.timestamp, format: .dateTime.hour().minute())
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
        .accessibilityIdentifier("activity.recent")
    }
}

/// Кнопка «Говорить» / «Стоп».
struct TalkButton: View {
    let model: AppModel

    var body: some View {
        let listening = model.state == .listening
        let title = listening ? "Стоп" : "Говорить"
        Button {
            model.toggleTalking()
        } label: {
            Label(title, systemImage: listening ? "stop.circle" : "mic.circle")
        }
        .disabled(!listening && !model.assistant.machine.canHandle(.pushToTalkPressed))
        .accessibilityIdentifier("assistant.talk")
    }
}

/// Что сейчас распознано и что ответил ассистент. Только в памяти, нигде не сохраняется.
struct ConversationView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let transcript = model.assistant.liveTranscript {
                Label(transcript.isEmpty ? "Слушаю…" : transcript, systemImage: "waveform")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .accessibilityIdentifier("assistant.transcript")
            }
            if let reply = model.assistant.lastReply {
                Text(reply)
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("assistant.reply")
            }
        }
    }
}

/// Проблема с понятным действием: открыть настройки, скачать модель, повторить.
struct ProblemBanner: View {
    let model: AppModel
    let problem: AssistantProblem
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(problem.message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                switch problem {
                case .microphoneDenied:
                    Button("Открыть настройки") { model.openSystemPrivacySettings(for: problem) }
                case .speechRecognitionDenied:
                    Button("Разрешить распознавание") { model.requestSpeechRecognitionAccess() }
                    Button("Открыть настройки") { model.openSystemPrivacySettings(for: problem) }
                case .speechModelMissing, .speechModelDownloadFailed:
                    Button(model.assistant.isDownloadingModel ? "Скачивается…" : "Скачать модель") {
                        Task { await model.downloadSpeechModel() }
                    }
                    .disabled(model.assistant.isDownloadingModel)
                case .microphoneSilent:
                    Button("Звук в macOS") { model.openSoundSettings() }
                    Button("Настройки JARVIS") {
                        NSApp.activate()
                        openSettings()
                    }
                case .speechModelDownloading, .languageNotSupported, .microphoneUnavailable:
                    EmptyView()
                }
                Button("Повторить") { model.retryAssistant() }
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("assistant.problem")
    }
}

/// Поле для текстовой команды — когда говорить неудобно.
struct CommandField: View {
    let model: AppModel
    @State private var text = ""

    var body: some View {
        TextField("Команда текстом, например «который час»", text: $text)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
                let command = text
                text = ""
                model.submitCommand(command)
            }
            // Пока JARVIS ждёт подтверждения, сюда можно написать «да» или «нет».
            .disabled(!model.assistant.machine.canHandle(.commandReceived) && model.assistant.state != .awaitingConfirmation)
            .accessibilityIdentifier("command.field")
    }
}
