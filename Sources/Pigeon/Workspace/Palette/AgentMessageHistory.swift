import AppKit
import SwiftUI

/// Linear message history for a tab's coding-agent session, opened
/// with cmd+L: a palette-style overlay listing every captured prompt,
/// newest last. Click (or arrows + Enter) to jump the terminal's
/// scrollback to that message.
struct AgentMessageHistory: View {
    @ObservedObject var outline: AgentOutlineModel
    @ObservedObject var tab: TerminalTab
    let onClose: () -> Void

    @State private var selectionIndex: Int?
    @State private var query = ""

    private var filtered: [(index: Int, entry: AgentOutlineModel.Entry)] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return outline.entries.enumerated().map { ($0.offset, $0.element) }
        }
        return outline.entries.enumerated()
            .filter { $0.element.prompt.localizedCaseInsensitiveContains(trimmed) }
            .map { ($0.offset, $0.element) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered, id: \.entry.id) { item in
                            row(index: item.index, entry: item.entry)
                        }
                        if filtered.isEmpty {
                            Text(query.isEmpty
                                ? "No messages yet — prompts appear here as you send them to the agent"
                                : "No matches")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(16)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 320)
                .onAppear {
                    selectionIndex = outline.entries.indices.last
                    if let last = outline.entries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: query) { _ in
                    selectionIndex = filtered.last?.index
                }
            }
        }
        .frame(width: 520)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.background)
                .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary, lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 8) {
            PaletteFieldLike(
                text: $query,
                placeholder: "Search messages…",
                onUp: { move(-1) },
                onDown: { move(1) },
                onEnter: { runSelected() },
                onCancel: onClose)
                .frame(maxWidth: .infinity)
            Text("\(outline.entries.count)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 12))
    }

    private func row(index: Int, entry: AgentOutlineModel.Entry) -> some View {
        let selected = selectionIndex == index
        return HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.prompt)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if let source = entry.source {
                        Text(source)
                    }
                    Text(entry.date, format: .dateTime.month().day().hour().minute())
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            selectionIndex = index
            runSelected()
        }
        .id(entry.id)
    }

    private func move(_ delta: Int) {
        let items = filtered
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.index == selectionIndex }
            ?? items.count - 1
        let next = (current + delta + items.count) % items.count
        selectionIndex = items[next].index
    }

    private func runSelected() {
        guard let index = selectionIndex,
              outline.entries.indices.contains(index)
        else { return }
        let entry = outline.entries[index]
        onClose()
        // Let the palette dismissal settle before scrolling.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            jump(to: entry)
        }
    }

    /// Scroll the terminal's scrollback to this message: search the
    /// recent buffer for the prompt's first line, center the viewport
    /// on the hit. Silent no-op when the line has scrolled out.
    private func jump(to entry: AgentOutlineModel.Entry) {
        let view = tab.surfaceView
        guard let grid = view.searchGrid() else { return }
        let needle = entry.prompt.components(separatedBy: "\n").first ?? entry.prompt
        let prefix = String(needle.prefix(60)).trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty else { return }

        let total = view.totalScreenRows(cols: grid.cols, viewportRows: grid.rows)
        let chunkRows = 1024
        var row = max(0, total - 20_000)
        while row < total {
            let last = min(row + chunkRows - 1, total - 1)
            guard let text = view.readScreenRows(row, last, cols: grid.cols) else { break }
            for (offset, line) in text.components(separatedBy: "\n").enumerated() {
                if line.contains(prefix) {
                    let matchRow = row + offset
                    let maxTop = max(0, total - grid.rows)
                    let target = min(max(0, matchRow - grid.rows / 2), maxTop)
                    view.scrollToBottom()
                    view.scrollLines(target - maxTop)
                    return
                }
            }
            row = last + 1
        }
    }
}

/// Search field for the message history: an NSTextField bridge that
/// owns keyboard focus (same approach as the find bar), handling
/// arrows/enter/escape through doCommandBy.
private struct PaletteFieldLike: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onUp: () -> Void
    var onDown: () -> Void
    var onEnter: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: PaletteFieldLike
        init(parent: PaletteFieldLike) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
        ) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onEnter()
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onDown()
                return true
            default:
                return false
            }
        }
    }
}
