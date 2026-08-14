import AppKit
import Combine
import SwiftUI

/// Reaches the hosting NSWindow to do the AppKit-side work SwiftUI can't
/// express: confirm-before-close while a process is running, the initial
/// window size requested by the terminal (window-width/height in cells),
/// and resize increments so window resizing snaps to the character grid.
struct WindowBridge: NSViewRepresentable {
    @ObservedObject var tabManager: TabManager

    func makeCoordinator() -> Coordinator {
        Coordinator(tabManager: tabManager)
    }

    func makeNSView(context: Context) -> BridgeHostView {
        let view = BridgeHostView()
        // viewDidMoveToWindow is the deterministic attach point; the
        // update pass below re-checks in case SwiftUI swaps the delegate.
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: BridgeHostView, context: Context) {
        DispatchQueue.main.async { context.coordinator.attach(to: nsView.window) }
    }

    final class BridgeHostView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }

    @MainActor
    final class Coordinator {
        private let tabManager: TabManager
        private weak var window: NSWindow?
        private let delegateProxy = WindowDelegateProxy()
        private var cancellables: Set<AnyCancellable> = []
        private var surfaceCancellables: Set<AnyCancellable> = []
        private var appliedInitialSize = false

        init(tabManager: TabManager) {
            self.tabManager = tabManager
            delegateProxy.tabManager = tabManager
            tabManager.$selectedTabID
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.observeSelectedSurface() }
                .store(in: &cancellables)
        }

        func attach(to window: NSWindow?) {
            guard let window else { return }
            if self.window !== window {
                self.window = window
                appliedInitialSize = false
            }
            // The manager needs its window for key-window resolution
            // (menu items and the driver act on the frontmost manager).
            tabManager.window = window

            // SwiftUI owns the window delegate; interpose a forwarding
            // proxy so we get windowShouldClose without losing the rest.
            // Reinstalled here every pass in case SwiftUI swaps it back.
            if window.delegate !== delegateProxy {
                delegateProxy.forward = window.delegate
                window.delegate = delegateProxy
            }

            observeSelectedSurface()
            applyInitialSizeIfReady()
        }

        /// Track the active tab's surface for cell size changes (font or
        /// scale factor changes retrigger the CELL_SIZE action).
        private func observeSelectedSurface() {
            surfaceCancellables.removeAll()
            guard let tab = tabManager.selectedTab else { return }
            tab.surfaceView.$cellSize
                .receive(on: DispatchQueue.main)
                .sink { [weak self] size in self?.applyResizeIncrements(size) }
                .store(in: &surfaceCancellables)

            // The initial size and the surface's first layout can each
            // arrive after the window attaches; watch both until applied.
            if !appliedInitialSize, let first = tabManager.tabs.first {
                first.surfaceView.$initialSize
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in self?.applyInitialSizeIfReady() }
                    .store(in: &surfaceCancellables)
                first.surfaceView.publisher(for: \.frame)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in self?.applyInitialSizeIfReady() }
                    .store(in: &surfaceCancellables)
            }
        }

        private func applyResizeIncrements(_ cellSize: NSSize) {
            guard let window, cellSize.width > 0, cellSize.height > 0 else { return }
            window.contentResizeIncrements = cellSize
        }

        /// Size the window so the first surface gets its requested grid.
        /// Applied once per window, only when the surface has been laid
        /// out (we measure the chrome around it from the live layout).
        private func applyInitialSizeIfReady() {
            guard !appliedInitialSize,
                  let window,
                  let content = window.contentView,
                  let view = tabManager.tabs.first?.surfaceView,
                  view.window === window,
                  view.frame.width > 0, view.frame.height > 0,
                  let size = view.initialSize
            else { return }
            appliedInitialSize = true

            let chrome = NSSize(
                width: content.frame.width - view.frame.width,
                height: content.frame.height - view.frame.height)
            var target = NSSize(
                width: size.width + chrome.width,
                height: size.height + chrome.height)
            if let screen = window.screen ?? NSScreen.main {
                target.width = min(target.width, screen.visibleFrame.width)
                target.height = min(target.height, screen.visibleFrame.height)
            }
            window.setContentSize(target)
        }
    }
}

/// NSWindowDelegate interposer: forwards everything to SwiftUI's own
/// delegate but takes over windowShouldClose to confirm when a terminal
/// in the window still runs a process.
final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    weak var forward: NSWindowDelegate?
    weak var tabManager: TabManager?
    private var allowClose = false

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (forward?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let forward, forward.responds(to: aSelector) { return forward }
        return super.forwardingTarget(for: aSelector)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // SwiftUI's delegate keeps its veto.
        if let forward,
           forward.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))),
           forward.windowShouldClose?(sender) == false {
            return false
        }

        guard let tabManager else { return true }
        if allowClose || !tabManager.needsConfirmClose {
            // The window is going away: release the tabs (and shells) now
            // so app-quit confirmation doesn't ask about them again.
            tabManager.terminateAllTabs()
            return true
        }

        CloseConfirmation.present(
            on: sender,
            message: "Close Window?",
            detail: "A terminal in this window still has a running process. "
                + "Closing the window will kill it.",
            confirmTitle: "Close Window"
        ) { [weak self, weak sender] in
            guard let self else { return }
            // close() skips windowShouldClose, so release the tabs here —
            // otherwise quit confirmation would ask about them again.
            self.tabManager?.terminateAllTabs()
            self.allowClose = true
            sender?.close()
        }
        return false
    }
}
