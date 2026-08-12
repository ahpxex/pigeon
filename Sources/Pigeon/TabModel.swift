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

    init?(app: ghostty_app_t) {
        let view = Ghostty.SurfaceView(app: app)
        guard view.surface != nil else { return nil }
        self.surfaceView = view
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

/// Ordered tab list plus selection for the main window.
@MainActor
final class TabManager: ObservableObject {
    static let shared = TabManager()

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

    private init() {
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(handleNewTab), name: .pigeonNewTab, object: nil)
        center.addObserver(
            self, selector: #selector(handleCloseTab), name: .pigeonCloseTab, object: nil)
        center.addObserver(
            self, selector: #selector(handleGotoTab), name: .pigeonGotoTab, object: nil)

        newTab()
    }

    @discardableResult
    func newTab() -> TerminalTab? {
        guard let app = Ghostty.App.shared.app,
              let tab = TerminalTab(app: app)
        else { return nil }
        // A tab opened while a grouped tab is selected joins that group.
        tab.groupID = selectedTab?.groupID
        tabs.append(tab)
        selectedTabID = tab.id
        return tab
    }

    func close(_ tab: TerminalTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let window = tab.surfaceView.window
        let groupID = tab.groupID
        tabs.remove(at: index)
        removeGroupIfEmpty(groupID)

        if tabs.isEmpty {
            window?.close()
            return
        }
        if selectedTabID == tab.id {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    // MARK: Groups

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
        let previous = tab.groupID
        tab.groupID = group?.id
        removeGroupIfEmpty(previous)
    }

    /// Dissolve a group; members return to the top level.
    func ungroup(_ group: TabGroup) {
        for tab in tabs where tab.groupID == group.id {
            tab.groupID = nil
        }
        groups.removeAll { $0.id == group.id }
    }

    private func removeGroupIfEmpty(_ groupID: TabGroup.ID?) {
        guard let groupID,
              !tabs.contains(where: { $0.groupID == groupID })
        else { return }
        groups.removeAll { $0.id == groupID }
    }

    func select(_ tab: TerminalTab) {
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
        newTab()
    }

    @objc private func handleCloseTab(_ notification: Notification) {
        guard let view = notification.object as? Ghostty.SurfaceView,
              let tab = tab(owning: view)
        else { return }
        close(tab)
    }

    @objc private func handleGotoTab(_ notification: Notification) {
        guard let raw = notification.userInfo?["goto"] as? Int32,
              let current = selectedTab,
              let index = tabs.firstIndex(where: { $0.id == current.id })
        else { return }

        switch ghostty_action_goto_tab_e(raw) {
        case GHOSTTY_GOTO_TAB_PREVIOUS:
            selectedTabID = tabs[(index + tabs.count - 1) % tabs.count].id
        case GHOSTTY_GOTO_TAB_NEXT:
            selectedTabID = tabs[(index + 1) % tabs.count].id
        case GHOSTTY_GOTO_TAB_LAST:
            selectedTabID = tabs.last?.id
        default:
            // Positive values are 1-based tab indices (cmd+1 ... cmd+9).
            let target = Int(raw) - 1
            guard tabs.indices.contains(target) else { return }
            selectedTabID = tabs[target].id
        }
    }
}
