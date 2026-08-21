import Foundation

/// Samples every tab's visible viewport once a second — a local read,
/// nothing leaves the machine — and derives activity signals:
///
/// - `TerminalTab.isBusy`: the terminal is producing output *on its
///   own* (a build streaming, Claude Code / Codex working). Typing echo
///   doesn't count: a change only qualifies as spontaneous when the
///   user hasn't touched the keyboard for a couple of seconds. The
///   sidebar shows a spinner instead of the tab icon while busy.
/// - A per-tab work log the title summarizer reads to decide when a
///   real work session has happened: spontaneous output after the user
///   interacted, and how long the screen has been quiet since.
@MainActor
final class TabActivityMonitor {
    static let shared = TabActivityMonitor()

    private static let sampleInterval: TimeInterval = 1
    /// A change within this window of the last keystroke is treated as
    /// typing echo, not tool output.
    private static let typingEchoWindow: TimeInterval = 2
    /// Busy switches on after this many consecutive spontaneous
    /// changes…
    private static let busyOnAfter = 2
    /// …and off after this long without any change.
    private static let busyOffAfter: TimeInterval = 3

    struct Activity {
        /// When the screen last changed for any reason (typing included).
        var lastChangeAt: Date = .distantPast
        /// Seconds of spontaneous output observed after the user first
        /// interacted with this tab — "the tool is doing work the user
        /// asked for". TUI startup paint (before any input) doesn't count.
        var workSeconds = 0
        fileprivate var lastText = ""
        fileprivate var consecutiveSpontaneous = 0
    }

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
    }

    func activity(for tabID: UUID) -> Activity? {
        activities[tabID]
    }

    private func tick() {
        let tabs = TabManager.all.flatMap(\.tabs)
        activities = activities.filter { id, _ in tabs.contains { $0.id == id } }
        let now = Date()

        for tab in tabs {
            var activity = activities[tab.id] ?? Activity()
            let text = tab.surfaceView.viewportText()
            let lastInput = tab.surfaceView.lastUserInputAt

            if text != activity.lastText {
                activity.lastText = text
                activity.lastChangeAt = now
                let typingEcho = lastInput.map {
                    now.timeIntervalSince($0) < Self.typingEchoWindow
                } ?? false
                if typingEcho {
                    activity.consecutiveSpontaneous = 0
                } else {
                    activity.consecutiveSpontaneous += 1
                    if lastInput != nil { activity.workSeconds += 1 }
                }
            } else {
                activity.consecutiveSpontaneous = 0
            }

            if activity.consecutiveSpontaneous >= Self.busyOnAfter {
                if !tab.isBusy { tab.isBusy = true }
            } else if now.timeIntervalSince(activity.lastChangeAt) >= Self.busyOffAfter {
                if tab.isBusy { tab.isBusy = false }
            }

            activities[tab.id] = activity
        }
    }
}
