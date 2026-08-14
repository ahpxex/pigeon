import AppKit

/// Sheet-style "are you sure" for closing terminals whose process is
/// still running. Shared by the tab-close path and the window-close path.
@MainActor
enum CloseConfirmation {
    static func present(
        on window: NSWindow?,
        message: String,
        detail: String,
        confirmTitle: String,
        onConfirm: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")

        if let window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { onConfirm() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            onConfirm()
        }
    }
}
