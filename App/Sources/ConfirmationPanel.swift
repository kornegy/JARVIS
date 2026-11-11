import AppKit
import SwiftUI
import JarvisAssistant

/// Окно подтверждения: «Закрыть «Safari»?» — [Нет] [Да].
///
/// Плавающее (поверх других окон), чтобы вопрос был виден, даже когда главное окно JARVIS
/// закрыто. ⏎ — «Да», Esc или закрытие окна — «Нет». Окно показывает **точное** действие,
/// которое будет выполнено (docs/Security.md §5).
@MainActor
final class ConfirmationPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    /// Что сделать, если окно закрыли крестиком (это «Нет»).
    private var declineOnClose: (() -> Void)?
    private var isClosingProgrammatically = false

    func show(_ pending: PendingAction, onConfirm: @escaping () -> Void, onDecline: @escaping () -> Void) {
        hide()
        declineOnClose = onDecline
        let view = ConfirmationView(
            summary: pending.summary,
            allowsVoice: pending.allowsVoiceConfirmation,
            isDangerous: pending.isDangerous,
            onConfirm: { [weak self] in
                self?.declineOnClose = nil
                onConfirm()
            },
            onDecline: { [weak self] in
                self?.declineOnClose = nil
                onDecline()
            }
        )
        let panel = NSPanel(contentViewController: NSHostingController(rootView: view))
        panel.styleMask = [.titled, .closable]
        panel.title = "JARVIS — подтверждение"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        self.panel = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard let panel else { return }
        isClosingProgrammatically = true
        panel.close()
        isClosingProgrammatically = false
        self.panel = nil
        declineOnClose = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosingProgrammatically else { return }
        let decline = declineOnClose
        declineOnClose = nil
        panel = nil
        decline?()
    }
}

struct ConfirmationView: View {
    let summary: String
    let allowsVoice: Bool
    let isDangerous: Bool
    let onConfirm: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isDangerous ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
                    .foregroundStyle(isDangerous ? Color.red : Color.orange)
                    .accessibilityHidden(true)
                Text(question)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("confirmation.summary")
            }
            Text(hint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Нет", role: .cancel, action: onDecline)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("confirmation.decline")
                Button("Да", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("confirmation.confirm")
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    /// «закрыть «Safari»» → «Закрыть «Safari»?»
    private var question: String {
        guard let first = summary.first else { return summary }
        return first.uppercased() + summary.dropFirst() + "?"
    }

    private var hint: String {
        allowsVoice
            ? "Скажите «да» или «нет» — или нажмите ⏎ / Esc. Без ответа через 30 секунд ничего не произойдёт."
            : "Это действие подтверждается только здесь: кнопкой «Да» или клавишей ⏎. Без ответа через 30 секунд ничего не произойдёт."
    }
}
