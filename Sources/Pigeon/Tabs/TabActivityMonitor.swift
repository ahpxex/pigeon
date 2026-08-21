import AppKit

/// Drives each tab's busy spinner and the work log the title
/// summarizer reads. Two inputs:
///
/// - **Submit events** (`.pigeonSurfaceDidSubmit`, bare Enter): the
///   spinner lights *immediately* — the user just asked something to
///   run and shouldn't wait for a sampling tick to see feedback.
/// - **Viewport samples**, once a second (a local read; nothing leaves
///   the machine): screen changes keep the spinner alive and feed the
///   work log. A change within 2s of the user's last keystroke is
///   typing echo — it never lights or extends the spinner, so
///   composing a prompt doesn't spin.
///
/// The spinner clears once the screen has produced nothing on its own
/// for a few seconds (measured from the last spontaneous change or the
/// submit, whichever is later) — "no more updates" is the only off
/// signal, matching how a submitted-and-answered exchange feels.
@MainActor
final class TabActivityMonitor {
    static let shared = TabActivityMonitor()

    private static let sampleInterval: TimeInterval = 1
    /// A change within this window of the last keystroke is treated as
    /// typing echo, not tool output.
    private static let typingEchoWindow: TimeInterval = 2
    /// Busy clears after this long without spontaneous output (also the
    /// grace a fresh submit gets before its first output must appear —
    /// Claude Code's first token can take a couple of seconds).
    private static let busyOffAfter: TimeInterval = 3

    struct Activity {
        /// When the screen last changed for any reason (typing included).
        var lastChangeAt: Date = .distantPast
        /// When the screen last changed on its own (not typing echo).
        var lastSpontaneousAt: Date = .distantPast
        /// When the user last submitted (bare Enter) in this tab.
        var submittedAt: Date = .distantPast
        /// Seconds of spontaneous output observed after the user first
        /// interacted with this tab — "the tool is doing work the user
        /// asked for". TUI startup paint (before any input) doesn't count.
        var workSeconds = 0
        /// Screen tails captured at the moment of each submit (oldest
        /// first, last few kept). At Enter time the input box still
        /// shows what the user typed, so this is the user's request —
        /// in a shell prompt and in a TUI alike. The title summarizer
        /// weighs these over the tool's output.
        var recentSubmits: [String] = []
        fileprivate var lastText = ""
        fileprivate var consecutiveSpontaneous = 0
    }

    /// How many submit snapshots to keep per tab, and their size.
    private static let maxSubmitSnapshots = 3
    private static let submitSnapshotLines = 12
    private static let submitSnapshotBytes = 1_200

    private var activities: [UUID: Activity] = [:]
    private var timer: Timer?

    private init() {}

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { _ in
            Task { @MainActor in TabActivityMonitor.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        NotificationCenter.default.addObserver(
            self, selector: #selector(surfaceDidSubmit),
            name: .pigeonSurfaceDidSubmit, object: nil)
    }

    func activity(for tabID: UUID) -> Activity? {
        activities[tabID]
    }

    @objc private func surfaceDidSubmit(_ notification: Notification) {
        guard let view = notification.object as? Ghostty.SurfaceView,
              let tab = TabManager.all.flatMap(\.tabs)
                  .first(where: { $0.surfaceView === view })
        else { return }
        var activity = activities[tab.id] ?? Activity()
        activity.submittedAt = Date()

        // The notification fires before the keypress reaches the
        // terminal: the screen still shows the composed input.
        var lines = view.viewportText()
            .components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        var snapshot = lines.suffix(Self.submitSnapshotLines).joined(separator: "\n")
        if snapshot.count > Self.submitSnapshotBytes {
            snapshot = String(snapshot.suffix(Self.submitSnapshotBytes))
        }
        if !snapshot.isEmpty {
            activity.recentSubmits.append(snapshot)
            if activity.recentSubmits.count > Self.maxSubmitSnapshots {
                activity.recentSubmits.removeFirst(
                    activity.recentSubmits.count - Self.maxSubmitSnapshots)
            }
        }

        activities[tab.id] = activity
        if !tab.isBusy { tab.isBusy = true }
    }

    /// The user is looking at this tab right now: it is selected in a
    /// key window of the active app. Finishing work anywhere else
    /// leaves an unread mark.
    private func isViewed(_ tab: TerminalTab, in manager: TabManager) -> Bool {
        NSApp.isActive
            && manager.selectedTabID == tab.id
            && tab.surfaceView.window?.isKeyWindow == true
    }

    private func tick() {
        let pairs = TabManager.all.flatMap { manager in
            manager.tabs.map { (manager, $0) }
        }
        activities = activities.filter { id, _ in pairs.contains { $0.1.id == id } }
        let now = Date()

        for (manager, tab) in pairs {
            var activity = activities[tab.id] ?? Activity()
            let text = tab.surfaceView.viewportText()
            let lastInput = tab.surfaceView.lastUserInputAt

            if text != activity.lastText {
                activity.lastText = text
                activity.lastChangeAt = now
                let typingEcho = lastInput.map {
                    now.timeIntervalSince($0) < Self.typingEchoWindow
                } ?? false
                if !typingEcho {
                    activity.lastSpontaneousAt = now
                    activity.consecutiveSpontaneous += 1
                    if lastInput != nil { activity.workSeconds += 1 }
                    // Igniting from samples alone (no submit — e.g. a
                    // build resumes printing) takes two consecutive
                    // changes: a lone repaint (status-line refresh after
                    // an answer) shouldn't flash the spinner. An already
                    // lit spinner is extended by any spontaneous change.
                    if !tab.isBusy, activity.consecutiveSpontaneous >= 2 {
                        tab.isBusy = true
                    }
                } else {
                    activity.consecutiveSpontaneous = 0
                }
            } else {
                activity.consecutiveSpontaneous = 0
            }

            let aliveUntil = max(activity.lastSpontaneousAt, activity.submittedAt)
                .addingTimeInterval(Self.busyOffAfter)
            if tab.isBusy, now >= aliveUntil {
                tab.isBusy = false
                // Work just finished; flag it unless the user watched
                // it happen.
                if !isViewed(tab, in: manager) {
                    tab.hasUnread = true
                }
            }
            if tab.hasUnread, isViewed(tab, in: manager) {
                tab.hasUnread = false
            }

            activities[tab.id] = activity
        }
    }
}
