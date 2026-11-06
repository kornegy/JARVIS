import SwiftUI
import JarvisCore

/// Журнал действий: что JARVIS сделал, когда, по чьей команде и с каким результатом.
struct ActivityLogView: View {
    let model: AppModel
    @State private var isConfirmingClear = false

    var body: some View {
        Group {
            if model.recentActivity.isEmpty {
                ContentUnavailableView(
                    "Журнал пуст",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Здесь появятся действия JARVIS. Текст команд, аудио и ответы AI в журнал не записываются.")
                )
            } else {
                Table(model.recentActivity) {
                    TableColumn("Время") { entry in
                        Text(entry.timestamp, format: .dateTime.day().month().hour().minute().second())
                            .monospacedDigit()
                    }
                    TableColumn("Действие") { entry in
                        Text(entry.action.displayName)
                    }
                    TableColumn("Источник") { entry in
                        Text(entry.source.displayName)
                    }
                    TableColumn("Результат") { entry in
                        Label(entry.outcome.displayName, systemImage: entry.outcome.symbolName)
                            .foregroundStyle(entry.outcome.color)
                    }
                    TableColumn("Подтверждение") { entry in
                        Text(entry.confirmationText)
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 320)
        .toolbar {
            ToolbarItem {
                Button("Обновить", systemImage: "arrow.clockwise") {
                    Task { await model.refreshActivity() }
                }
            }
            ToolbarItem {
                Button("Очистить…", systemImage: "trash") {
                    isConfirmingClear = true
                }
                .disabled(model.recentActivity.isEmpty)
            }
        }
        .confirmationDialog("Очистить журнал действий?", isPresented: $isConfirmingClear) {
            Button("Очистить", role: .destructive) {
                Task { await model.clearActivity() }
            }
        } message: {
            Text("Все записи будут удалены с диска без возможности восстановления.")
        }
        .task { await model.refreshActivity() }
    }
}
