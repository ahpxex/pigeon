import SwiftUI

/// One tab row: icon, title (inline-renamable), close button or ⌘N badge.
struct TabRow: View {
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
    @State private var showingIconPicker = false
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
