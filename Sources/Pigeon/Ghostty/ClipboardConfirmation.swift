import AppKit
import GhosttyKit

extension Ghostty {
    /// User confirmation for clipboard access the kernel flagged as
    /// sensitive: OSC 52 reads/writes and pastes containing control
    /// characters (paste protection). The kernel only asks when the
    /// clipboard-read / clipboard-write / clipboard-paste-protection
    /// config says so; our job is just the dialog.
    @MainActor
    enum ClipboardConfirmation {
        /// Show the confirmation, sheet-attached when the surface has a
        /// window. Calls `completion` with the user's decision exactly once.
        static func present(
            on window: NSWindow?,
            contents: String,
            request: ghostty_clipboard_request_e,
            completion: @escaping (Bool) -> Void
        ) {
            let alert = NSAlert()
            alert.alertStyle = .warning

            let confirmTitle: String
            switch request {
            case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
                alert.messageText = "Potentially Unsafe Paste"
                alert.informativeText =
                    "The text being pasted contains control characters that "
                    + "the terminal could interpret as commands."
                confirmTitle = "Paste Anyway"
            case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ:
                alert.messageText = "Allow Clipboard Read?"
                alert.informativeText =
                    "A program running in the terminal wants to read the "
                    + "contents of your clipboard."
                confirmTitle = "Allow"
            case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE:
                alert.messageText = "Allow Clipboard Write?"
                alert.informativeText =
                    "A program running in the terminal wants to replace the "
                    + "contents of your clipboard."
                confirmTitle = "Allow"
            default:
                alert.messageText = "Allow Clipboard Access?"
                alert.informativeText =
                    "A program running in the terminal wants to access your clipboard."
                confirmTitle = "Allow"
            }

            alert.accessoryView = previewView(for: contents)
            alert.addButton(withTitle: confirmTitle)
            alert.addButton(withTitle: "Cancel")

            if let window {
                alert.beginSheetModal(for: window) { response in
                    completion(response == .alertFirstButtonReturn)
                }
            } else {
                completion(alert.runModal() == .alertFirstButtonReturn)
            }
        }

        /// A read-only scrollable preview of the affected text so the user
        /// can judge what they're approving. Long content is truncated —
        /// this is a preview, not an editor.
        private static func previewView(for contents: String) -> NSView {
            let maxPreview = 1_000
            var preview = contents
            if preview.count > maxPreview {
                preview = String(preview.prefix(maxPreview)) + "\n…"
            }

            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
            textView.string = preview
            textView.isEditable = false
            textView.font = .monospacedSystemFont(
                ofSize: NSFont.smallSystemFontSize, weight: .regular)
            textView.textContainerInset = NSSize(width: 4, height: 4)

            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
            scroll.documentView = textView
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.drawsBackground = true
            return scroll
        }
    }
}
