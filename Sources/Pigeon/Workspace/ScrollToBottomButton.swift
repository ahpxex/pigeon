import AppKit
import SwiftUI

/// Floating "scroll to bottom" pill over a tab's terminal: appears
/// whenever the viewport isn't at the live bottom (user scrolled up, or
/// a message-history jump landed mid-scrollback), disappears at the
/// bottom. Clicking scrolls back down. One instance per tab, overlaid
/// on the terminal area.
struct ScrollToBottomButton: View {
    @ObservedObject var tab: TerminalTab
    @State private var visible = false
    @State private var sampler: Timer?

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if visible {
                Button {
                    tab.surfaceView.scrollToBottom()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.down.2")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Jump to latest")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.primary.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Scroll to bottom")
                .transition(.opacity)
            }
            // Non-empty content keeps onAppear firing (an empty Group
            // in an overlay never appears).
            Color.clear.frame(height: 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(visible)
        .onAppear { startSampling() }
        .onDisappear { sampler?.invalidate(); sampler = nil }
        .animation(.easeOut(duration: 0.15), value: visible)
    }

    /// Poll the scroll position while this tab's surface is visible —
    /// cheap (two small text dumps every 0.5s) and entirely local; the
    /// kernel has no scroll-position callback to subscribe to.
    private func startSampling() {
        sampler?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                let atBottom = tab.surfaceView.isScrolledToBottom()
                if atBottom != !visible { visible = !atBottom }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sampler = timer
    }
}
