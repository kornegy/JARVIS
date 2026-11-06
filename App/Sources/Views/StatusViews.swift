import SwiftUI
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
                .symbolEffect(.pulse, isActive: presentation.tone == .active)
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

/// Честный индикатор микрофона: показывает, идёт ли захват звука на самом деле.
struct MicrophoneIndicator: View {
    let isCapturing: Bool

    var body: some View {
        let title = isCapturing ? "Микрофон используется" : "Микрофон не используется"
        Label(title, systemImage: isCapturing ? "mic.fill" : "mic.slash")
            .font(.callout)
            .foregroundStyle(isCapturing ? Color.orange : Color.secondary)
            .accessibilityIdentifier("microphone.indicator")
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
        let paused = model.stateMachine.isMicrophonePaused
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
