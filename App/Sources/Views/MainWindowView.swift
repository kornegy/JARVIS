import AppKit
import SwiftUI

/// Небольшое главное окно: статус, управление, последние действия.
struct MainWindowView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusHeader(model: model)

            if let notice = model.notice {
                NoticeBanner(text: notice) { model.dismissNotice() }
            }

            HStack {
                PowerButton(model: model)
                MicrophonePauseButton(model: model)
            }

            MicrophoneIndicator(isCapturing: model.isMicrophoneCapturing)

            if model.isEnabled && !model.isVoiceEngineAvailable {
                Text("Голосовой ввод появится на следующем этапе (Phase 2). Сейчас JARVIS показывает состояние, хранит настройки и ведёт журнал действий.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("voice.unavailable")
            }

            Divider()

            RecentActivityList(entries: Array(model.recentActivity.prefix(5)))

            Divider()

            HStack {
                Button("Журнал действий") {
                    NSApp.activate()
                    openWindow(id: WindowID.activity)
                }
                .keyboardShortcut("l", modifiers: [.command])
                Spacer()
                Button("Настройки…") {
                    NSApp.activate()
                    openSettings()
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
