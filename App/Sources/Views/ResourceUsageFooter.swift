import SwiftUI
import JarvisCore

/// Строка самодиагностики внизу главного окна: сколько процессора и памяти тратит JARVIS
/// и какая модель распознавания сейчас слушает.
///
/// Замер идёт раз в 2 секунды и только пока окно открыто (`.task` отменяется, когда окно
/// закрывают), поэтому сама диагностика почти ничего не стоит. Цифры — только для
/// процесса JARVIS: системные службы речи macOS считаются отдельно (docs/PerformanceTargets.md).
struct ResourceUsageFooter: View {
    let model: AppModel
    @State private var cpuPercent: Double?
    @State private var memoryBytes: UInt64?
    @State private var speechModel: String?

    var body: some View {
        Text(summary)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("diagnostics.usage")
            .task {
                var previous = ProcessUsage.sample()
                memoryBytes = previous.memoryBytes
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    let current = ProcessUsage.sample()
                    cpuPercent = ProcessUsage.cpuPercent(from: previous, to: current)
                    memoryBytes = current.memoryBytes
                    speechModel = model.activeSpeechModelName
                    previous = current
                }
            }
    }

    private var summary: String {
        var parts: [String] = []
        parts.append("ЦП: " + (cpuPercent.map { String(format: "%.0f %%", $0) } ?? "…"))
        if let memoryBytes {
            parts.append("Память: " + ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory))
        }
        if let speechModel {
            parts.append("Распознавание: \(speechModel)")
        }
        return parts.joined(separator: " · ")
    }
}
