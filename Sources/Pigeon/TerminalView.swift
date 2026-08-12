import SwiftUI
import GhosttyKit

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

private enum DropContainer: Equatable {
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

/// Collapsible group section header.
private struct GroupHeaderRow: View {
    @ObservedObject var group: TabGroup
    let isDropTarget: Bool
    @Binding var editingGroupID: TabGroup.ID?

    @EnvironmentObject private var ghostty: Ghostty.App
    @State private var hovering = false
    @State private var renaming = false
    @State private var draftName = ""
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .rotationEffect(.degrees(group.isExpanded ? 90 : 0))
                .opacity(0.5)

            if renaming {
                TextField("Group Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .focused($renameFieldFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { cancelRename() }
                    .onChange(of: renameFieldFocused) { focused in
                        if !focused && renaming { commitRename() }
                    }
                    .accessibilityIdentifier("renameGroupField")
            } else {
                Text(group.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .padding(.top, 6)
        .foregroundStyle(ghostty.foregroundColor.opacity(hovering ? 0.8 : 0.55))
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill((AppSettings.shared.accentColor ?? Color.accentColor)
                    .opacity(isDropTarget ? 0.25 : 0)))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !renaming else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                TabManager.shared.toggleExpanded(group)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename Group") { startRename() }
            Button("Delete Group") { TabManager.shared.deleteGroup(group) }
        }
        .onAppear {
            // A group created from the blank-area click starts life in
            // name-editing mode.
            if editingGroupID == group.id { startRename() }
        }
    }

    /// True while the group is a fresh, unnamed creation: cancelling the
    /// name edit removes it instead of leaving an anonymous group behind.
    private var isProvisional: Bool {
        editingGroupID == group.id && group.name.isEmpty
    }

    private func startRename() {
        draftName = group.name
        renaming = true
        renameFieldFocused = true
    }

    private func commitRename() {
        guard renaming else { return }
        renaming = false
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            group.name = trimmed
        } else if isProvisional {
            TabManager.shared.deleteGroup(group)
        }
        editingGroupID = nil
    }

    private func cancelRename() {
        renaming = false
        if isProvisional {
            TabManager.shared.deleteGroup(group)
        }
        editingGroupID = nil
    }
}

private struct TabRow: View {
    let tab: TerminalTab
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    let isSelected: Bool
    let isOnlyTab: Bool
    /// Set while the command key is held: shows the ⌘N jump badge.
    let shortcutNumber: Int?

    @EnvironmentObject private var ghostty: Ghostty.App
    @ObservedObject private var tabState: TerminalTab
    @ObservedObject private var settings = AppSettings.shared
    @State private var hovering = false
    @State private var renaming = false
    @State private var draftTitle = ""
    @FocusState private var renameFieldFocused: Bool

    init(
        tab: TerminalTab,
        surfaceView: Ghostty.SurfaceView,
        isSelected: Bool,
        isOnlyTab: Bool,
        shortcutNumber: Int? = nil
    ) {
        self.tab = tab
        self.surfaceView = surfaceView
        self.isSelected = isSelected
        self.isOnlyTab = isOnlyTab
        self.shortcutNumber = shortcutNumber
        self.tabState = tab
    }

    private var displayTitle: String {
        tab.displayTitle
    }

    @State private var showingIconPicker = false

    var body: some View {
        HStack(spacing: 6) {
            if let icon = TabIcon.image(for: tabState.iconCode) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                    .opacity(0.6)
            }

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
                    .help(surfaceView.pwd ?? surfaceView.title)
            }

            if let shortcutNumber {
                Text("⌘\(shortcutNumber)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .opacity(0.55)
            } else if hovering && !isOnlyTab && !renaming {
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
                .fill(selectionFill))
        .contentShape(Rectangle())
        // Single tap only: a double-tap gesture here would force SwiftUI
        // to hold every click for the double-click interval, making tab
        // switching feel laggy. Rename lives in the context menu.
        .onTapGesture { TabManager.shared.select(tab) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename") { startRename() }
            if tabState.customTitle != nil {
                Button("Use Default Title") {
                    tabState.customTitle = nil
                }
            }
            Button("Change Icon…") { showingIconPicker = true }
            Divider()
            Menu("Move to Group") {
                ForEach(TabManager.shared.groups) { group in
                    Button(group.name) {
                        TabManager.shared.assign(tab, to: group)
                    }
                    .disabled(group.id == tabState.groupID)
                }
                if !TabManager.shared.groups.isEmpty { Divider() }
                Button("New Group") {
                    let group = TabManager.shared.createGroup()
                    TabManager.shared.assign(tab, to: group)
                }
                if tabState.groupID != nil {
                    Divider()
                    Button("Remove from Group") {
                        TabManager.shared.assign(tab, to: nil)
                    }
                }
            }
            Divider()
            Button("Close Tab") { TabManager.shared.close(tab) }
                .disabled(isOnlyTab)
        }
        .popover(isPresented: $showingIconPicker, arrowEdge: .trailing) {
            IconPicker(tab: tabState)
        }
    }

    /// Selection uses the user's accent color when set; neutral
    /// foreground tint otherwise.
    private var selectionFill: Color {
        if isSelected {
            if let accent = settings.accentColor { return accent.opacity(0.3) }
            return ghostty.foregroundColor.opacity(0.15)
        }
        return ghostty.foregroundColor.opacity(hovering ? 0.07 : 0)
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

/// Grid of the bundled OpenMoji icons for picking a tab icon.
private struct IconPicker: View {
    @ObservedObject var tab: TerminalTab
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.fixed(28), spacing: 4), count: 8)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(TabIcon.categories) { category in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(category.name)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(category.codes, id: \.self) { code in
                                iconButton(for: code)
                            }
                        }
                    }
                }
            }
            .padding(10)
        }
        .frame(width: 8 * 32 + 20, height: 280)
    }

    private func iconButton(for code: String) -> some View {
        Button {
            tab.iconCode = code
            dismiss()
        } label: {
            Group {
                if let image = TabIcon.image(for: code) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 22, height: 22)
                }
            }
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(tab.iconCode == code
                        ? (AppSettings.shared.accentColor ?? Color.accentColor).opacity(0.3)
                        : Color.clear))
        }
        .buttonStyle(.plain)
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
