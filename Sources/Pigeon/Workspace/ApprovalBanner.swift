import SwiftUI

/// A coding agent in this tab asks to run a tool and Pigeon holds the
/// request (PermissionBroker, while Remote Control is on). Answer here,
/// remotely with `pigeon approve`, or hand it back to the agent's own
/// prompt. Floats at the top so it never covers the agent's own dialog
/// at the bottom of the screen (Claude Code keeps showing it meanwhile).
///
/// Buttons only, no keyboard shortcuts: the terminal keeps keyboard
/// focus, and Enter must keep going to the terminal.
struct ApprovalBanner: View {
    let surfaceID: String
    @ObservedObject private var broker = PermissionBroker.shared

    var body: some View {
        let requests = broker.requests(for: surfaceID)
        if let request = requests.first {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(.orange)
                    Text("\(agentName(request.source)) wants to use \(request.tool)")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if requests.count > 1 {
                        Text("+\(requests.count - 1) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !request.summary.isEmpty {
                    Text(request.summary)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.06)))
                }
                if let description = request.description {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Deny") {
                        broker.resolve(id: request.id, decision: .deny(reason: nil), by: .pigeon)
                    }
                    Button("Answer in Terminal") {
                        broker.resolve(id: request.id, decision: .release, by: .pigeon)
                    }
                    .help("Hand the question back to the agent's own prompt")
                    Spacer()
                    Text(request.id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .help("Remote: pigeon approve \(request.id)")
                    Button("Allow") {
                        broker.resolve(id: request.id, decision: .allow, by: .pigeon)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.5)))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
            .padding(.top, 8)
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityIdentifier("approvalBanner")
        }
    }

    private func agentName(_ source: String) -> String {
        ActivityHooks.Source(rawValue: source)?.displayName ?? "The agent"
    }
}
