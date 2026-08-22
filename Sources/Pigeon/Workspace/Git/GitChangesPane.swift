import AppKit
import SwiftGitX
import SwiftUI

/// Git sheet: one unified left column (working-tree changes on top,
/// commit history below — the graph), diff on the right, draggable
/// split between them.
struct GitChangesPane: View {
    @ObservedObject var model: GitRepoModel

    @State private var listWidth: CGFloat?
    /// Vertical split between the changes panel and the history panel
    /// in the left column.
    @State private var changesHeight: CGFloat?

    private var effectiveListWidth: CGFloat {
        listWidth ?? 320
    }

    private var effectiveChangesHeight: CGFloat {
        changesHeight ?? 300
    }

    var body: some View {
        HStack(spacing: 0) {
            leftColumn
                .frame(width: effectiveListWidth)

            // Draggable divider between list and diff.
            Color.clear
                .frame(width: 10)
                .contentShape(Rectangle())
                .overlay {
                    Rectangle().fill(.quaternary).frame(width: 1)
                }
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeLeftRight.set()
                    } else if NSCursor.current == NSCursor.resizeLeftRight {
                        NSCursor.arrow.set()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named("git-split"))
                        .onChanged { value in
                            listWidth = min(
                                max(220, value.location.x),
                                560)
                        })

            GitDiffView(
                patch: model.patch,
                title: model.selectedPath,
                fileExtension: (model.selectedPath as NSString?)?.pathExtension)
                .equatable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .coordinateSpace(name: "git-split")
    }

    private var leftColumn: some View {
        VStack(spacing: 0) {
            // Changes panel (top) with its own scroll.
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    changesList
                        .padding(.vertical, 6)
                }
            }
            .frame(maxHeight: effectiveChangesHeight)

            // Horizontal drag bar between changes and history.
            Color.clear
                .frame(height: 10)
                .contentShape(Rectangle())
                .overlay {
                    Rectangle().fill(.quaternary).frame(height: 1)
                }
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeUpDown.set()
                    } else if NSCursor.current == NSCursor.resizeUpDown {
                        NSCursor.arrow.set()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named("git-left"))
                        .onChanged { value in
                            changesHeight = min(
                                max(120, value.location.y),
                                640)
                        })

            // History panel fills the rest.
            ScrollView {
                historyList
                    .padding(.vertical, 6)
            }

            Divider()

            commitBox
        }
        .coordinateSpace(name: "git-left")
    }

    private var changesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("CHANGES")
            if model.staged.isEmpty && model.unstaged.isEmpty {
                Text("No changes")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            if !model.staged.isEmpty {
                subHeader("Staged")
                ForEach(model.staged, id: \.self) { entry in
                    statusRow(entry, staged: true)
                }
            }
            if !model.unstaged.isEmpty {
                subHeader("Working Tree")
                ForEach(model.unstaged, id: \.self) { entry in
                    statusRow(entry, staged: false)
                }
            }
        }
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("HISTORY")
            if model.commits.isEmpty {
                Text("No commits")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            ForEach(model.commits) { commit in
                commitRow(commit)
            }
        }
    }

    // MARK: Headers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 3)
    }

    private func subHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
    }

    // MARK: Rows

    private func statusRow(_ entry: StatusEntry, staged: Bool) -> some View {
        let delta = (staged ? entry.index : entry.workingTree) ?? entry.index ?? entry.workingTree
        let path = delta?.newFile.path ?? delta?.oldFile.path ?? "?"
        let stats = model.lineStats[entry] ?? (additions: 0, deletions: 0)
        let selected = model.selectedEntry == entry

        return HStack(spacing: 6) {
            Text(Self.statusSymbol(entry))
                .font(.system(size: 10, weight: .bold).monospaced())
                .foregroundStyle(Self.statusColor(entry))
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text((path as NSString).deletingLastPathComponent)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("+\(stats.additions)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.green)
            Text("−\(stats.deletions)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.red)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Color.accentColor.opacity(0.15) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { model.select(entry) }
        .contextMenu {
            if staged {
                Button("Unstage") { model.unstage(entry) }
            } else {
                Button("Stage") { model.stage(entry) }
                Button("Discard Changes…") { model.discard(entry) }
            }
        }
    }

    private func commitRow(_ commit: GitGraphCommit) -> some View {
        let selected = model.selectedCommitID == commit.id
        return HStack(spacing: 6) {
            // Mini graph rail: this commit's dot plus rails to parents.
            HStack(spacing: 2) {
                ForEach(0..<max(1, commit.lane + 1), id: \.self) { lane in
                    Circle()
                        .fill(lane == commit.lane ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: lane == commit.lane ? 6 : 4, height: lane == commit.lane ? 6 : 4)
                }
            }
            .frame(width: 34, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(commit.summary)
                    .font(.system(size: 12))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(commit.id.abbreviated)
                        .font(Font(PreviewFont.terminalSmall))
                        .foregroundStyle(.tertiary)
                    Text(commit.author)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(commit.date, format: .dateTime.month().day())
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Color.accentColor.opacity(0.15) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { model.selectCommit(commit) }
    }

    // MARK: Commit box

    private var commitBox: some View {
        VStack(spacing: 8) {
            if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            TextEditor(text: $model.commitMessage)
                .font(.system(size: 12))
                .frame(height: 56)
                .scrollContentBackground(.hidden)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.quaternary))
                .overlay(alignment: .topLeading) {
                    if model.commitMessage.isEmpty {
                        Text("Commit message")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Button("Stage All") { model.stageAll() }
                    .controlSize(.small)
                Spacer()
                Button("Stash") { model.stashPush() }
                    .controlSize(.small)
                Button("Commit") {
                    Task { await model.commitStaged() }
                }
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.commitMessage.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
    }

    private static func statusSymbol(_ entry: StatusEntry) -> String {
        if entry.status.contains(.indexNew) { return "A" }
        if entry.status.contains(.indexModified) { return "M" }
        if entry.status.contains(.indexDeleted) { return "D" }
        if entry.status.contains(.indexRenamed) { return "R" }
        if entry.status.contains(.workingTreeNew) { return "U" }
        if entry.status.contains(.workingTreeModified) { return "M" }
        if entry.status.contains(.workingTreeDeleted) { return "D" }
        if entry.status.contains(.conflicted) { return "!" }
        return "?"
    }

    private static func statusColor(_ entry: StatusEntry) -> Color {
        if entry.status.contains(.indexNew) { return .green }
        if entry.status.contains(.indexModified) { return .orange }
        if entry.status.contains(.indexDeleted) { return .red }
        if entry.status.contains(.indexRenamed) { return .blue }
        if entry.status.contains(.workingTreeModified) { return .orange }
        if entry.status.contains(.workingTreeDeleted) { return .red }
        return .secondary
    }
}

/// Unified-diff renderer: file header, hunk headers, +/- lines with row
/// tinting, the terminal's font. Also used for commit diffs (graph
/// selections).
struct GitDiffView: View {
    let patch: Patch?
    var title: String?
    /// File extension of the diffed file, for syntax highlighting.
    var fileExtension: String?

    @State private var highlightedLines: [Int: AttributedString] = [:]
    @State private var highlightKey: String = ""

    var body: some View {
        Group {
            if let patch {
                diffBody(patch)
                    .onAppear {
                        let newKey = patch.delta.newFile.path
                        if newKey != highlightKey {
                            highlightKey = newKey
                            highlightedLines = [:]
                        }
                    }
                    .onChange(of: patch.delta.newFile.path) { newPath in
                        highlightKey = newPath
                        highlightedLines = [:]
                    }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right.square")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(title ?? "Select a file or commit to see its diff")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func diffBody(_ patch: Patch) -> some View {
        let font = PreviewFont.terminal
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let title {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04))
                }
                ForEach(Array(patch.hunks.enumerated()), id: \.offset) { hunkIndex, hunk in
                    hunkHeader(hunk)
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { lineIndex, line in
                        lineRow(line, font: font,
                                key: "\(hunkIndex)-\(lineIndex)")
                    }
                }
            }
        }
        .task(id: highlightKey) { await highlight(patch) }
    }

    /// Per-line syntax highlighting: each line highlighted on its own
    /// (simple and index-safe; multi-line constructs like block comments
    /// lose color on continuation lines — acceptable for a diff view).
    /// Two passes: additions+context as one document in hunk order,
    /// deletions as one document — then both maps merge keyed by the
    /// line's flat index across hunks.
    private func highlight(_ patch: Patch) async {
        guard let fileExtension,
              let language = SyntaxHighlighter.language(forExtension: fileExtension)
        else { return }

        func body(_ line: Patch.Hunk.Line) -> String {
            line.content.hasSuffix("\n")
                ? String(line.content.dropLast()) : line.content
        }
        func isDeletion(_ line: Patch.Hunk.Line) -> Bool {
            line.type == .deletion || line.type == .deletionEOF
        }

        // Collect flat indices for both sides.
        var newIndex = 0, oldIndex = 0
        var newEntries: [(Int, String)] = []
        var oldEntries: [(Int, String)] = []
        for hunk in patch.hunks {
            for line in hunk.lines {
                if isDeletion(line) {
                    oldEntries.append((oldIndex, body(line)))
                } else {
                    newEntries.append((newIndex, body(line)))
                }
                newIndex += 1
                oldIndex += 1
            }
        }

        var indexed: [Int: AttributedString] = [:]
        // Highlight both sides as documents (keeps within-side context
        // for strings/comments better than per-line).
        if let whole = await SyntaxHighlighter.attributedString(
            for: newEntries.map(\.1).joined(separator: "\n"), language: language) {
            let lines = SyntaxHighlighter.splitLines(whole)
            for (position, index) in newEntries.map(\.0).enumerated()
            where position < lines.count {
                indexed[index] = AttributedString(lines[position])
            }
        }
        if let whole = await SyntaxHighlighter.attributedString(
            for: oldEntries.map(\.1).joined(separator: "\n"), language: language) {
            let lines = SyntaxHighlighter.splitLines(whole)
            for (position, index) in oldEntries.map(\.0).enumerated()
            where position < lines.count {
                indexed[index] = AttributedString(lines[position])
            }
        }
        highlightedLines = indexed
    }

    private func hunkHeader(_ hunk: Patch.Hunk) -> some View {
        Text(hunk.header.trimmingCharacters(in: .whitespacesAndNewlines))
            .font(Font(PreviewFont.terminalSmall))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04))
    }

    private func lineRow(_ line: Patch.Hunk.Line, font: NSFont, key: String) -> some View {
        let marker: String
        let tint: Color
        switch line.type {
        case .addition, .additionEOF: marker = "+"; tint = .green.opacity(0.10)
        case .deletion, .deletionEOF: marker = "-"; tint = .red.opacity(0.10)
        default: marker = " "; tint = .clear
        }
        let content = line.content
        let body = content.hasSuffix("\n") ? String(content.dropLast()) : content
        let hunkLineIndex = Int(key.split(separator: "-").last ?? "0") ?? 0
        let hunkIndex = Int(key.split(separator: "-").first ?? "0") ?? 0
        // Flat index across hunks, matching highlight()'s walk.
        var flatIndex = 0
        if let patch {
            for (i, hunk) in patch.hunks.enumerated() {
                if i < hunkIndex { flatIndex += hunk.lines.count }
                else {
                    flatIndex += hunkLineIndex
                    break
                }
            }
        }
        let highlighted = highlightedLines[flatIndex]
        return HStack(alignment: .top, spacing: 0) {
            Text(marker)
                .foregroundStyle(marker == "+" ? .green : marker == "-" ? .red : .secondary)
                .frame(width: 18, alignment: .center)
            if let highlighted {
                Text(highlighted)
                    .textSelection(.enabled)
            } else {
                Text(body)
                    .textSelection(.enabled)
            }
        }
        .font(Font(font))
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint)
    }
}

extension GitDiffView: Equatable {
    static func == (lhs: GitDiffView, rhs: GitDiffView) -> Bool {
        lhs.patch == rhs.patch
            && lhs.title == rhs.title
            && lhs.fileExtension == rhs.fileExtension
    }
}
