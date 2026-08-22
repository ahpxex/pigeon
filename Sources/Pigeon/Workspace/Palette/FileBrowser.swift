import AppKit
import MarkdownUI
import SwiftUI

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

    @StateObject private var selection = FileSelection()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(rootURL.path)
                    .font(.system(size: 12, design: .monospaced))
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
                ScrollView {
                    FileTreeLevel(directory: rootURL, depth: 0, selection: selection)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }
                .frame(maxWidth: .infinity)

                Divider()

                Group {
                    if let url = selection.url {
                        FilePreview(url: url)
                    } else {
                        EmptyHint(icon: "doc.text.magnifyingglass",
                                  title: "No file selected",
                                  subtitle: "Pick a file from the tree to preview it")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: preferredSize.width, height: preferredSize.height)
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
    }
}

private func indent(_ depth: Int) -> CGFloat {
    CGFloat(depth) * 14 + 6
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
private struct FilePreview: View {
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
                        .markdownTheme(.gitHub)
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

    private func lineList(_ lines: [NSAttributedString], truncated: Bool) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(AttributedString(line))
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
