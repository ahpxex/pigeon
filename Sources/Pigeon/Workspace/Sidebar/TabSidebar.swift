import SwiftUI

/// The vertical tab list: ungrouped tabs, then collapsible groups.
/// Also owns the gesture-driven reorder / move-to-group logic.
struct TabSidebar: View {
    @EnvironmentObject private var ghostty: Ghostty.App
    @EnvironmentObject private var tabManager: TabManager
    @EnvironmentObject private var workspace: WorkspaceState

    /// Gesture-driven reordering state. We deliberately avoid the system
    /// drag-and-drop machinery (onDrag/onDrop): it snapshots the row into
    /// a system drag image that animates a fly-back on release, and never
    /// reports drags dropped outside a delegate — both caused visible
    /// ghosting. A plain DragGesture keeps everything in-process.
    @State private var draggingTabID: TerminalTab.ID? = nil
    @State private var dragTranslation: CGFloat = 0
    @State private var dragTargetIndex: Int? = nil
    @State private var rowSlotHeight: CGFloat = 29

    /// Container the pointer is hovering during a drag, when it differs
    /// from the dragged tab's own container.
    @State private var dropContainer: DropContainer = .none

    /// Measured row frames in the "sidebarList" space, for hit-testing
    /// drags across containers.
    @State private var rowFrames: [SidebarRowKey: CGRect] = [:]

    /// Group whose name is being edited because it was just created.
    @State private var editingGroupID: TabGroup.ID? = nil

    /// True while the command key is down: rows show their ⌘N jump badge.
    @State private var commandHeld = false
    @State private var flagsMonitor: Any? = nil

    private let rowSpacing: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the traffic-light buttons overlaying the top left.
            Spacer()
                .frame(height: 44)

            GeometryReader { viewport in
                ScrollView {
                    VStack(spacing: 0) {
                        VStack(spacing: rowSpacing) {
                            ForEach(tabManager.ungroupedTabs) { tab in
                                decoratedRow(for: tab)
                            }
                            ForEach(tabManager.groups) { group in
                                GroupHeaderRow(
                                    group: group,
                                    isDropTarget: dropContainer == .group(group.id),
                                    editingGroupID: $editingGroupID)
                                .background(frameReader(for: .header(group.id)))
                                if group.isExpanded {
                                    ForEach(tabManager.tabs(in: group)) { tab in
                                        decoratedRow(for: tab)
                                            .padding(.leading, 14)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 8)

                        // Blank space below the rows: right-click for the
                        // sidebar menu. New groups name themselves inline;
                        // cancelling the name removes the group again.
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button("New Group") {
                                    let group = tabManager.createGroup(named: "")
                                    editingGroupID = group.id
                                }
                                Button("New Tab") {
                                    tabManager.newTab()
                                }
                            }
                            .accessibilityIdentifier("sidebarBlankArea")
                    }
                    .frame(minHeight: viewport.size.height, alignment: .top)
                }
            }
            .coordinateSpace(name: "sidebarList")
            .onPreferenceChange(SidebarRowFramesKey.self) { rowFrames = $0 }
            .onAppear {
                flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    commandHeld = event.modifierFlags.contains(.command)
                    return event
                }
            }
            .onDisappear {
                if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
                flagsMonitor = nil
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
                        workspace.toggleSidebar()
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

    /// 1-based ⌘N badge position (visual order), only for the first 9.
    private func shortcutNumber(for tab: TerminalTab) -> Int? {
        guard let index = tabManager.visualOrderedTabs.firstIndex(where: { $0.id == tab.id }),
              index < 9
        else { return nil }
        return index + 1
    }

    @ViewBuilder
    private func decoratedRow(for tab: TerminalTab) -> some View {
        TabRow(
            tab: tab,
            surfaceView: tab.surfaceView,
            isSelected: tab.id == tabManager.selectedTabID,
            isOnlyTab: tabManager.tabs.count == 1,
            shortcutNumber: commandHeld ? shortcutNumber(for: tab) : nil)
        .background(rowHeightReader)
        .background(frameReader(for: .tab(tab.id)))
        .offset(y: rowOffset(for: tab))
        .zIndex(draggingTabID == tab.id ? 1 : 0)
        .shadow(
            color: .black.opacity(draggingTabID == tab.id ? 0.3 : 0),
            radius: 4, y: 2)
        // High priority so the row wins drags over the ScrollView;
        // trackpad/wheel scrolling is a separate event type on macOS
        // and keeps working.
        .highPriorityGesture(reorderGesture(for: tab))
    }

    /// Rows are uniform height; measure the first one so slot math stays
    /// correct across font/OS changes.
    private var rowHeightReader: some View {
        GeometryReader { geo in
            Color.clear.onAppear { rowSlotHeight = geo.size.height }
        }
    }

    private func frameReader(for key: SidebarRowKey) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: SidebarRowFramesKey.self,
                value: [key: geo.frame(in: .named("sidebarList"))])
        }
    }

    private var slotHeight: CGFloat { rowSlotHeight + rowSpacing }

    /// In-container reordering uses slot math; hovering another container
    /// (group rows, group header, or the top-level region) turns the drag
    /// into a move-into-container instead.
    private func containerMembers(of tab: TerminalTab) -> [TerminalTab] {
        tabManager.tabs.filter { $0.groupID == tab.groupID }
    }

    /// Which container the given point (in sidebarList space) is over.
    private func container(at point: CGPoint) -> DropContainer {
        for group in tabManager.groups {
            if let frame = rowFrames[.header(group.id)], frame.contains(point) {
                return .group(group.id)
            }
        }
        for tab in tabManager.tabs {
            if let frame = rowFrames[.tab(tab.id)], frame.contains(point) {
                if let groupID = tab.groupID { return .group(groupID) }
                return .topLevel
            }
        }
        return .none
    }

    private func dropContainer(for tab: TerminalTab, at point: CGPoint) -> DropContainer {
        let hovered = container(at: point)
        switch hovered {
        case .none:
            return .none
        case .topLevel:
            return tab.groupID == nil ? .none : .topLevel
        case .group(let id):
            return tab.groupID == id ? .none : .group(id)
        }
    }

    private func reorderGesture(for tab: TerminalTab) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("sidebarList"))
            .onChanged { value in
                let members = containerMembers(of: tab)
                guard let from = members.firstIndex(where: { $0.id == tab.id })
                else { return }
                if draggingTabID == nil {
                    draggingTabID = tab.id
                    dragTargetIndex = from
                }
                dragTranslation = value.translation.height

                let newDrop = dropContainer(for: tab, at: value.location)
                let slots = Int((dragTranslation / slotHeight).rounded())
                // While hovering a foreign container, container-mates stay
                // put (no slot preview) — the group header highlights.
                let target = newDrop == .none
                    ? max(0, min(members.count - 1, from + slots))
                    : from
                if target != dragTargetIndex || newDrop != dropContainer {
                    withAnimation(.easeOut(duration: 0.12)) {
                        dragTargetIndex = target
                        dropContainer = newDrop
                    }
                }
            }
            .onEnded { _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    if let id = draggingTabID,
                       let dragged = tabManager.tabs.first(where: { $0.id == id }) {
                        switch dropContainer {
                        case .group(let groupID):
                            if let group = tabManager.groups.first(where: { $0.id == groupID }) {
                                tabManager.assign(dragged, to: group)
                                tabManager.setExpanded(group, expanded: true)
                            }
                        case .topLevel:
                            tabManager.assign(dragged, to: nil)
                        case .none:
                            if let target = dragTargetIndex {
                                tabManager.move(tabID: id, toContainerIndex: target)
                            }
                        }
                    }
                    draggingTabID = nil
                    dragTranslation = 0
                    dragTargetIndex = nil
                    dropContainer = .none
                }
            }
    }

    /// The dragged row follows the pointer; container-mates between the
    /// original and target positions slide one slot out of the way.
    private func rowOffset(for tab: TerminalTab) -> CGFloat {
        guard let dragID = draggingTabID,
              let dragged = tabManager.tabs.first(where: { $0.id == dragID })
        else { return 0 }

        if tab.id == dragID { return dragTranslation }

        // Only rows in the same container react.
        guard tab.groupID == dragged.groupID,
              let target = dragTargetIndex
        else { return 0 }

        let members = containerMembers(of: dragged)
        guard let from = members.firstIndex(where: { $0.id == dragID }),
              let index = members.firstIndex(where: { $0.id == tab.id })
        else { return 0 }
        if from < index && index <= target { return -slotHeight }
        if target <= index && index < from { return slotHeight }
        return 0
    }
}

/// Identifies measurable sidebar rows for drag hit-testing.
private enum SidebarRowKey: Hashable {
    case tab(TerminalTab.ID)
    case header(TabGroup.ID)
}

enum DropContainer: Equatable {
    case none
    case topLevel
    case group(TabGroup.ID)
}

private struct SidebarRowFramesKey: PreferenceKey {
    static var defaultValue: [SidebarRowKey: CGRect] = [:]
    static func reduce(value: inout [SidebarRowKey: CGRect], nextValue: () -> [SidebarRowKey: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Invisible drag strip on the sidebar's trailing edge.
struct SidebarResizeHandle: View {
    @EnvironmentObject private var workspace: WorkspaceState
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
