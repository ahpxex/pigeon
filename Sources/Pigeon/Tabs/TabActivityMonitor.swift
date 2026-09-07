import AppKit

/// Applies coding-agent activity hooks to terminal tabs. Hooks are the
/// only source of truth for the sidebar spinner: terminal input, viewport
/// changes, foreground-process state, prompt detection, and silence never
/// infer or clear agent activity.
@MainActor
final class TabActivityMonitor {
    static let shared = TabActivityMonitor()

    struct Activity {
        /// The most recent accepted hook event for this tab.
        var lastEventAt: Date = .distantPast
        /// User prompts supplied by busy hooks, oldest first. The title
        /// summarizer uses these instead of sampling the terminal screen
        /// at Enter time.
        var recentSubmits: [String] = []
        /// Monotonic count of user submissions to the coding agent: a
        /// busy hook that starts a new work interval, or one carrying a
        /// prompt while work is already running (a queued follow-up).
        /// The title summarizer re-titles the tab once per submission.
        var submitCount = 0

        fileprivate var accumulatedWorkSeconds: TimeInterval = 0
        fileprivate var busyStartedAt: Date?
        /// `workSeconds` at the moment of the latest submission.
        fileprivate var workSecondsAtSubmit: TimeInterval = 0

        /// Hook-reported work time. A live busy interval continues to
        /// accrue without polling or inspecting terminal output.
        var workSeconds: TimeInterval {
            accumulatedWorkSeconds + (busyStartedAt.map {
                max(0, Date().timeIntervalSince($0))
            } ?? 0)
        }

        var isBusy: Bool { busyStartedAt != nil }

        /// Hook-reported work time since the latest submission — what
        /// decides whether that submission was substantial enough to
        /// re-title the tab for.
        var workSecondsSinceSubmit: TimeInterval {
            max(0, workSeconds - workSecondsAtSubmit)
        }
    }

    private static let maxSubmitSnapshots = 3
    private static let maxSubmitLength = 1_200

    private var activities: [UUID: Activity] = [:]

    private init() {}

    func activity(for tabID: UUID) -> Activity? {
        activities[tabID]
    }

    /// Apply one authenticated hook event. Returns false when the surface
    /// no longer exists so the reporter receives a non-success response
    /// instead of mistaking a dropped event for an accepted one.
    @discardableResult
    func handleHookActivity(
        surfaceID: String,
        event: String,
        prompt: String? = nil,
        source: String? = nil
    ) -> Bool {
        guard let pair = TabManager.all
            .flatMap({ manager in manager.tabs.map { (manager, $0) } })
            .first(where: { $0.1.surfaceView.agentSurfaceID == surfaceID })
        else { return false }

        let (manager, tab) = pair
        let now = Date()
        var activity = activities[tab.id] ?? Activity()
        let wasBusy = activity.isBusy || tab.isBusy
        let outline = AgentOutlineStore.outline(for: surfaceID)

        switch event {
        case "busy":
            let startsInterval = activity.busyStartedAt == nil
            if startsInterval || prompt != nil {
                activity.workSecondsAtSubmit = activity.workSeconds
                activity.submitCount += 1
            }
            if startsInterval {
                activity.busyStartedAt = now
            }
            activity.lastEventAt = now
            if let prompt {
                record(prompt: prompt, in: &activity)
                outline.append(prompt: prompt, source: source)
            }
            tab.isBusy = true

        case "idle":
            finishBusyInterval(in: &activity, at: now)
            activity.lastEventAt = now
            outline.endSession()
            tab.isBusy = false
            if wasBusy, !isViewed(tab, in: manager) {
                tab.hasUnread = true
            }

        default: // ping: a new idle session baseline
            // A new session also repairs stale state from a previous
            // process that died without delivering idle. Do not count
            // that unknown gap as real work time.
            activity.busyStartedAt = nil
            activity.lastEventAt = now
            outline.endSession()
            tab.isBusy = false
        }

        activities[tab.id] = activity
        return true
    }

    func remove(tabID: UUID, surfaceID: String) {
        activities.removeValue(forKey: tabID)
        AgentOutlineStore.remove(surfaceID: surfaceID)
    }

    /// The user is looking at this tab right now: it is selected in a
    /// key window of the active app. Finishing work anywhere else leaves
    /// an unread mark.
    private func isViewed(_ tab: TerminalTab, in manager: TabManager) -> Bool {
        NSApp.isActive
            && manager.selectedTabID == tab.id
            && tab.surfaceView.window?.isKeyWindow == true
    }

    private func finishBusyInterval(in activity: inout Activity, at now: Date) {
        guard let started = activity.busyStartedAt else { return }
        activity.accumulatedWorkSeconds += max(0, now.timeIntervalSince(started))
        activity.busyStartedAt = nil
    }

    private func record(prompt: String, in activity: inout Activity) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        activity.recentSubmits.append(String(trimmed.prefix(Self.maxSubmitLength)))
        if activity.recentSubmits.count > Self.maxSubmitSnapshots {
            activity.recentSubmits.removeFirst(
                activity.recentSubmits.count - Self.maxSubmitSnapshots)
        }
    }
}
