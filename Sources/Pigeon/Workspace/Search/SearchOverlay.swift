import SwiftUI

/// Match highlights painted over the terminal surface. Rects arrive in
/// surface-view coordinates; this view must overlay the surface exactly.
struct SearchHighlights: View {
    @ObservedObject var model: TerminalSearchModel

    var body: some View {
        Canvas { context, _ in
            for rect in model.visibleRects {
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 2),
                    with: .color(.yellow.opacity(0.35)))
            }
            if let rect = model.currentRect {
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 2),
                    with: .color(.orange.opacity(0.5)))
                context.stroke(
                    Path(roundedRect: rect, cornerRadius: 2),
                    with: .color(.orange), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Floating find bar, top-right over the terminal.
struct SearchBar: View {
    @ObservedObject var model: TerminalSearchModel
    @EnvironmentObject private var ghostty: Ghostty.App

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            // AppKit field: SwiftUI FocusState cannot reliably wrestle
            // first responder from the terminal NSView; this one takes
            // it directly and handles Esc / Enter / shift+Enter.
            FindField(model: model)
                .frame(width: 160, height: 18)
                .accessibilityIdentifier("searchField")

            Text(countLabel)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 38)

            Button { model.previous() } label: {
                Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(model.matches.isEmpty)

            Button { model.next() } label: {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(model.matches.isEmpty)

            Button { model.close() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("closeSearchButton")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.12)))
        .padding(.top, 8)
        .padding(.trailing, 16)
    }

    private var countLabel: String {
        guard !model.matches.isEmpty else {
            return model.query.isEmpty ? "" : "0"
        }
        let current = (model.currentIndex ?? -1) + 1
        let total = model.matches.count >= 2000 ? "2000+" : String(model.matches.count)
        return current > 0 ? "\(current)/\(total)" : total
    }
}

/// Plain NSTextField bridge that owns keyboard focus while the find bar
/// is open. Esc closes, Enter jumps to the next match, shift+Enter to
/// the previous one.
private struct FindField: NSViewRepresentable {
    @ObservedObject var model: TerminalSearchModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.placeholderString = "Find"
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingHead
        field.cell?.sendsActionOnEndEditing = false
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.model = model
        if field.stringValue != model.query,
           field.currentEditor() == nil || field.window?.firstResponder !== field.currentEditor() {
            field.stringValue = model.query
        }
        // Grab focus once per open() (focusToken bump).
        if context.coordinator.lastFocusToken != model.focusToken {
            context.coordinator.lastFocusToken = model.focusToken
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var model: TerminalSearchModel
        var lastFocusToken = -1

        init(model: TerminalSearchModel) {
            self.model = model
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            model.query = field.stringValue
        }

        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
        ) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                model.close()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                // Read the in-flight event, not the hardware state, so
                // synthetic events (automation) carry their shift too.
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                if shift {
                    model.previous()
                } else {
                    model.next()
                }
                return true
            // shift/option+Enter arrive as these instead of insertNewline.
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                 #selector(NSResponder.insertLineBreak(_:)):
                model.previous()
                return true
            default:
                return false
            }
        }
    }
}
