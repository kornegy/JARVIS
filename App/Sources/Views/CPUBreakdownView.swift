import AppKit
import SwiftUI
import JarvisCore

/// Раздел «Где тратится процессор»: разбивка нагрузки по потокам JARVIS, наш код
/// и системные службы речи macOS.
///
/// Замер идёт только пока раздел раскрыт, раз в 2 секунды, в фоновой задаче.
/// Анализируется только процессорное время — не звук и не текст.
struct CPUBreakdownSection: View {
    let model: AppModel
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Где тратится процессор", isExpanded: $isExpanded) {
            CPUBreakdownContent(model: model)
        }
        .font(.caption)
        .accessibilityIdentifier("diagnostics.breakdown")
    }
}

private struct CPUBreakdownContent: View {
    let model: AppModel
    @State private var breakdown: CPUBreakdown?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let breakdown {
                row("JARVIS всего", breakdown.total, bold: true)
                group("Потоки JARVIS", breakdown.threads)
                group("Наш код (входит в потоки выше)", breakdown.ownCode)
                if breakdown.speechServices.isEmpty {
                    Text("Системные службы речи: не найдены или нет доступа.")
                        .foregroundStyle(.secondary)
                } else {
                    group("Системные службы речи macOS (отдельные процессы)", breakdown.speechServices)
                }
                Button(copied ? "Скопировано" : "Скопировать отчёт") { copy(breakdown) }
                    .accessibilityIdentifier("diagnostics.copy")
            } else {
                Text("Замеряю…").foregroundStyle(.secondary)
            }
            Text("Только время процессора, без звука и текста. Ничего не сохраняется.")
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
        .task {
            var previous = await Self.snapshot()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                let current = await Self.snapshot()
                breakdown = CPUProfiler.breakdown(from: previous, to: current)
                previous = current
            }
        }
    }

    /// Снимок — в фоне, чтобы сам замер не нагружал главный поток.
    private static func snapshot() async -> CPUSnapshot {
        await Task.detached(priority: .utility) { CPUProfiler.snapshot() }.value
    }

    private func group(_ title: String, _ items: [CPUBreakdown.Item]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(.secondary)
            ForEach(items) { item in
                row(item.name, item.percent, bold: false)
            }
        }
    }

    private func row(_ name: String, _ percent: Double, bold: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name)
                .lineLimit(2)
            Spacer(minLength: 8)
            Text("\(CPUBreakdown.format(percent)) %")
                .monospacedDigit()
        }
        .fontWeight(bold ? .semibold : .regular)
    }

    private func copy(_ breakdown: CPUBreakdown) {
        let report = model.diagnosticsContext + "\n" + breakdown.report
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        copied = true
    }
}
