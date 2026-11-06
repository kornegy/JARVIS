import AppKit
import SwiftUI

/// Панель, которая открывается по клику на иконку JARVIS в строке меню.
struct MenuBarContentView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusHeader(model: model)

            HStack {
                PowerButton(model: model)
                MicrophonePauseButton(model: model)
            }

            MicrophoneIndicator(isCapturing: model.isMicrophoneCapturing)

            Toggle("Privacy Mode", isOn: model.binding(\.privacy.privacyMode))
                .toggleStyle(.switch)
                .help("Запретить любую сетевую обработку голоса и AI")

            Divider()

            RecentActivityList(entries: Array(model.recentActivity.prefix(3)))

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                menuButton("Открыть окно JARVIS", systemImage: "macwindow") {
                    NSApp.activate()
                    openWindow(id: WindowID.main)
                }
                menuButton("Журнал действий", systemImage: "list.bullet.rectangle") {
                    NSApp.activate()
                    openWindow(id: WindowID.activity)
                }
                menuButton("Настройки…", systemImage: "gearshape") {
                    NSApp.activate()
                    openSettings()
                }
                .keyboardShortcut(",", modifiers: [.command])
                menuButton("Выйти из JARVIS", systemImage: "xmark.circle") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: [.command])
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func menuButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}
