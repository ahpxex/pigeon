import AppKit
import Combine
import GhosttyKit
import SwiftUI

extension Notification.Name {
    /// Ask the SwiftUI layer to open the Settings scene.
    static let pigeonOpenSettings = Notification.Name("pigeonOpenSettings")
    /// Request a new tab. Object is the originating SurfaceView (may be nil).
    static let pigeonNewTab = Notification.Name("pigeonNewTab")
    /// Request closing the tab that owns the SurfaceView in object.
    static let pigeonCloseTab = Notification.Name("pigeonCloseTab")
    /// The user pressed bare Enter in the SurfaceView in object —
    /// treated as "submitted something" by the activity monitor, which
    /// lights the tab's busy spinner immediately.
    static let pigeonSurfaceDidSubmit = Notification.Name("pigeonSurfaceDidSubmit")
    /// Switch tabs. Object is the originating SurfaceView, userInfo["goto"]
    /// is a ghostty_action_goto_tab_e raw value.
    static let pigeonGotoTab = Notification.Name("pigeonGotoTab")
    /// Request a new terminal window. userInfo["id"] carries a UUID so
    /// the per-window bridges can claim the request exactly once.
    static let pigeonNewWindow = Notification.Name("pigeonNewWindow")
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

            // Pigeon's own kernel config (~/.config/pigeon/config) —
            // deliberately isolated from Ghostty.app's configuration.
            guard let config = ConfigStore.load() else {
                readiness = .error("failed to load config")
                return
            }
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

        /// Configured background opacity; chrome and window transparency
        /// follow it so the terminal and the chrome stay in step.
        var backgroundOpacity: Double {
            guard let config else { return 1 }
            var value: Double = 1
            let key = "background-opacity"
            _ = withUnsafeMutablePointer(to: &value) { ptr in
                ghostty_config_get(config, ptr, key, UInt(key.count))
            }
            return value
        }

        /// Whether quitting the app should ask the user first (any surface
        /// still has a running process, per confirm-close-surface).
        var needsConfirmQuit: Bool {
            guard let app else { return false }
            return ghostty_app_needs_confirm_quit(app)
        }

        /// Process pending libghostty work. Scheduled from the wakeup
        /// callback; must run on the main thread.
        func tick() {
            guard let app else { return }
            ghostty_app_tick(app)
        }

        /// Open the SwiftUI Settings scene. Routed through the SwiftUI
        /// openSettings environment action (SettingsOpener in the view
        /// tree); the legacy AppKit selectors no longer respond on
        /// current macOS.
        @MainActor
        static func openSettingsWindow() {
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .pigeonOpenSettings, object: nil)
        }

        /// Rebuild the config from Pigeon's file and push it to the app
        /// (propagates to all live surfaces).
        @MainActor
        func reloadConfig() {
            guard let app else { return }
            guard let newConfig = ConfigStore.load() else {
                Ghostty.logger.error("config reload failed")
                return
            }
            objectWillChange.send()
            ghostty_app_update_config(app, newConfig)
            // The app-level update does not touch live surfaces; each one
            // must be updated explicitly (fonts, colors, etc).
            for manager in TabManager.all {
                for tab in manager.tabs {
                    if let surface = tab.surfaceView.surface {
                        ghostty_surface_update_config(surface, newConfig)
                    }
                }
            }
            if let old = config { ghostty_config_free(old) }
            config = newConfig
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

            case GHOSTTY_ACTION_PWD:
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let view = surfaceView(of: target.target.surface),
                      let cPwd = action.action.pwd.pwd
                else { return false }
                let pwd = String(cString: cPwd)
                DispatchQueue.main.async { view.pwd = pwd }
                return true

            case GHOSTTY_ACTION_RELOAD_CONFIG:
                Task { @MainActor in App.shared.reloadConfig() }
                return true

            case GHOSTTY_ACTION_CONFIG_CHANGE:
                // Emitted after ghostty_app_update_config; nothing extra
                // to do — our published change already refreshed the UI.
                return true

            case GHOSTTY_ACTION_OPEN_CONFIG:
                // "open config" in ghostty terms maps to Pigeon's
                // Settings window.
                DispatchQueue.main.async { App.openSettingsWindow() }
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

            case GHOSTTY_ACTION_INITIAL_SIZE:
                // Preferred content size in points, from window-width/height
                // (cells). WindowBridge applies it when the window appears.
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let view = surfaceView(of: target.target.surface)
                else { return false }
                let v = action.action.initial_size
                let size = NSSize(width: Double(v.width), height: Double(v.height))
                DispatchQueue.main.async { view.initialSize = size }
                return true

            case GHOSTTY_ACTION_CELL_SIZE:
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let view = surfaceView(of: target.target.surface)
                else { return false }
                let v = action.action.cell_size
                // Arrives in physical pixels; resize increments are points.
                let backing = NSSize(width: Double(v.width), height: Double(v.height))
                DispatchQueue.main.async { [weak view] in
                    guard let view else { return }
                    view.cellSize = view.convertFromBacking(backing)
                }
                return true

            case GHOSTTY_ACTION_SIZE_LIMIT:
                // Minimum size hints; SwiftUI's frame minimums cover us.
                return true

            case GHOSTTY_ACTION_NEW_WINDOW:
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .pigeonNewWindow,
                        object: nil,
                        userInfo: ["id": UUID()])
                }
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
                    // User-initiated (cmd+W): confirm if a process is running.
                    NotificationCenter.default.post(
                        name: .pigeonCloseTab,
                        object: view,
                        userInfo: ["confirm": true])
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

        /// Reads that need user approval: OSC 52 reads and pastes with
        /// control characters. The kernel already applied the config; we
        /// ask and complete the request with the text or an empty string.
        private static func confirmReadClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            string: UnsafePointer<CChar>?,
            state: UnsafeMutableRawPointer?,
            request: ghostty_clipboard_request_e
        ) {
            guard let view = surfaceView(userdata), let string else { return }
            let contents = String(cString: string)
            DispatchQueue.main.async { [weak view] in
                ClipboardConfirmation.present(
                    on: view?.window,
                    contents: contents,
                    request: request
                ) { [weak view] confirmed in
                    // The surface may have died while the dialog was up;
                    // completing against a freed surface would crash.
                    guard let surface = view?.surface else { return }
                    let value = confirmed ? contents : ""
                    value.withCString { cString in
                        ghostty_surface_complete_clipboard_request(
                            surface, cString, state, true)
                    }
                }
            }
        }

        private static func writeClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            string: UnsafePointer<CChar>?,
            location: ghostty_clipboard_e,
            confirm: Bool
        ) {
            guard location == GHOSTTY_CLIPBOARD_STANDARD, let string else { return }
            let value = String(cString: string)
            let view = surfaceView(userdata)
            DispatchQueue.main.async {
                let write = {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(value, forType: .string)
                }
                guard confirm else {
                    write()
                    return
                }
                // OSC 52 write with clipboard-write = ask. Unlike reads
                // there is no request to complete; a denial simply leaves
                // the clipboard untouched.
                ClipboardConfirmation.present(
                    on: view?.window,
                    contents: value,
                    request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE
                ) { confirmed in
                    if confirmed { write() }
                }
            }
        }

        private static func closeSurface(
            _ userdata: UnsafeMutableRawPointer?,
            processAlive: Bool
        ) {
            guard let view = surfaceView(userdata) else { return }
            // The kernel asks us to close (normally: the process exited).
            // Only a still-alive process warrants a confirmation.
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .pigeonCloseTab,
                    object: view,
                    userInfo: ["confirm": processAlive])
            }
        }
    }
}
