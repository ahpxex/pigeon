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
        .background(ghostty.backgroundColor)
        .ignoresSafeArea()
        .frame(minWidth: 400, minHeight: 300)
    }
}

/// Invisible drag strip on the sidebar's trailing edge.
private struct SidebarResizeHandle: View {
    @ObservedObject private var workspace = WorkspaceState.shared
    @State private var dragStartWidth: Double? = nil

    var body: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartWidth == nil {
                            dragStartWidth = workspace.sidebarWidth
                        }
                        let proposed = (dragStartWidth ?? 0) + value.translation.width
                        workspace.sidebarWidth = WorkspaceState.clampWidth(proposed)
                    }
                    .onEnded { value in
                        let proposed = (dragStartWidth ?? 0) + value.translation.width
                        dragStartWidth = nil
                        if proposed < WorkspaceState.collapseThreshold {
                            withAnimation(.easeOut(duration: 0.15)) {
                                workspace.sidebarCollapsed = true
                            }
                        }
                    }
            )
    }
}

private struct TabSidebar: View {
    @EnvironmentObject private var ghostty: Ghostty.App
    @ObservedObject private var tabManager = TabManager.shared

    /// Gesture-driven reordering state. We deliberately avoid the system
    /// drag-and-drop machinery (onDrag/onDrop): it snapshots the row into
    /// a system drag image that animates a fly-back on release, and never
    /// reports drags dropped outside a delegate — both caused visible
    /// ghosting. A plain DragGesture keeps everything in-process.
    @State private var draggingTabID: TerminalTab.ID? = nil
    @State private var dragTranslation: CGFloat = 0
    @State private var dragTargetIndex: Int? = nil
    @State private var rowSlotHeight: CGFloat = 29

    private let rowSpacing: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the traffic-light buttons overlaying the top left.
            Spacer()
                .frame(height: 44)

            ScrollView {
                VStack(spacing: rowSpacing) {
                    ForEach(tabManager.tabs) { tab in
                        TabRow(
                            tab: tab,
                            surfaceView: tab.surfaceView,
                            isSelected: tab.id == tabManager.selectedTabID,
                            isOnlyTab: tabManager.tabs.count == 1)
                        .background(rowHeightReader)
                        .offset(y: rowOffset(for: tab))
                        .zIndex(draggingTabID == tab.id ? 1 : 0)
                        .shadow(
                            color: .black.opacity(draggingTabID == tab.id ? 0.3 : 0),
                            radius: 4, y: 2)
                        // High priority so the row wins drags over the
                        // ScrollView; trackpad/wheel scrolling is a separate
                        // event type on macOS and keeps working.
                        .highPriorityGesture(reorderGesture(for: tab))
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)

            HStack(spacing: 0) {
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
                .accessibilityIdentifier("newTabButton")

                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        WorkspaceState.shared.toggleSidebar()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12))
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide Sidebar (⌥⌘S)")
                .accessibilityIdentifier("collapseSidebarButton")
            }
            .foregroundStyle(chromeForeground.opacity(0.7))
            .padding(8)
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

    // MARK: Reordering

    /// Rows are uniform height; measure the first one so slot math stays
    /// correct across font/OS changes.
    private var rowHeightReader: some View {
        GeometryReader { geo in
            Color.clear.onAppear { rowSlotHeight = geo.size.height }
        }
    }

    private var slotHeight: CGFloat { rowSlotHeight + rowSpacing }

    private func reorderGesture(for tab: TerminalTab) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard let from = tabManager.tabs.firstIndex(where: { $0.id == tab.id })
                else { return }
                if draggingTabID == nil {
                    draggingTabID = tab.id
                    dragTargetIndex = from
                }
                dragTranslation = value.translation.height

                let slots = Int((dragTranslation / slotHeight).rounded())
                let target = max(0, min(tabManager.tabs.count - 1, from + slots))
                if target != dragTargetIndex {
                    withAnimation(.easeOut(duration: 0.12)) {
                        dragTargetIndex = target
                    }
                }
            }
            .onEnded { _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    if let id = draggingTabID,
                       let target = dragTargetIndex {
                        tabManager.move(tabID: id, toIndex: target)
                    }
                    draggingTabID = nil
                    dragTranslation = 0
                    dragTargetIndex = nil
                }
            }
    }

    /// The dragged row follows the pointer; rows between the original and
    /// target positions slide one slot out of the way.
    private func rowOffset(for tab: TerminalTab) -> CGFloat {
        guard let dragID = draggingTabID,
              let from = tabManager.tabs.firstIndex(where: { $0.id == dragID }),
              let target = dragTargetIndex
        else { return 0 }

        if tab.id == dragID { return dragTranslation }

        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tab.id })
        else { return 0 }
        if from < index && index <= target { return -slotHeight }
        if target <= index && index < from { return slotHeight }
        return 0
    }
}

private struct TabRow: View {
    let tab: TerminalTab
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    let isSelected: Bool
    let isOnlyTab: Bool

    @EnvironmentObject private var ghostty: Ghostty.App
    @ObservedObject private var tabState: TerminalTab
    @State private var hovering = false
    @State private var renaming = false
    @State private var draftTitle = ""
    @FocusState private var renameFieldFocused: Bool

    init(tab: TerminalTab, surfaceView: Ghostty.SurfaceView, isSelected: Bool, isOnlyTab: Bool) {
        self.tab = tab
        self.surfaceView = surfaceView
        self.isSelected = isSelected
        self.isOnlyTab = isOnlyTab
        self.tabState = tab
    }

    private var displayTitle: String {
        tabState.customTitle ?? surfaceView.title
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .opacity(0.6)

            if renaming {
                TextField("", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($renameFieldFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { cancelRename() }
                    .onChange(of: renameFieldFocused) { focused in
                        // Clicking elsewhere commits, like Finder.
                        if !focused && renaming { commitRename() }
                    }
                    .accessibilityIdentifier("renameTabField")
            } else {
                Text(displayTitle)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if hovering && !isOnlyTab && !renaming {
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
        // Single tap only: a double-tap gesture here would force SwiftUI
        // to hold every click for the double-click interval, making tab
        // switching feel laggy. Rename lives in the context menu.
        .onTapGesture { TabManager.shared.select(tab) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename") { startRename() }
            if tabState.customTitle != nil {
                Button("Use Shell Title") {
                    tabState.customTitle = nil
                }
            }
            Divider()
            Button("Close Tab") { TabManager.shared.close(tab) }
                .disabled(isOnlyTab)
        }
    }

    private func startRename() {
        draftTitle = displayTitle
        renaming = true
        renameFieldFocused = true
    }

    private func commitRename() {
        guard renaming else { return }
        renaming = false
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        tabState.customTitle = trimmed.isEmpty ? nil : trimmed
        returnFocusToTerminal()
    }

    private func cancelRename() {
        renaming = false
        returnFocusToTerminal()
    }

    private func returnFocusToTerminal() {
        guard isSelected else { return }
        DispatchQueue.main.async {
            surfaceView.window?.makeFirstResponder(surfaceView)
        }
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
