import SwiftUI

/// Grid of the bundled OpenMoji icons for picking a tab icon,
/// sectioned by category.
struct IconPicker: View {
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
