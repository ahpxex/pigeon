import AppKit
import SwiftGitX
import SwiftUI

/// Git sheet: a single left column (changes on top, history with the
/// mini graph below) and the diff on the right, with a draggable
/// split. All git operations go through SwiftGitX (libgit2) except
/// stashes, which shell out to the git CLI.
struct GitWorkspace: View {
    let repoURL: URL
    var preferredSize: CGSize = CGSize(width: 860, height: 560)

    @StateObject private var model = GitRepoModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GitChangesPane(model: model)
        }
        .frame(width: preferredSize.width, height: preferredSize.height)
        .task { await model.load(repoURL: repoURL) }
        .onReceive(NotificationCenter.default.publisher(for: .pigeonGitDidChange)) { _ in
            Task { await model.refresh() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(repoURL.lastPathComponent)
                .font(.system(size: 12, weight: .medium))
            if let branch = model.currentBranch {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(branch)
                    .font(.system(size: 12, weight: .medium))
            }

            Spacer()

            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")

            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }
}

/// Async repository state for the Git sheet. One refresh loads status,
/// stash list, branch, and (lazily available to the graph pane) log.
@MainActor
final class GitRepoModel: ObservableObject {
    @Published var status: [StatusEntry] = []
    @Published var stashes: [StashListItem] = []
    @Published var currentBranch: String?
    @Published var aheadBehind: (Int, Int)?
    @Published var commits: [GitGraphCommit] = []
    @Published var selectedEntry: StatusEntry?
    @Published var selectedCommitID: OID?
    @Published var patch: Patch?
    @Published var selectedPath: String?
    @Published var commitMessage = ""
    @Published var errorMessage: String?
    /// +/- line counts per status entry, loaded lazily per selection
    /// batch (diffing every file on refresh would be slow on big
    /// changesets).
    @Published var lineStats: [StatusEntry: (additions: Int, deletions: Int)] = [:]

    private(set) var repository: Repository?
    private(set) var repoURL: URL?

    struct StashListItem: Identifiable, Equatable {
        let id: Int
        let message: String
    }

    func load(repoURL: URL) async {
        self.repoURL = repoURL
        await refresh()
    }

    func refresh() async {
        let url = repoURL
        guard let url else { return }
        let repo: Repository
        do {
            repo = try Repository.open(at: url)
        } catch {
            errorMessage = "Not a git repository: \(url.path)"
            return
        }
        repository = repo
        errorMessage = nil
        await reloadStatus()
        await reloadStashes()
        loadBranch()
        await loadLog()
        await loadLineStats()
    }

    /// +/− counts for each status entry (from each file's patch hunks).
    private func loadLineStats() async {
        guard let repo = repository else { return }
        var result: [StatusEntry: (additions: Int, deletions: Int)] = [:]
        for entry in status {
            let delta = entry.index ?? entry.workingTree
            guard let delta,
                  let patch = try? repo.patch(from: delta)
            else { continue }
            var additions = 0, deletions = 0
            for hunk in patch.hunks {
                for line in hunk.lines {
                    switch line.type {
                    case .addition, .additionEOF: additions += 1
                    case .deletion, .deletionEOF: deletions += 1
                    default: break
                    }
                }
            }
            result[entry] = (additions, deletions)
        }
        lineStats = result
    }

    private func reloadStatus() async {
        guard let repo = repository else { return }
        do {
            status = try repo.status()
        } catch {
            errorMessage = "status failed: \(error)"
        }
    }

    private func loadBranch() {
        guard let repo = repository else { return }
        if let head = try? repo.HEAD as? Branch {
            currentBranch = head.name
        }
    }

    private func reloadStashes() async {
        guard let url = repoURL else { return }
        // SwiftGitX doesn't wrap stash enumeration; ask the CLI (it's
        // the same repository and object database).
        let out = GitCLI.run(["stash", "list", "--format=%gd|%s"], cwd: url)
        stashes = out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2,
                  let index = parts[0].split(separator: "{")[1]
                .split(separator: "}").first
            else { return nil }
            return StashListItem(id: Int(index) ?? 0, message: String(parts[1]))
        }
    }

    private func loadLog() async {
        guard let repo = repository else { return }
        // Parents come with the commit objects; the graph layout is
        // computed from them in GitGraphCommit.make.
        var result: [GitGraphCommit] = []
        let sequence: CommitSequence
        do {
            sequence = try repo.log(sorting: .topological)
        } catch {
            errorMessage = "log failed: \(error)"
            return
        }
        for commit in sequence.prefix(300) {
            result.append(GitGraphCommit(commit: commit))
        }
        commits = GitGraphCommit.assignLanes(result)
    }

    // MARK: Selection / diff

    /// Entries staged in the index (index delta present, no working-tree
    /// changes of their own).
    var staged: [StatusEntry] {
        status.filter { $0.index != nil && $0.workingTree == nil }
    }

    /// Entries with working-tree changes (staged-and-modified included;
    /// the row is listed once under Changes).
    var unstaged: [StatusEntry] {
        status.filter { $0.workingTree != nil }
    }

    func select(_ entry: StatusEntry?) {
        selectedEntry = entry
        selectedCommitID = nil
        patch = nil
        guard let entry, let repo = repository else { return }
        let delta = entry.workingTree ?? entry.index
        guard let delta else { return }
        selectedPath = delta.newFile.path
        do {
            patch = try repo.patch(from: delta) ?? patch
        } catch {
            errorMessage = "diff failed: \(error)"
        }
    }

    /// Select a commit from the history: show its diff (against its
    /// first parent) — first file's patch for now; the graph pane grows
    /// a file list next.
    func selectCommit(_ commit: GitGraphCommit) {
        selectedEntry = nil
        selectedCommitID = commit.id
        patch = nil
        selectedPath = nil
        guard let repo = repository else { return }
        do {
            let full = try repo.show(id: commit.id) as Commit
            if let parents = try? full.parents, let parent = parents.first {
                let treeDiff = try repo.diff(from: parent, to: full)
                patch = treeDiff.patches.first
            }
        } catch {
            errorMessage = "commit diff failed: \(error)"
        }
    }

    // MARK: Actions

    func stage(_ entry: StatusEntry) {
        guard let repo = repository,
              let delta = entry.workingTree ?? entry.index
        else { return }
        try? repo.add(paths: [delta.newFile.path])
        Task { await refresh(); select(nil) }
    }

    func stageAll() {
        for entry in status where entry.workingTree != nil {
            stage(entry)
        }
    }

    func unstage(_ entry: StatusEntry) {
        guard let repo = repository,
              let delta = entry.index
        else { return }
        // Unstage = reset the index entry to HEAD. HEAD can be unborn
        // on a fresh repo; then there is nothing staged anyway.
        if let head = try? repo.HEAD as? Branch,
           let headCommit = head.target as? Commit {
            try? repo.reset(from: headCommit, paths: [delta.newFile.path])
        }
        Task { await refresh(); select(nil) }
    }

    func discard(_ entry: StatusEntry) {
        guard let repo = repository,
              let delta = entry.workingTree ?? entry.index
        else { return }
        try? repo.restore(
            RestoreOption([.workingTree, .staged]),
            paths: [delta.newFile.path])
        Task { await refresh(); select(nil) }
    }

    func commitStaged() async {
        guard let repo = repository,
              !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        do {
            _ = try repo.commit(message: commitMessage)
            commitMessage = ""
            await refresh()
        } catch {
            errorMessage = "commit failed: \(error)"
        }
    }

    // MARK: Stash (CLI-backed)

    func stashPush() {
        guard let url = repoURL else { return }
        _ = GitCLI.run(["stash", "push", "--include-untracked"], cwd: url)
        Task { await refresh() }
    }

    func stashApply(_ item: StashListItem) {
        guard let url = repoURL else { return }
        _ = GitCLI.run(["stash", "apply", "stash@{\(item.id)}"], cwd: url)
        Task { await refresh() }
    }

    func stashPop(_ item: StashListItem) {
        guard let url = repoURL else { return }
        _ = GitCLI.run(["stash", "pop", "stash@{\(item.id)}"], cwd: url)
        Task { await refresh() }
    }

    func stashDrop(_ item: StashListItem) {
        guard let url = repoURL else { return }
        _ = GitCLI.run(["stash", "drop", "stash@{\(item.id)}"], cwd: url)
        Task { await refresh() }
    }
}

/// Thin wrapper for shelling out to git (stash only, until SwiftGitX
/// wraps it).
enum GitCLI {
    @discardableResult
    static func run(_ arguments: [String], cwd: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

extension Notification.Name {
    /// Posted after Git mutations so the sheet can refresh (also lets
    /// future callers outside the sheet trigger one).
    static let pigeonGitDidChange = Notification.Name("pigeonGitDidChange")
}
