import AppKit
import SwiftUI
import JarvisAssistant

/// Небольшое главное окно: статус, управление, разговор, последние действия.
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
            if let problem = model.assistant.problem {
                ProblemBanner(model: model, problem: problem)
            }

            HStack {
                PowerButton(model: model)
                TalkButton(model: model)
                MicrophonePauseButton(model: model)
            }

            MicrophoneIndicator(isCapturing: model.isMicrophoneCapturing)

            if model.isEnabled {
                Text(model.voiceHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("voice.hint")
                if let hotKeyProblem = model.hotKeyProblem {
                    Text(hotKeyProblem)
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                }
                CommandField(model: model)
            }

            ConversationView(model: model)

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

            ResourceUsageFooter(model: model)
            CPUBreakdownSection(model: model)
        }
        .padding(20)
        .frame(width: 400)
    }
}
