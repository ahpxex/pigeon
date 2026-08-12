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

struct TerminalWorkspace: View {
    @EnvironmentObject private var ghostty: Ghostty.App
    @ObservedObject private var tabManager = TabManager.shared
    @ObservedObject private var workspace = WorkspaceState.shared

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
                    TerminalSurface(
                        surfaceView: tab.surfaceView,
                        isActive: tab.id == tabManager.selectedTabID)
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
        .background(ghostty.backgroundColor.opacity(ghostty.backgroundOpacity))
        .background(WindowTransparencyConfigurator(opacity: ghostty.backgroundOpacity))
        .ignoresSafeArea()
        .frame(minWidth: 400, minHeight: 300)
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
