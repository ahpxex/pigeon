import AppKit
import Combine
import GhosttyKit

/// One terminal tab. Owns its surface view (and therefore the shell
/// process) for the tab's whole lifetime, whether or not it is visible.
final class TerminalTab: Identifiable, ObservableObject {
    let id = UUID()
    let surfaceView: Ghostty.SurfaceView

    init?(app: ghostty_app_t) {
        let view = Ghostty.SurfaceView(app: app)
        guard view.surface != nil else { return nil }
        self.surfaceView = view
    }
}

/// Ordered tab list plus selection for the main window.
@MainActor
final class TabManager: ObservableObject {
    static let shared = TabManager()

    @Published private(set) var tabs: [TerminalTab] = []
    @Published var selectedTabID: TerminalTab.ID?

    var selectedTab: TerminalTab? {
        tabs.first { $0.id == selectedTabID }
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
        tabs.append(tab)
        selectedTabID = tab.id
        return tab
    }

    func close(_ tab: TerminalTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let window = tab.surfaceView.window
        tabs.remove(at: index)

        if tabs.isEmpty {
            window?.close()
            return
        }
        if selectedTabID == tab.id {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    func select(_ tab: TerminalTab) {
        selectedTabID = tab.id
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
