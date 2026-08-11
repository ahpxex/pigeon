import SwiftUI
import GhosttyKit

/// Root view of the main window: vertical tab sidebar + terminal area,
/// all painted with the terminal's configured background color so the
/// window reads as a single surface.
struct TerminalView: View {
    @EnvironmentObject private var ghostty: Ghostty.App

    var body: some View {
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

private struct TerminalWorkspace: View {
    @EnvironmentObject private var ghostty: Ghostty.App
    @ObservedObject private var tabManager = TabManager.shared

    var body: some View {
        HStack(spacing: 0) {
            TabSidebar()
                .frame(width: 220)

            ZStack {
                ForEach(tabManager.tabs) { tab in
                    TerminalSurface(
                        surfaceView: tab.surfaceView,
                        isActive: tab.id == tabManager.selectedTabID)
                    .opacity(tab.id == tabManager.selectedTabID ? 1 : 0)
                    .allowsHitTesting(tab.id == tabManager.selectedTabID)
                }
            }
            .frame(minWidth: 200, maxWidth: .infinity, minHeight: 100, maxHeight: .infinity)
        }
        .background(ghostty.backgroundColor)
        .ignoresSafeArea()
        .frame(minWidth: 600, minHeight: 400)
    }
}

private struct TabSidebar: View {
    @EnvironmentObject private var ghostty: Ghostty.App
    @ObservedObject private var tabManager = TabManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the traffic-light buttons overlaying the top left.
            Spacer()
                .frame(height: 44)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(tabManager.tabs) { tab in
                        TabRow(
                            tab: tab,
                            surfaceView: tab.surfaceView,
                            isSelected: tab.id == tabManager.selectedTabID,
                            isOnlyTab: tabManager.tabs.count == 1)
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)

            Button {
                tabManager.newTab()
            } label: {
                Label("New Tab", systemImage: "plus")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(chromeForeground.opacity(0.7))
            .padding(8)
            .accessibilityIdentifier("newTabButton")
        }
        .background(chromeOverlay)
    }

    /// Sidebar tint: the terminal background nudged toward its opposite
    /// luminance so the sidebar reads as chrome but stays in-theme.
    private var chromeOverlay: some View {
        Rectangle()
            .fill(chromeForeground.opacity(0.06))
    }

    private var chromeForeground: Color {
        ghostty.foregroundColor
    }
}

private struct TabRow: View {
    let tab: TerminalTab
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    let isSelected: Bool
    let isOnlyTab: Bool

    @EnvironmentObject private var ghostty: Ghostty.App
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .opacity(0.6)

            Text(surfaceView.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if hovering && !isOnlyTab {
                Button {
                    TabManager.shared.close(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(0.6)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("closeTabButton")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(ghostty.foregroundColor.opacity(isSelected ? 1 : 0.6))
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(ghostty.foregroundColor.opacity(
                    isSelected ? 0.15 : (hovering ? 0.07 : 0))))
        .contentShape(Rectangle())
        .onTapGesture { TabManager.shared.select(tab) }
        .onHover { hovering = $0 }
    }
}

/// Bridges a Ghostty.SurfaceView into SwiftUI. The view (and shell
/// process) is owned by TerminalTab; this only mounts it.
struct TerminalSurface: NSViewRepresentable {
    let surfaceView: Ghostty.SurfaceView
    let isActive: Bool

    func makeNSView(context: Context) -> Ghostty.SurfaceView {
        surfaceView
    }

    func updateNSView(_ nsView: Ghostty.SurfaceView, context: Context) {
        guard isActive else { return }
        DispatchQueue.main.async {
            guard let window = nsView.window,
                  window.firstResponder !== nsView
            else { return }
            window.makeFirstResponder(nsView)
        }
    }
}
