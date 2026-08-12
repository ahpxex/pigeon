import SwiftUI

/// Collapsible group section header.
struct GroupHeaderRow: View {
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
            // A group created from the blank-area menu starts life in
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
