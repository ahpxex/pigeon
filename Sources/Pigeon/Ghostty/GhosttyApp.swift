import AppKit
import Combine
import GhosttyKit
import SwiftUI

extension Notification.Name {
    /// Request a new tab. Object is the originating SurfaceView (may be nil).
    static let pigeonNewTab = Notification.Name("pigeonNewTab")
    /// Request closing the tab that owns the SurfaceView in object.
    static let pigeonCloseTab = Notification.Name("pigeonCloseTab")
    /// Switch tabs. Object is the originating SurfaceView, userInfo["goto"]
    /// is a ghostty_action_goto_tab_e raw value.
    static let pigeonGotoTab = Notification.Name("pigeonGotoTab")
}

extension Ghostty {
    /// Owns the libghostty app instance: configuration, the runtime
    /// callbacks, and the tick loop. One per process.
    final class App: ObservableObject {
        static let shared = App()

        enum Readiness {
            case loading
            case error(String)
            case ready
        }

        @Published private(set) var readiness: Readiness = .loading

        private(set) var app: ghostty_app_t?
        private(set) var config: ghostty_config_t?

        private init() {
            guard Ghostty.initialized else {
                readiness = .error("ghostty_init failed")
                return
            }

            // Load configuration from the standard Ghostty locations
            // (e.g. ~/.config/ghostty/config). Pigeon reuses Ghostty's
            // configuration format.
            guard let config = ghostty_config_new() else {
                readiness = .error("ghostty_config_new failed")
                return
            }
            ghostty_config_load_default_files(config)
            ghostty_config_finalize(config)
            self.config = config

            var runtime = ghostty_runtime_config_s(
                userdata: Unmanaged.passUnretained(self).toOpaque(),
                supports_selection_clipboard: false,
                wakeup_cb: { userdata in App.wakeup(userdata) },
                action_cb: { app, target, action in App.action(app, target: target, action: action) },
                read_clipboard_cb: { userdata, location, state in
                    App.readClipboard(userdata, location: location, state: state)
                },
                confirm_read_clipboard_cb: { userdata, string, state, request in
                    App.confirmReadClipboard(userdata, string: string, state: state, request: request)
                },
                write_clipboard_cb: { userdata, string, location, confirm in
                    App.writeClipboard(userdata, string: string, location: location, confirm: confirm)
                },
                close_surface_cb: { userdata, processAlive in
                    App.closeSurface(userdata, processAlive: processAlive)
                }
            )

            guard let app = ghostty_app_new(&runtime, config) else {
                readiness = .error("ghostty_app_new failed")
                return
            }
            self.app = app

            // NSApp may not exist yet when we're constructed from the SwiftUI
            // App initializer; NSApplication.shared creates it on demand.
            ghostty_app_set_focus(app, NSApplication.shared.isActive)
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(applicationDidBecomeActive),
                name: NSApplication.didBecomeActiveNotification,
                object: nil)
            center.addObserver(
                self,
                selector: #selector(applicationDidResignActive),
                name: NSApplication.didResignActiveNotification,
                object: nil)

            readiness = .ready
        }

        /// The configured terminal background color. Drives the window
        /// chrome so the whole window reads as one surface.
        var backgroundColor: Color {
            var color = ghostty_config_color_s()
            let key = "background"
            guard let config,
                  ghostty_config_get(config, &color, key, UInt(key.count))
            else { return Color(nsColor: .windowBackgroundColor) }
            return Color(
                red: Double(color.r) / 255,
                green: Double(color.g) / 255,
                blue: Double(color.b) / 255)
        }

        /// The configured foreground color, for chrome text.
        var foregroundColor: Color {
            var color = ghostty_config_color_s()
            let key = "foreground"
            guard let config,
                  ghostty_config_get(config, &color, key, UInt(key.count))
            else { return Color(nsColor: .textColor) }
            return Color(
                red: Double(color.r) / 255,
                green: Double(color.g) / 255,
                blue: Double(color.b) / 255)
        }

        /// Process pending libghostty work. Scheduled from the wakeup
        /// callback; must run on the main thread.
        func tick() {
            guard let app else { return }
            ghostty_app_tick(app)
        }

        /// Tear down libghostty state. Called on app termination.
        func shutdown() {
            NotificationCenter.default.removeObserver(self)
            if let app { ghostty_app_free(app) }
            if let config { ghostty_config_free(config) }
            self.app = nil
            self.config = nil
        }

        @objc private func applicationDidBecomeActive(_ notification: Notification) {
            guard let app else { return }
            ghostty_app_set_focus(app, true)
        }

        @objc private func applicationDidResignActive(_ notification: Notification) {
            guard let app else { return }
            ghostty_app_set_focus(app, false)
        }

        // MARK: Runtime callbacks

        private static func appInstance(_ userdata: UnsafeMutableRawPointer?) -> App? {
            guard let userdata else { return nil }
            return Unmanaged<App>.fromOpaque(userdata).takeUnretainedValue()
        }

        /// Surface-scoped callbacks receive the surface config userdata,
        /// which is always the owning SurfaceView.
        private static func surfaceView(_ userdata: UnsafeMutableRawPointer?) -> SurfaceView? {
            guard let userdata else { return nil }
            return Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        }

        private static func surfaceView(of surface: ghostty_surface_t?) -> SurfaceView? {
            guard let surface else { return nil }
            return surfaceView(ghostty_surface_userdata(surface))
        }

        private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
            guard let state = appInstance(userdata) else { return }
            // Called from any thread; ticking must happen on the main thread.
            DispatchQueue.main.async { state.tick() }
        }

        private static func action(
            _ app: ghostty_app_t?,
            target: ghostty_target_s,
            action: ghostty_action_s
        ) -> Bool {
            switch action.tag {
            case GHOSTTY_ACTION_QUIT:
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return true

            case GHOSTTY_ACTION_SET_TITLE:
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let view = surfaceView(of: target.target.surface),
                      let cTitle = action.action.set_title.title
                else { return false }
                let title = String(cString: cTitle)
                DispatchQueue.main.async { view.title = title }
                return true

            case GHOSTTY_ACTION_RING_BELL:
                DispatchQueue.main.async { NSSound.beep() }
                return true

            case GHOSTTY_ACTION_OPEN_URL:
                let v = action.action.open_url
                guard let cUrl = v.url else { return false }
                let urlString = String(decoding: UnsafeRawBufferPointer(
                    start: cUrl, count: Int(v.len)), as: UTF8.self)
                guard let url = URL(string: urlString) else { return false }
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                return true

            case GHOSTTY_ACTION_MOUSE_SHAPE:
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let view = surfaceView(of: target.target.surface)
                else { return false }
                let shape = action.action.mouse_shape
                DispatchQueue.main.async { view.setMouseShape(shape) }
                return true

            case GHOSTTY_ACTION_INITIAL_SIZE, GHOSTTY_ACTION_CELL_SIZE, GHOSTTY_ACTION_SIZE_LIMIT:
                // Window sizing hints; safe to ignore for now, SwiftUI
                // manages the window frame.
                return true

            case GHOSTTY_ACTION_NEW_TAB:
                let view: SurfaceView? = target.tag == GHOSTTY_TARGET_SURFACE
                    ? surfaceView(of: target.target.surface)
                    : nil
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .pigeonNewTab, object: view)
                }
                return true

            case GHOSTTY_ACTION_CLOSE_TAB:
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let view = surfaceView(of: target.target.surface)
                else { return false }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .pigeonCloseTab, object: view)
                }
                return true

            case GHOSTTY_ACTION_GOTO_TAB:
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let view = surfaceView(of: target.target.surface)
                else { return false }
                let goto = action.action.goto_tab
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .pigeonGotoTab,
                        object: view,
                        userInfo: ["goto": goto.rawValue])
                }
                return true

            case GHOSTTY_ACTION_CLOSE_WINDOW:
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let view = surfaceView(of: target.target.surface)
                else { return false }
                DispatchQueue.main.async { view.window?.close() }
                return true

            default:
                Ghostty.logger.debug("unhandled action: \(action.tag.rawValue)")
                return false
            }
        }

        private static func readClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            state: UnsafeMutableRawPointer?
        ) {
            // Only the standard clipboard exists on macOS.
            guard location == GHOSTTY_CLIPBOARD_STANDARD,
                  let view = surfaceView(userdata),
                  let surface = view.surface
            else { return }
            let string = NSPasteboard.general.string(forType: .string) ?? ""
            string.withCString { cString in
                ghostty_surface_complete_clipboard_request(surface, cString, state, false)
            }
        }

        private static func confirmReadClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            string: UnsafePointer<CChar>?,
            state: UnsafeMutableRawPointer?,
            request: ghostty_clipboard_request_e
        ) {
            // TODO: show a confirmation dialog like Ghostty does for
            // OSC 52 reads and pastes with control characters. For now we
            // allow the request.
            guard let view = surfaceView(userdata),
                  let surface = view.surface,
                  let string
            else { return }
            ghostty_surface_complete_clipboard_request(surface, string, state, true)
        }

        private static func writeClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            string: UnsafePointer<CChar>?,
            location: ghostty_clipboard_e,
            confirm: Bool
        ) {
            guard location == GHOSTTY_CLIPBOARD_STANDARD, let string else { return }
            let value = String(cString: string)
            DispatchQueue.main.async {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(value, forType: .string)
            }
        }

        private static func closeSurface(
            _ userdata: UnsafeMutableRawPointer?,
            processAlive: Bool
        ) {
            guard let view = surfaceView(userdata) else { return }
            // TODO: confirm before closing when processAlive is true.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .pigeonCloseTab, object: view)
            }
        }
    }
}
