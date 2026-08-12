import Foundation
import Combine

/// UI state for the main window that persists across launches.
@MainActor
final class WorkspaceState: ObservableObject {
    static let shared = WorkspaceState()

    static let minSidebarWidth: Double = 160
    static let maxSidebarWidth: Double = 420
    /// Dragging narrower than this collapses the sidebar.
    static let collapseThreshold: Double = 120

    @Published var sidebarCollapsed: Bool {
        didSet { defaults.set(sidebarCollapsed, forKey: "sidebarCollapsed") }
    }

    @Published var sidebarWidth: Double {
        didSet { defaults.set(sidebarWidth, forKey: "sidebarWidth") }
    }

    private let defaults = UserDefaults.standard

    private init() {
        sidebarCollapsed = defaults.bool(forKey: "sidebarCollapsed")
        let width = defaults.double(forKey: "sidebarWidth")
        sidebarWidth = width == 0 ? 220 : Self.clampWidth(width)
    }

    func toggleSidebar() {
        sidebarCollapsed.toggle()
    }

    nonisolated static func clampWidth(_ width: Double) -> Double {
        min(max(width, minSidebarWidth), maxSidebarWidth)
    }
}
