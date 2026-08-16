import SwiftUI
import GhosttyKit

/// Root view of the main window: vertical tab sidebar + terminal area,
/// all painted with the terminal's configured background color so the
/// window reads as a single surface.
struct TerminalView: View {
    @EnvironmentObject private var ghostty: Ghostty.App

    var body: some View {
        content
            .background(SettingsOpener())
            .background(NewWindowBridge())
    }

    @ViewBuilder
    private var content: some View {
        switch ghostty.readiness {
        case .loading:
            ProgressView()
                .frame(minWidth: 400, minHeight: 300)
        case .error(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                Text("libghostty failed to start")
                    .font(.headline)
                Text(message)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 400, minHeight: 300)
            .padding()
        case .ready:
            TerminalWorkspace()
        }
    }
}

/// Owns one window's tab manager (and through it the window's sidebar
/// state). Instantiated per WindowGroup scene, so every window gets its
/// own set of tabs.
struct TerminalWorkspace: View {
    @StateObject private var tabManager = TabManager()

    var body: some View {
        WorkspaceLayout(tabManager: tabManager, workspace: tabManager.workspace)
            .environmentObject(tabManager)
            .environmentObject(tabManager.workspace)
    }
}

private struct WorkspaceLayout: View {
    @EnvironmentObject private var ghostty: Ghostty.App
    @ObservedObject var tabManager: TabManager
    @ObservedObject var workspace: WorkspaceState

    var body: some View {
        HStack(spacing: 0) {
            if !workspace.sidebarCollapsed {
                TabSidebar()
                    .frame(width: workspace.sidebarWidth)
                    .overlay(alignment: .trailing) { SidebarResizeHandle() }
                    .transition(.move(edge: .leading))
            }

            ZStack {
                ForEach(tabManager.tabs) { tab in
                    ZStack {
                        TerminalSurface(
                            surfaceView: tab.surfaceView,
                            isActive: tab.id == tabManager.selectedTabID)
                        // Highlights share the surface's coordinate space;
                        // the ZStack keeps them aligned exactly.
                        SearchHighlights(model: tab.search)
                    }
                    .overlay(alignment: .topTrailing) {
                        TabSearchBar(search: tab.search)
                    }
                    .opacity(tab.id == tabManager.selectedTabID ? 1 : 0)
                    .allowsHitTesting(tab.id == tabManager.selectedTabID)
                }
            }
            // Breathing room between the text grid and the window edges;
            // the padding shows the same background so it stays seamless.
            // With the sidebar collapsed the traffic lights float over the
            // terminal, so push the first line below them.
            .padding(EdgeInsets(
                top: workspace.sidebarCollapsed ? 40 : 14,
                leading: workspace.sidebarCollapsed ? 12 : 10,
                bottom: 0,
                trailing: 12))
            .frame(minWidth: 200, maxWidth: .infinity, minHeight: 100, maxHeight: .infinity)
        }
        .overlay(alignment: .topLeading) {
            if workspace.sidebarCollapsed {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        workspace.toggleSidebar()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13))
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(ghostty.foregroundColor.opacity(0.5))
                // Clear of the traffic lights on the left.
                .padding(.leading, 82)
                .padding(.top, 6)
                .accessibilityIdentifier("expandSidebarButton")
            }
        }
        .overlay(alignment: .top) {
            // Active tab identity, centered like a native window title.
            if workspace.sidebarCollapsed, let tab = tabManager.selectedTab {
                CollapsedTabTitle(tab: tab, surfaceView: tab.surfaceView)
                    .padding(.top, 11)
            }
        }
        .background(ghostty.backgroundColor.opacity(ghostty.backgroundOpacity))
        .background(WindowTransparencyConfigurator(opacity: ghostty.backgroundOpacity))
        .background(WindowBridge(tabManager: tabManager))
        .ignoresSafeArea()
        .frame(minWidth: 400, minHeight: 300)
    }
}

/// Find bar for one tab, shown only while its search is open.
private struct TabSearchBar: View {
    @ObservedObject var search: TerminalSearchModel

    var body: some View {
        if search.isOpen {
            SearchBar(model: search)
        }
    }
}

/// Active tab identity shown in the header strip while the sidebar is
/// collapsed: the tab's OpenMoji icon plus its display title (which
/// follows the user's label-style setting, folder name or full path).
private struct CollapsedTabTitle: View {
    @ObservedObject var tab: TerminalTab
    @ObservedObject var surfaceView: Ghostty.SurfaceView

    @EnvironmentObject private var ghostty: Ghostty.App
    // displayTitle depends on the label-style setting; observe it so the
    // header follows changes live like the sidebar rows do.
    @ObservedObject private var settings = AppSettings.shared

    init(tab: TerminalTab, surfaceView: Ghostty.SurfaceView) {
        self.tab = tab
        self.surfaceView = surfaceView
    }

    var body: some View {
        HStack(spacing: 6) {
            if let icon = TabIcon.image(for: tab.iconCode) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 15, height: 15)
            }
            Text(tab.displayTitle)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(ghostty.foregroundColor.opacity(0.6))
        }
        .frame(maxWidth: 380)
        .help(surfaceView.pwd ?? surfaceView.title)
        .accessibilityIdentifier("collapsedTabTitle")
    }
}

/// background-opacity < 1 needs the NSWindow itself to be non-opaque;
/// SwiftUI has no API for that, so reach the window through a hosted view.
private struct WindowTransparencyConfigurator: NSViewRepresentable {
    let opacity: Double

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        let translucent = opacity < 0.999
        if window.isOpaque == translucent {
            window.isOpaque = !translucent
            window.backgroundColor = translucent ? .clear : nil
            window.invalidateShadow()
        }
    }
}

/// Invisible bridge that exposes SwiftUI's openWindow action to AppKit
/// land (ghostty's new_window action, the driver). Every window hosts
/// one; the shared claim set makes exactly one act per request.
private struct NewWindowBridge: View {
    @Environment(\.openWindow) private var openWindow
    @MainActor private static var claimed = Set<UUID>()

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .pigeonNewWindow)) { note in
                guard let id = note.userInfo?["id"] as? UUID,
                      !Self.claimed.contains(id)
                else { return }
                Self.claimed.insert(id)
                openWindow(id: "main")
            }
    }
}

/// Invisible bridge that exposes SwiftUI's openSettings action to AppKit
/// land (ghostty actions, the driver) via a notification.
private struct SettingsOpener: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsOpenerModern()
        } else {
            Color.clear
                .frame(width: 0, height: 0)
                .onReceive(NotificationCenter.default.publisher(for: .pigeonOpenSettings)) { _ in
                    _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
        }
    }
}

@available(macOS 14.0, *)
private struct SettingsOpenerModern: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .pigeonOpenSettings)) { _ in
                openSettings()
            }
    }
}
