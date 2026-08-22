import AppKit
import SwiftUI

/// Global notifications for the palette flow: open the palette, and
/// open the file browser at a URL (posted by the palette's Browse Files
/// action, handled by WorkspaceLayout).
extension Notification.Name {
    static let pigeonOpenPalette = Notification.Name("pigeonOpenPalette")
    static let pigeonOpenFileBrowser = Notification.Name("pigeonOpenFileBrowser")
    /// Open the Git workspace for the selected tab's repository.
    static let pigeonOpenGit = Notification.Name("pigeonOpenGit")
    /// Open the agent message history (cmd+L) for the selected tab.
    static let pigeonOpenMessageHistory = Notification.Name("pigeonOpenMessageHistory")
}

/// The command palette: a fuzzy-searchable list over every open tab and
/// a handful of app actions (Settings, New Tab, Browse Files, …).
/// Tab-switching is the headline — type a fragment of a tab's title or
/// working directory, Enter to jump.
struct CommandPalette: View {
    /// Actions the palette can run, in list order.
    enum Action {
        case browseFiles(URL)
        case newTab
        case newWindow
        case openSettings
        case toggleSidebar
        /// cd the current tab's shell into a recent directory (zoxide).
        case openDirectory(URL)

        var label: String {
            switch self {
            case .browseFiles: return "Browse Files"
            case .newTab: return "New Tab"
            case .newWindow: return "New Window"
            case .openSettings: return "Open Settings"
            case .toggleSidebar: return "Toggle Sidebar"
            case .openDirectory(let url): return
                "cd \((url.path as NSString).abbreviatingWithTildeInPath)"
            }
        }

        var symbol: String {
            switch self {
            case .browseFiles: return "folder"
            case .newTab: return "plus.rectangle"
            case .newWindow: return "macwindow.badge.plus"
            case .openSettings: return "gearshape"
            case .toggleSidebar: return "sidebar.left"
            case .openDirectory: return "arrow.turn.down.right"
            }
        }
    }

    /// One searchable row: either a tab or an action. Tab state is
    /// resolved live at render time — titles and working directories
    /// may change while the palette is open.
    @MainActor
    enum Item: Identifiable {
        case tab(TabManager, TerminalTab.ID)
        case action(Action)

        var id: String {
            switch self {
            case .tab(_, let id): return "tab-\(id.uuidString)"
            case .action(let a): return "action-\(a.label)"
            }
        }

        var tab: TerminalTab? {
            if case .tab(_, let id) = self {
                return TabManager.all.flatMap(\.tabs).first { $0.id == id }
            }
            return nil
        }

        var searchText: String {
            if let tab { return "\(tab.displayTitle) \(tab.surfaceView.pwd ?? "")" }
            if case .action(let a) = self { return a.label }
            return ""
        }

        var displayTitle: String {
            if let tab { return tab.displayTitle }
            if case .action(let a) = self { return a.label }
            return "(closed)"
        }
    }

    @ObservedObject var tabManager: TabManager
    let onClose: () -> Void

    /// The palette's whole interactive state, shared with the field
    /// bridge so arrows/enter/escape act on the same source of truth.
    @StateObject private var model = PaletteModel()

    var body: some View {
        VStack(spacing: 0) {
            PaletteField(model: model, onClose: onClose)
                .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 12))

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            row(item, isSelected: index == model.selectionIndex)
                                .contentShape(Rectangle())
                                .onTapGesture { model.run(item, onClose: onClose) }
                                .id(item.id)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 320)
                .onChange(of: model.selectionIndex) { newIndex in
                    if model.items.indices.contains(newIndex) {
                        proxy.scrollTo(model.items[newIndex].id)
                    }
                }
                .onAppear {
                    model.rebuild()
                }
                .onChange(of: model.query) { _ in
                    model.rebuild()
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
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    private func row(_ item: Item, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            switch item {
            case .tab:
                if let tab = item.tab, let icon = TabIcon.image(for: tab.iconCode) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 18, height: 18)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if let pwd = item.tab?.surfaceView.pwd {
                        Text((pwd as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            case .action(let action):
                Image(systemName: action.symbol)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(action.label)
                    .font(.system(size: 13, weight: .medium))
            }
            Spacer()
            if isSelected {
                Text("↩")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
    }
}

/// Interactive state of the palette: query, items, selection. Kept as an
/// ObservableObject so the NSTextField bridge can drive it directly.
@MainActor
final class PaletteModel: ObservableObject {
    @Published var query = ""
    @Published var items: [CommandPalette.Item] = []
    @Published var selectionIndex = 0

    /// Rebuild the item list: tab rows first, then recent directories
    /// (zoxide), then built-in actions, filtered by the query when
    /// present.
    func rebuild() {
        let tabs = TabManager.all.flatMap { manager in
            manager.tabs.map { CommandPalette.Item.tab(manager, $0.id) }
        }
        let recents = recentDirectories.prefix(6).map {
            CommandPalette.Item.action(.openDirectory(URL(fileURLWithPath: $0)))
        }
        let actions: [CommandPalette.Item] = [
            .action(.browseFiles(startDirectory)),
            .action(.newTab),
            .action(.newWindow),
            .action(.openSettings),
            .action(.toggleSidebar),
        ]
        let all = tabs + recents + actions
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            items = all
            return
        }
        items = all
            .map { ($0, Self.score(query: trimmed, text: $0.searchText)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        if selectionIndex >= items.count { selectionIndex = 0 }
    }

    /// Where Browse Files starts: the key window's selected tab working
    /// directory, falling back to home.
    private var startDirectory: URL {
        if let pwd = TabManager.forKeyWindow?.selectedTab?.surfaceView.pwd {
            return URL(fileURLWithPath: pwd)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// zoxide's frecency-ranked directories (its own database, same
    /// data `z`/`zi` use). Nil when zoxide isn't installed.
    private static var zoxidePath: String? {
        ["/opt/homebrew/bin/zoxide", "/usr/local/bin/zoxide"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private var recentDirectories: [String] {
        guard let zoxide = Self.zoxidePath else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zoxide)
        process.arguments = ["query", "-l", "--score"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // Lines look like " 116.0 /Users/ahpx/code" — score then path
        // (paths with spaces are fine, only the first token is numeric).
        return String(data: data, encoding: .utf8)?
            .components(separatedBy: "\n")
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                // Strip the leading score token.
                let parts = trimmed.split(separator: " ", maxSplits: 1)
                return parts.count == 2 ? String(parts[1]) : nil
            } ?? []
    }

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        selectionIndex = (selectionIndex + delta + items.count) % items.count
    }

    func runSelected(onClose: () -> Void) {
        guard items.indices.contains(selectionIndex) else { return }
        run(items[selectionIndex], onClose: onClose)
    }

    func run(_ item: CommandPalette.Item, onClose: () -> Void) {
        onClose()
        switch item {
        case .tab(let manager, let id):
            if let tab = manager.tabs.first(where: { $0.id == id }) {
                manager.select(tab)
                manager.window?.makeKeyAndOrderFront(nil)
            }
        case .action(let action):
            switch action {
            case .browseFiles(let url):
                NotificationCenter.default.post(
                    name: .pigeonOpenFileBrowser, object: nil, userInfo: ["url": url])
            case .newTab:
                NotificationCenter.default.post(name: .pigeonNewTab, object: nil)
            case .newWindow:
                NotificationCenter.default.post(
                    name: .pigeonNewWindow, object: nil, userInfo: ["id": UUID()])
            case .openSettings:
                NotificationCenter.default.post(name: .pigeonOpenSettings, object: nil)
            case .toggleSidebar:
                withAnimation(.easeOut(duration: 0.15)) {
                    TabManager.forKeyWindow?.workspace.toggleSidebar()
                }
            case .openDirectory(let url):
                // Type the cd into the key tab's shell — the real input
                // path, so zoxide records the visit and the shell prompt
                // stays honest. Only when the tab isn't mid-TUI. The cd
                // text goes through the paste path; Enter must go through
                // the key path (bracketed paste swallows trailing
                // newlines — they don't execute).
                guard let tab = TabManager.forKeyWindow?.selectedTab,
                      !tab.surfaceView.needsConfirmQuit
                else { return }
                tab.surfaceView.sendText("cd " + Self.shellQuoted(url.path))
                tab.surfaceView.sendKey(keyCode: 36, text: "\r")
            }
        }
    }

    /// Quote a path for shells: single quotes, with embedded quotes
    /// escaped per POSIX ('\'' ).
    private static func shellQuoted(_ path: String) -> String {
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Tiny subsequence fuzzy score: every query character must appear
    /// in order; earlier and denser matches score higher. Case-
    /// insensitive; 0 = no match.
    static func score(query: String, text: String) -> Int {
        let q = query.lowercased()
        let t = text.lowercased()
        var qi = q.startIndex
        var score = 0
        var streak = 0
        for ti in t.indices {
            guard qi < q.endIndex else { break }
            if t[ti] == q[qi] {
                score += 1 + streak * 2
                streak += 1
                qi = q.index(after: qi)
            } else {
                streak = 0
            }
        }
        return qi == q.endIndex ? score : 0
    }
}

/// NSTextField bridge that owns first responder while the palette is
/// open (same approach as the terminal's find bar). Arrows move the
/// selection, Enter runs it, escape closes.
private struct PaletteField: NSViewRepresentable {
    @ObservedObject var model: PaletteModel
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model, onClose: onClose) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.placeholderString = "Search tabs and commands…"
        field.delegate = context.coordinator
        // Grab focus as soon as the field is installed in a window.
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.model = model
        context.coordinator.onClose = onClose
        if field.stringValue != model.query,
           field.currentEditor() == nil || field.window?.firstResponder !== field.currentEditor() {
            field.stringValue = model.query
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var model: PaletteModel
        var onClose: () -> Void
        var didFocus = false

        init(model: PaletteModel, onClose: @escaping () -> Void) {
            self.model = model
            self.onClose = onClose
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            model.query = field.stringValue
            model.rebuild()
        }

        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
        ) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                onClose()
                return true
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                model.runSelected(onClose: onClose)
                return true
            case #selector(NSResponder.moveDown(_:)):
                model.moveSelection(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                model.moveSelection(-1)
                return true
            default:
                return false
            }
        }
    }
}
