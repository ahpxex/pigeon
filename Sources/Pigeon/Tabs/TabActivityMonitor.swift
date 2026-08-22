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

    private static let sampleInterval: TimeInterval = 0.5
    /// A change within this window of the last keystroke is treated as
    /// typing echo, not tool output.
    private static let typingEchoWindow: TimeInterval = 2
    /// With a foreground process running (TUI, long command), busy
    /// clears this soon after its output stops.
    private static let stillAfter: TimeInterval = 1.5
    /// …but never before a fresh submit has had time to produce its
    /// first output (Claude Code's first token can take a couple of
    /// seconds of static screen).
    private static let firstTokenGrace: TimeInterval = 3
    /// Back at the shell prompt (no foreground process), busy clears
    /// immediately — this small grace only covers the moment right
    /// after Enter, before the shell-integration prompt marker flips.
    private static let promptSettleGrace: TimeInterval = 0.7

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
        var workSeconds: TimeInterval = 0
        /// Screen tails captured at the moment of each submit (oldest
        /// first, last few kept). At Enter time the input box still
        /// shows what the user typed, so this is the user's request —
        /// in a shell prompt and in a TUI alike. The title summarizer
        /// weighs these over the tool's output.
        var recentSubmits: [String] = []
        fileprivate var lastText = ""
        fileprivate var consecutiveSpontaneous = 0
        /// The user has submitted input INTO a running TUI (Enter while
        /// not at a shell prompt) and hasn't returned to the prompt
        /// since. The spinner exists only for this: an agent chewing on
        /// a prompt. Plain shell commands — instant or long — never
        /// spin.
        fileprivate var inTUISession = false
        /// A coding agent on this surface reported activity via hooks
        /// (Claude Code / Codex / pi, see ActivityHooks): busy/idle
        /// events are authoritative, and heuristic ignition (Enter +
        /// viewport churn) is suppressed from here on — scrolling and
        /// resizes must not light the spinner. Sticky for the tab's
        /// lifetime; the sampling-based *extinguish* paths stay armed
        /// so a lost idle event (crashed agent, killed hook) still
        /// clears the spinner.
        fileprivate var hooksPresent = false
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

    /// A hook/extension inside a coding agent (Claude Code, Codex, pi)
    /// reported run state for a surface. "busy"/"idle" are the
    /// authoritative spinner transitions; "ping" (SessionStart-class
    /// events) only marks the surface as hook-driven so the sampling
    /// heuristics stop guessing for it.
    func handleHookActivity(surfaceID: String, event: String, prompt: String? = nil, source: String? = nil) {
        guard let pair = TabManager.all
            .flatMap({ manager in manager.tabs.map { (manager, $0) } })
            .first(where: { $0.1.surfaceView.agentSurfaceID == surfaceID })
        else { return }
        let (manager, tab) = pair
        var activity = activities[tab.id] ?? Activity()
        activity.hooksPresent = true

        let outline = AgentOutlineStore.outline(for: surfaceID)

        switch event {
        case "busy":
            // Hook events outrank the pre-Enter probe: the agent may
            // report work from states needsConfirmQuit can't see
            // (queued prompts, auto-continues). Keep inTUISession
            // armed so the prompt-return extinguish path still works.
            activity.inTUISession = true
            activities[tab.id] = activity
            if let prompt {
                outline.append(prompt: prompt, source: source)
            }
            if !tab.isBusy { tab.isBusy = true }
        case "idle":
            activities[tab.id] = activity
            if tab.isBusy {
                tab.isBusy = false
                if !isViewed(tab, in: manager) { tab.hasUnread = true }
            }
        default: // "ping" — presence marker only
            activities[tab.id] = activity
        }
    }

    @objc private func surfaceDidSubmit(_ notification: Notification) {
        guard let view = notification.object as? Ghostty.SurfaceView,
              let tab = TabManager.all.flatMap(\.tabs)
                  .first(where: { $0.surfaceView === view })
        else { return }
        var activity = activities[tab.id] ?? Activity()
        activity.submittedAt = Date()

        // The notification fires before the keypress reaches the
        // terminal, so needsConfirmQuit still reflects the pre-Enter
        // state: true = a foreground process was already running and
        // this Enter went INTO it (a TUI prompt submit) — the only
        // case that lights the spinner. At a shell prompt this Enter
        // merely starts a command; no spinner.
        activity.inTUISession = view.needsConfirmQuit

        // The screen also still shows the composed input.
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
        // Hook-equipped agents light the spinner themselves (a busy
        // event is on its way); Enter here may be an empty prompt or a
        // confirmation dialog that starts no agent run, so guessing
        // would just re-create the false-positive this whole path fixes.
        if activity.inTUISession, !activity.hooksPresent, !tab.isBusy { tab.isBusy = true }
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
                    if lastInput != nil { activity.workSeconds += Self.sampleInterval }
                    // Re-ignition mid-session (the agent paused, then
                    // resumed streaming) takes two consecutive changes
                    // so a lone status-line repaint doesn't flash the
                    // spinner. Only within a TUI session — output from
                    // anything else (builds, logs) never spins.
                    if !tab.isBusy, activity.inTUISession,
                       !activity.hooksPresent,
                       activity.consecutiveSpontaneous >= 2 {
                        tab.isBusy = true
                    }
                } else {
                    activity.consecutiveSpontaneous = 0
                }
            } else {
                activity.consecutiveSpontaneous = 0
            }

            // Back at a shell prompt: whatever TUI the user was talking
            // to is gone (or was never there); the session ends.
            if activity.inTUISession, !tab.surfaceView.needsConfirmQuit {
                activity.inTUISession = false
                AgentOutlineStore.outline(for: tab.surfaceView.agentSurfaceID)
                    .endSession()
            }

            if tab.isBusy {
                let sinceSubmit = now.timeIntervalSince(activity.submittedAt)
                let sinceOutput = now.timeIntervalSince(activity.lastSpontaneousAt)
                // needsConfirmQuit (default config) is the kernel's
                // "cursor is not at a shell prompt" — i.e. a foreground
                // command or TUI is running. Back at the prompt the work
                // is over, no matter how recent the last output was: an
                // instant command must not wear the spinner for seconds.
                // With a process running (Claude Code / Codex / pi, a
                // build), the spinner dies as soon as output stops.
                let done = tab.surfaceView.needsConfirmQuit
                    ? sinceOutput >= Self.stillAfter && sinceSubmit >= Self.firstTokenGrace
                    : sinceSubmit >= Self.promptSettleGrace
                if done {
                    tab.isBusy = false
                    // Work just finished; flag it unless the user
                    // watched it happen.
                    if !isViewed(tab, in: manager) {
                        tab.hasUnread = true
                    }
                }
            }
            if tab.hasUnread, isViewed(tab, in: manager) {
                tab.hasUnread = false
            }

            activities[tab.id] = activity
        }
    }
}
