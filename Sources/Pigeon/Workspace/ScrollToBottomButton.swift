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
        ZStack {
            if visible {
                Button {
                    tab.surfaceView.scrollToBottom()
                } label: {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.75))
                        .padding(7)
                        .background(.regularMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
                }
                .buttonStyle(.plain)
                .help("Scroll to bottom")
                .transition(.opacity)
            }
            Color.clear  // Keeps the view non-empty so onAppear fires.
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 14)
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
