import AppKit
import MarkdownUI
import SwiftUI

/// The terminal's configured font (KernelSettings fontFamily/size),
/// used for code previews so the browser reads like the terminal.
/// Falls back to the system monospaced face when no family is set or
/// the family fails to load.
@MainActor
enum PreviewFont {
    static var terminal: NSFont {
        let size = CGFloat(KernelSettings.shared.fontSize)
        let family = KernelSettings.shared.fontFamily
        if !family.isEmpty, let font = NSFont(name: family, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Scaled variant for dense UI spots (path captions etc.).
    static var terminalSmall: NSFont {
        let size = max(10, CGFloat(KernelSettings.shared.fontSize) - 2)
        let family = KernelSettings.shared.fontFamily
        if !family.isEmpty, let font = NSFont(name: family, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// File browser opened from the command palette's "Browse Files"
/// action: a lazily-expanded directory tree on the left (starting with
/// the *contents* of the terminal's working directory — no parent row),
/// a preview pane on the right. Code files get highlight.js syntax
/// colors (Highlightr), markdown renders as styled text, images show
/// inline; everything is line-lazy so big files stay smooth.
struct FileBrowser: View {
    @Environment(\.dismiss) private var dismiss

    /// Root of the tree: the working directory of the tab that opened
    /// the palette.
    let rootURL: URL
    /// Sheet size, derived from the presenting window (proportional,
    /// slightly smaller, centered).
    var preferredSize: CGSize = CGSize(width: 720, height: 520)
    /// Left pane width; live-adjusted by the divider drag. Defaults to
    /// roughly a third of the sheet — narrow tree, wide preview.
    @State private var treeWidth: CGFloat?
    /// Search field state: when non-nil, the tree shows matching files
    /// anywhere under the root (recursive) instead of the directory tree.
    @State private var searchQuery: String?
    /// Search hits for the current query (computed off-main; set when
    /// done). Reset whenever the query changes.
    @State private var searchMatches: [FileNode]?
    /// Autofocus the search field when the browser opens.
    @FocusState private var focusSearch: Bool

    private var effectiveTreeWidth: CGFloat {
        treeWidth ?? min(260, preferredSize.width * 0.32)
    }

    @StateObject private var selection = FileSelection()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(rootURL.path)
                    .font(Font(PreviewFont.terminalSmall))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)

            Divider()

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        TextField("Search files…", text: searchBinding)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .onSubmit { focusSearch = false }
                            .focused($focusSearch)
                        if searchQuery != nil {
                            Button {
                                searchQuery = nil
                                searchMatches = nil
                                focusSearch = true
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    Divider()
                    ScrollView {
                        if let results = searchMatches, searchQuery != nil {
                            SearchResultList(results: results, selection: selection)
                                .padding(.vertical, 6)
                        } else {
                            FileTreeLevel(directory: rootURL, depth: 0, selection: selection)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                        }
                    }
                }
                .frame(width: effectiveTreeWidth)

                // Draggable divider: narrow tree on the left, wide
                // preview on the right. The drag sets the width from the
                // pointer's position in the split's coordinate space —
                // no delta bookkeeping, and the drag survives the
                // divider sliding under the pointer.
                Color.clear
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .overlay {
                        Rectangle()
                            .fill(.quaternary)
                            .frame(width: 1)
                    }
                    .onHover { hovering in
                        // set() (not push/pop): the divider moves under
                        // the pointer during drags, which would unbalance
                        // the cursor stack.
                        if hovering {
                            NSCursor.resizeLeftRight.set()
                        } else if NSCursor.current == NSCursor.resizeLeftRight {
                            NSCursor.arrow.set()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("pigeon-split"))
                            .onChanged { value in
                                treeWidth = min(
                                    max(160, value.location.x),
                                    preferredSize.width - 260)
                            }
                    )

                Group {
                    if let url = selection.url {
                        FilePreview(url: url)
                            .equatable()
                    } else {
                        EmptyHint(icon: "doc.text.magnifyingglass",
                                  title: "No file selected",
                                  subtitle: "Pick a file from the tree to preview it")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .coordinateSpace(name: "pigeon-split")
        }
        .frame(width: preferredSize.width, height: preferredSize.height)
        .onAppear { focusSearch = true }
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { searchQuery ?? "" },
            set: { newValue in
                searchQuery = newValue.isEmpty ? nil : newValue
                searchMatches = nil
                scheduleSearch()
            })
    }

    /// Debounced search-as-you-type: fd runs off-main, respects
    /// .gitignore, and parallelizes the walk natively — broad queries
    /// over big trees return without beachballing. fd missing falls
    /// back to no results rather than a hand-rolled walk: fast broad
    /// search is the whole point.
    private func scheduleSearch() {
        searchTask?.cancel()
        guard let query = searchQuery?.trimmingCharacters(in: .whitespaces),
              !query.isEmpty
        else { return }
        let root = rootURL
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let matches = await Task.detached(priority: .userInitiated) {
                Self.fdSearch(query, root: root)
            }.value
            guard !Task.isCancelled else { return }
            searchMatches = matches
        }
    }

    @State private var searchTask: Task<Void, Never>?

    /// fd binary, if installed.
    private static var fdPath: String? {
        ["/opt/homebrew/bin/fd", "/usr/local/bin/fd"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Name-substring search via fd: dotfiles included, .gitignore
    /// respected (fd's default), files and directories, capped.
    private static func fdSearch(_ query: String, root: URL) -> [FileNode] {
        guard let fd = fdPath else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: fd)
        process.arguments = [
            query, root.path,
            "--hidden",
            "--max-results", "500",
            "--max-depth", "12",
            "--absolute-path",
            "--type", "f", "--type", "d",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return String(data: data, encoding: .utf8)?
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .map { line -> FileNode in
                let url = URL(fileURLWithPath: line)
                var isDir: ObjCBool = false
                let isDirectory = FileManager.default.fileExists(
                    atPath: line, isDirectory: &isDir) && isDir.boolValue
                return FileNode(url: url, isDirectory: isDirectory)
            } ?? []
    }
}

/// Currently previewed URL, shared by the tree rows and the pane.
@MainActor
final class FileSelection: ObservableObject {
    @Published var url: URL?

    func select(_ url: URL) {
        self.url = url
    }
}

/// One tree entry. Immutable value; expansion state lives in the views,
/// which is what makes clicks actually re-render (OutlineGroup over a
/// plain class silently ignores mutations — that was the bug).
struct FileNode: Identifiable {
    let url: URL
    let isDirectory: Bool

    var id: String { url.path }
    var displayName: String { url.lastPathComponent }

    /// Entries of a directory: directories first, then files, both
    /// name-sorted. Empty array for an empty directory.
    static func loadChildren(of url: URL) -> [FileNode] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return [] }
        var dirs: [FileNode] = []
        var files: [FileNode] = []
        for entry in entries {
            var isDir: ObjCBool = false
            let isDirectory = FileManager.default.fileExists(
                atPath: entry.path, isDirectory: &isDir) && isDir.boolValue
            if isDirectory {
                dirs.append(FileNode(url: entry, isDirectory: true))
            } else {
                files.append(FileNode(url: entry, isDirectory: false))
            }
        }
        let byName: (FileNode, FileNode) -> Bool = {
            $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent)
                == .orderedAscending
        }
        return dirs.sorted(by: byName) + files.sorted(by: byName)
    }
}

/// One directory's entries as tree rows. Children load on first appear
/// (the level only enters the hierarchy once its parent expands).
private struct FileTreeLevel: View {
    let directory: URL
    let depth: Int
    @ObservedObject var selection: FileSelection

    @State private var entries: [FileNode]?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if let entries {
                if entries.isEmpty {
                    Text("(empty)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, indent(depth))
                        .padding(.vertical, 2)
                }
                ForEach(entries) { node in
                    FileTreeRow(node: node, depth: depth, selection: selection)
                }
            }
        }
        .onAppear {
            guard entries == nil else { return }
            entries = FileNode.loadChildren(of: directory)
        }
    }
}

/// One row plus — for a directory — its nested level while expanded.
private struct FileTreeRow: View {
    let node: FileNode
    let depth: Int
    @ObservedObject var selection: FileSelection

    @State private var isExpanded = false
    @State private var children: [FileNode]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if isExpanded, let children {
                FileTreeLevel(directory: node.url, depth: depth + 1, selection: selection)
            }
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            if node.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            } else {
                Color.clear.frame(width: 9)
            }
            Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                .font(.system(size: 11))
                .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
            Text(node.displayName)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, indent(depth))
        .padding(.vertical, 2.5)
        .padding(.trailing, 8)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(selection.url == node.url
                      ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if node.isDirectory {
                if children == nil {
                    children = FileNode.loadChildren(of: node.url)
                }
                isExpanded.toggle()
            } else {
                selection.select(node.url)
            }
        }
        .contextMenu { FileContextMenu(url: node.url).content }
    }
}

private func indent(_ depth: Int) -> CGFloat {
    CGFloat(depth) * 14 + 6
}

/// Flat list of search hits: relative-path subtitles, click selects.
private struct SearchResultList: View {
    let results: [FileNode]
    @ObservedObject var selection: FileSelection

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(results) { node in
                HStack(spacing: 6) {
                    Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                        .font(.system(size: 11))
                        .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.displayName)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Text(node.url.path)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(selection.url == node.url
                              ? Color.accentColor.opacity(0.18) : Color.clear)
                )
                .contentShape(Rectangle())
                .onTapGesture { selection.select(node.url) }
                .contextMenu { FileContextMenu(url: node.url).content }
            }
        }
    }
}

/// Open-with targets for the context menu.
enum FileOpenActions {
    /// VS Code's CLI lives in /usr/local/bin (Intel) or
    /// /opt/homebrew/bin (Apple Silicon); resolve whatever exists.
    private static var codeBinary: String? {
        ["/usr/local/bin/code", "/opt/homebrew/bin/code"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var hasVSCode: Bool { codeBinary != nil }

    static func openInVSCode(_ url: URL) {
        guard let code = codeBinary else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: code)
        process.arguments = [url.path]
        try? process.run()
    }

    static func openWithDefaultApp(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Reveal in Finder — the natural third leg of an open-with menu.
    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Context menu pieces shared by tree rows and search results.
struct FileContextMenu {
    let url: URL

    @ViewBuilder var content: some View {
        if FileOpenActions.hasVSCode {
            Button("Open in VS Code") { FileOpenActions.openInVSCode(url) }
        }
        Button("Open With…") { FileOpenActions.openWithDefaultApp(url) }
        Button("Reveal in Finder") { FileOpenActions.revealInFinder(url) }
    }
}

/// macOS-13-compatible placeholder (ContentUnavailableView is 14+).
private struct EmptyHint: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Right-hand pane: renders whatever is selected. Loading (decode +
/// highlight) happens on a background task; rows render lazily so a
/// 256 KB file never beachballs the browser.
private struct FilePreview: View, Equatable {
    static func == (lhs: FilePreview, rhs: FilePreview) -> Bool {
        lhs.url == rhs.url
    }
    let url: URL

    @State private var preview: PreviewBody?

    enum PreviewBody {
        case plain([NSAttributedString])
        case code([NSAttributedString], truncated: Bool)
        case markdown(String)
        case image(NSImage)
        case binary(Int64)
    }

    var body: some View {
        Group {
            switch preview {
            case nil:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .plain(let lines):
                lineList(lines, truncated: false)
            case .code(let lines, let truncated):
                lineList(lines, truncated: truncated)
            case .markdown(let source):
                ScrollView {
                    Markdown(source)
                        .markdownTheme(Self.terminalCodeTheme)
                        .markdownCodeSyntaxHighlighter(HighlightrCodeSyntaxHighlighter())
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .image(let image):
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image).interpolation(.high).padding(12)
                }
            case .binary(let size):
                EmptyHint(icon: "doc.badge.ellipsis", title: "Binary file",
                          subtitle: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
        }
        .overlay(alignment: .bottom) {
            Text(url.lastPathComponent)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .onChange(of: url) { _ in preview = nil }
        .task(id: url) { await load() }
    }

    /// GitHub theme with the terminal's font family/size for inline and
    /// fenced code — preview text should read like the terminal.
    @MainActor
    static var terminalCodeTheme: Theme {
        let font = PreviewFont.terminal
        return .gitHub
            .code {
                if let family = font.familyName {
                    FontFamily(.custom(family))
                }
                FontSize(CGFloat(font.pointSize))
            }
    }

    private func lineList(_ lines: [NSAttributedString], truncated: Bool) -> some View {
        let font = PreviewFont.terminal
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(AttributedString(line))
                        .font(Font(font))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 0.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if truncated {
                    Text("… truncated — file continues")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
            }
            .padding(.vertical, 8)
            .textSelection(.enabled)
        }
    }

    private func load() async {
        let url = self.url
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let typeID = (try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier) ?? ""
        let isImage = typeID.hasPrefix("public.image")
            || ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "svg", "ico"]
                .contains(url.pathExtension.lowercased())

        if isImage, let image = NSImage(contentsOf: url) {
            preview = .image(image)
            return
        }

        guard let data = try? Data(contentsOf: url) else {
            preview = .plain([NSAttributedString(string: "(unreadable)")])
            return
        }
        if data.prefix(8192).contains(0) {
            preview = .binary(Int64(data.count))
            return
        }

        // Everything below is CPU work on strings — keep it off main.
        let rendered: PreviewBody = await Task.detached(priority: .userInitiated) {
            let limit = 256 * 1024
            var slice = data.prefix(limit)
            while !slice.isEmpty, String(data: slice, encoding: .utf8) == nil {
                slice = slice.dropLast(1)
            }
            let text = String(data: slice, encoding: .utf8)
                ?? String(decoding: slice, as: UTF8.self)
            let truncated = data.count > slice.count

            let isMarkdown = ["md", "markdown"].contains(url.pathExtension.lowercased())
            if isMarkdown {
                return PreviewBody.markdown(text)
            }
            if let lines = await MainActor.run(body: {
                SyntaxHighlighter.attributedLines(for: text, fileURL: url)
            }) {
                return .code(lines, truncated: truncated)
            }
            return .plain(text.components(separatedBy: "\n").map(NSAttributedString.init))
        }.value
        preview = rendered
    }
}
