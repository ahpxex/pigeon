import AppKit
import Combine
import GhosttyKit

/// One terminal tab. Owns its surface view (and therefore the shell
/// process) for the tab's whole lifetime, whether or not it is visible.
final class TerminalTab: Identifiable, ObservableObject {
    let id = UUID()
    let surfaceView: Ghostty.SurfaceView

    /// User-assigned name. When set it wins over the shell-reported title.
    @Published var customTitle: String?

    /// OpenMoji code shown in the sidebar; random at birth, user-pickable.
    @Published var iconCode: String = TabIcon.random()

    /// Sidebar group membership; nil = top level.
    @Published var groupID: TabGroup.ID?

    /// Scrollback search state (cmd+F), one per tab.
    @MainActor let search = TerminalSearchModel()

    init?(app: ghostty_app_t) {
        let view = Ghostty.SurfaceView(app: app)
        guard view.surface != nil else { return nil }
        self.surfaceView = view
    }

    /// Sidebar label: custom name > working directory > shell title.
    @MainActor
    var displayTitle: String {
        if let customTitle { return customTitle }
        if let pwd = surfaceView.pwd {
            switch AppSettings.shared.labelStyle {
            case .folderName: return Self.folderLabel(pwd)
            case .fullPath: return (pwd as NSString).abbreviatingWithTildeInPath
            }
        }
        return surfaceView.title
    }

    /// "~/code/pigeon" -> "pigeon", home itself -> "~".
    static func folderLabel(_ pwd: String) -> String {
        let abbreviated = (pwd as NSString).abbreviatingWithTildeInPath
        if abbreviated == "~" { return "~" }
        return (abbreviated as NSString).lastPathComponent
    }
}

/// A collapsible section of tabs in the sidebar.
final class TabGroup: Identifiable, ObservableObject {
    let id = UUID()
    @Published var name: String
    @Published var isExpanded = true

    init(name: String) {
        self.name = name
    }
}

/// Ordered tab list plus selection for one terminal window. Every window
/// owns an instance; ghostty actions arrive via NotificationCenter and
/// each manager only handles the ones about surfaces it owns.
@MainActor
final class TabManager: ObservableObject {
    /// All live managers, in window-creation order. Weakly held — a
    /// manager dies with its window's scene state.
    private struct WeakBox { weak var value: TabManager? }
    private static var registry: [WeakBox] = []

    static var all: [TabManager] {
        registry.compactMap(\.value)
    }

    /// The manager of the frontmost terminal window; app-scoped requests
    /// (menu items, the driver) act on it. keyWindow is nil while the app
    /// is inactive (e.g. driver requests from a background curl), so fall
    /// back to front-to-back window order, which survives deactivation.
    static var forKeyWindow: TabManager? {
        let managers = all
        if let key = NSApp.keyWindow ?? NSApp.mainWindow,
           let manager = managers.first(where: { $0.window === key }) {
            return manager
        }
        for window in NSApp.orderedWindows {
            if let manager = managers.first(where: { $0.window === window }) {
                return manager
            }
        }
        return managers.first
    }

    static func manager(owning view: Ghostty.SurfaceView) -> TabManager? {
        all.first { $0.tab(owning: view) != nil }
    }

    /// The hosting window; wired up by WindowBridge once it exists.
    weak var window: NSWindow?

    /// Per-window sidebar state (width/collapse), persisted app-wide.
    let workspace = WorkspaceState()

    @Published private(set) var tabs: [TerminalTab] = []
    @Published private(set) var groups: [TabGroup] = []
    @Published var selectedTabID: TerminalTab.ID?

    var selectedTab: TerminalTab? {
        tabs.first { $0.id == selectedTabID }
    }

    var ungroupedTabs: [TerminalTab] {
        tabs.filter { $0.groupID == nil }
    }

    func tabs(in group: TabGroup) -> [TerminalTab] {
        tabs.filter { $0.groupID == group.id }
    }

    init() {
        Self.registry.removeAll { $0.value == nil }
        Self.registry.append(WeakBox(value: self))

        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(handleNewTab), name: .pigeonNewTab, object: nil)
        center.addObserver(
            self, selector: #selector(handleCloseTab), name: .pigeonCloseTab, object: nil)
        center.addObserver(
            self, selector: #selector(handleGotoTab), name: .pigeonGotoTab, object: nil)

        newTab()
    }

    /// Tabs in the order the sidebar displays them: top level first,
    /// then each group's members. cmd+1-9 and the held-cmd indicators
    /// follow this order so what you see is what you jump to.
    var visualOrderedTabs: [TerminalTab] {
        ungroupedTabs + groups.flatMap { group in tabs.filter { $0.groupID == group.id } }
    }

    @discardableResult
    func newTab() -> TerminalTab? {
        guard let app = Ghostty.App.shared.app,
              let tab = TerminalTab(app: app)
        else { return nil }
        // A tab opened while a grouped tab is selected joins that group.
        tab.groupID = selectedTab?.groupID
        // Keep icons distinct across open tabs.
        tab.iconCode = TabIcon.random(
            excluding: Set(tabs.map(\.iconCode)),
            category: AppSettings.shared.iconCategory)
        tabs.append(tab)
        selectedTabID = tab.id
        return tab
    }

    /// Close a tab, asking first when its process is still running (the
    /// kernel decides via confirm-close-surface + process state). Pass
    /// `confirmIfNeeded: false` for closes that must not prompt: the
    /// process already exited, or driver-initiated test closes.
    func close(_ tab: TerminalTab, confirmIfNeeded: Bool = true) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        guard confirmIfNeeded, tab.surfaceView.needsConfirmQuit else {
            forceClose(tab)
            return
        }
        CloseConfirmation.present(
            on: tab.surfaceView.window,
            message: "Close \"\(tab.displayTitle)\"?",
            detail: "The terminal still has a running process. "
                + "Closing the tab will kill it.",
            confirmTitle: "Close Tab"
        ) { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.forceClose(tab)
        }
    }

    private func forceClose(_ tab: TerminalTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let window = tab.surfaceView.window
        tabs.remove(at: index)
        // Free the kernel surface now; the view itself lingers until
        // SwiftUI re-renders, and close-then-quit checks the kernel first.
        tab.surfaceView.shutdownSurface()

        if tabs.isEmpty {
            window?.close()
            return
        }
        if selectedTabID == tab.id {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    /// Whether closing the whole window should ask the user first.
    var needsConfirmClose: Bool {
        tabs.contains { $0.surfaceView.needsConfirmQuit }
    }

    /// Drop every tab at once, releasing the surfaces (and shells) without
    /// the close-last-tab window dance. Called when the window goes away —
    /// SwiftUI may keep the scene state alive afterwards, so also retire
    /// this manager from the registry.
    func terminateAllTabs() {
        for tab in tabs { tab.surfaceView.shutdownSurface() }
        tabs.removeAll()
        selectedTabID = nil
        Self.registry.removeAll { $0.value === self || $0.value == nil }
    }

    // MARK: Groups
    //
    // Groups may be empty (created ahead of use); they only disappear via
    // deleteGroup or when a just-created group's name edit is cancelled.

    @discardableResult
    func createGroup(named name: String? = nil) -> TabGroup {
        let group = TabGroup(name: name ?? "Group \(groups.count + 1)")
        groups.append(group)
        return group
    }

    func assign(_ tab: TerminalTab, to group: TabGroup?) {
        // groupID lives on the tab, but which sidebar section a tab renders
        // in is derived state of this manager — publish the change here so
        // the sidebar recomputes its sections.
        objectWillChange.send()
        tab.groupID = group?.id
    }

    /// Delete a group; members (if any) return to the top level.
    func deleteGroup(_ group: TabGroup) {
        for tab in tabs where tab.groupID == group.id {
            tab.groupID = nil
        }
        groups.removeAll { $0.id == group.id }
    }

    /// Collapse state is read by the sidebar's body (derived state of the
    /// manager), so the toggle must publish through the manager too.
    func toggleExpanded(_ group: TabGroup) {
        objectWillChange.send()
        group.isExpanded.toggle()
    }

    func setExpanded(_ group: TabGroup, expanded: Bool) {
        guard group.isExpanded != expanded else { return }
        toggleExpanded(group)
    }

    func select(_ tab: TerminalTab) {
        // Selecting a tab hidden in a collapsed group reveals it.
        if let groupID = tab.groupID,
           let group = groups.first(where: { $0.id == groupID }),
           !group.isExpanded {
            toggleExpanded(group)
        }
        selectedTabID = tab.id
    }

    /// Move a tab so it takes the position currently held by `target`.
    /// Used by drag-reordering (live, as the drag hovers rows).
    func move(tabID: TerminalTab.ID, before target: TerminalTab.ID) {
        guard tabID != target,
              let from = tabs.firstIndex(where: { $0.id == tabID }),
              let to = tabs.firstIndex(where: { $0.id == target })
        else { return }
        tabs.move(
            fromOffsets: IndexSet(integer: from),
            toOffset: to > from ? to + 1 : to)
    }

    /// Move a tab within its own container (its group, or the top level).
    /// `index` addresses the container's member list, not the global array.
    func move(tabID: TerminalTab.ID, toContainerIndex index: Int) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        let members = tabs.filter { $0.groupID == tab.groupID }
        guard members.indices.contains(index),
              let globalTarget = tabs.firstIndex(where: { $0.id == members[index].id })
        else { return }
        move(tabID: tabID, toIndex: globalTarget)
    }

    /// Move a tab to an absolute index (driver/testing).
    func move(tabID: TerminalTab.ID, toIndex index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == tabID }),
              tabs.indices.contains(index)
        else { return }
        tabs.move(
            fromOffsets: IndexSet(integer: from),
            toOffset: index > from ? index + 1 : index)
    }

    private func tab(owning view: Ghostty.SurfaceView) -> TerminalTab? {
        tabs.first { $0.surfaceView === view }
    }

    @objc private func handleNewTab(_ notification: Notification) {
        // Surface-originated (cmd+T in a terminal): only its own window's
        // manager reacts. Menu fallback (nil object): the key window's.
        if let view = notification.object as? Ghostty.SurfaceView {
            guard tab(owning: view) != nil else { return }
        } else {
            guard Self.forKeyWindow === self else { return }
        }
        newTab()
    }

    @objc private func handleCloseTab(_ notification: Notification) {
        guard let view = notification.object as? Ghostty.SurfaceView,
              let tab = tab(owning: view)
        else { return }
        // Process-exit closes come flagged confirm=false; user closes
        // (cmd+W) come flagged true and prompt when a process is running.
        let confirm = notification.userInfo?["confirm"] as? Bool ?? true
        close(tab, confirmIfNeeded: confirm)
    }

    @objc private func handleGotoTab(_ notification: Notification) {
        guard let view = notification.object as? Ghostty.SurfaceView,
              tab(owning: view) != nil
        else { return }
        let ordered = visualOrderedTabs
        guard let raw = notification.userInfo?["goto"] as? Int32,
              !ordered.isEmpty,
              let current = selectedTab,
              let index = ordered.firstIndex(where: { $0.id == current.id })
        else { return }

        switch ghostty_action_goto_tab_e(raw) {
        case GHOSTTY_GOTO_TAB_PREVIOUS:
            select(ordered[(index + ordered.count - 1) % ordered.count])
        case GHOSTTY_GOTO_TAB_NEXT:
            select(ordered[(index + 1) % ordered.count])
        case GHOSTTY_GOTO_TAB_LAST:
            if let last = ordered.last { select(last) }
        default:
            // Positive values are 1-based tab indices (cmd+1 ... cmd+9),
            // counted in sidebar display order.
            let target = Int(raw) - 1
            guard ordered.indices.contains(target) else { return }
            select(ordered[target])
        }
    }
}
