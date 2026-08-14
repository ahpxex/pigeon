import Foundation
import Combine

/// Sidebar state for one terminal window. Persisted app-wide (last
/// write wins), so new windows inherit the most recent layout.
@MainActor
final class WorkspaceState: ObservableObject {
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

    init() {
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
