import AppKit
import Carbon.HIToolbox
import Combine
import GhosttyKit

extension Ghostty {
    /// The NSView hosting a single terminal surface. libghostty attaches
    /// its own CAMetalLayer to this view and renders on its own thread;
    /// our job is geometry, focus, and input.
    final class SurfaceView: NSView, ObservableObject {
        /// Window title requested by the running program (OSC 0/2).
        @Published var title: String = "Pigeon" {
            didSet { window?.title = title }
        }

        /// Working directory reported by shell integration (OSC 7).
        @Published var pwd: String?

        /// Terminal cell size in points (CELL_SIZE action). The window
        /// uses it as resize increments so resizing snaps to the grid.
        @Published var cellSize: NSSize = .zero

        /// Preferred initial content size in points (INITIAL_SIZE action,
        /// derived from window-width/height in cells). Applied once when
        /// the window for a fresh surface appears.
        @Published var initialSize: NSSize?

        private(set) var surface: ghostty_surface_t?

        /// Accumulates text produced by interpretKeyEvents during keyDown
        /// so we can attach it to the libghostty key event.
        private var keyTextAccumulator: [String]? = nil

        /// IME preedit (marked) text state.
        private var markedText = NSMutableAttributedString()

        private var mouseShape: NSCursor = .iBeam

        private var appearanceObserver: NSKeyValueObservation?

        /// Stable identity the shell hook echoes back on /ask (via
        /// X-Pigeon-Surface): the agent uses it to read THIS tab's screen
        /// and to keep this tab's conversation memory.
        let agentSurfaceID = UUID().uuidString

        override var acceptsFirstResponder: Bool { true }

        init(app: ghostty_app_t) {
            super.init(frame: NSMakeRect(0, 0, 800, 600))

            var config = ghostty_surface_config_new()
            config.userdata = Unmanaged.passUnretained(self).toOpaque()
            config.platform_tag = GHOSTTY_PLATFORM_MACOS
            config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(self).toOpaque()
            ))
            config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)

            // Expose the agent server to the shell: the zsh
            // command_not_found_handler uses these to route natural
            // language to the built-in agent. The token authenticates the
            // request so no other local process (or browser) can call it.
            let env = [
                ("PIGEON_AGENT_PORT", String(AgentServer.shared.port)),
                ("PIGEON_AGENT_TOKEN", AgentServer.shared.token),
                ("PIGEON_SURFACE_ID", agentSurfaceID),
            ]
            let surface = Self.withEnvVars(env) { envPtr, count in
                config.env_vars = envPtr
                config.env_var_count = count
                return ghostty_surface_new(app, &config)
            }

            guard let surface else {
                Ghostty.logger.critical("ghostty_surface_new failed")
                return
            }
            self.surface = surface

            // Report the effective appearance to libghostty so terminal
            // programs can query the color scheme (mirrors vendor).
            appearanceObserver = observe(
                \.effectiveAppearance, options: [.new, .initial]
            ) { view, change in
                guard let appearance = change.newValue,
                      let surface = view.surface else { return }
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ghostty_surface_set_color_scheme(
                    surface, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        /// Build a C `ghostty_env_var_s` array from Swift strings, valid
        /// only for the duration of `body` (the surface copies them).
        private static func withEnvVars<R>(
            _ vars: [(String, String)],
            _ body: (UnsafeMutablePointer<ghostty_env_var_s>, Int) -> R
        ) -> R {
            func recurse(
                _ index: Int,
                _ accumulated: [ghostty_env_var_s]
            ) -> R {
                if index == vars.count {
                    var array = accumulated
                    return array.withUnsafeMutableBufferPointer { buffer in
                        body(buffer.baseAddress!, buffer.count)
                    }
                }
                return vars[index].0.withCString { key in
                    vars[index].1.withCString { value in
                        recurse(index + 1, accumulated + [ghostty_env_var_s(key: key, value: value)])
                    }
                }
            }
            return recurse(0, [])
        }

        deinit {
            if let surface { ghostty_surface_free(surface) }
        }

        /// Tear down the kernel surface (killing the shell) right now.
        /// Closing a tab must not wait for this view to deallocate —
        /// SwiftUI keeps it alive until the next render pass, and the
        /// close-last-tab → quit path checks the kernel synchronously.
        func shutdownSurface() {
            guard let surface else { return }
            ghostty_surface_free(surface)
            self.surface = nil
        }

        /// Whether closing this surface should ask the user first. The
        /// kernel folds in the confirm-close-surface config and whether a
        /// foreground process (beyond the shell) is still running.
        var needsConfirmQuit: Bool {
            guard let surface else { return false }
            return ghostty_surface_needs_confirm_quit(surface)
        }

        /// When the user last typed into this terminal (driver input
        /// counts too, so tests exercise the same paths). Activity
        /// tracking uses it to tell tool output from typing echo.
        private(set) var lastUserInputAt: Date?

        // MARK: Programmatic access (driver / tests)

        /// Send raw text to the pty as if typed. Control characters pass
        /// through (e.g. "\u{03}" for ctrl-c, "\r" for enter).
        func sendText(_ text: String) {
            guard let surface else { return }
            lastUserInputAt = Date()
            text.withCString { cString in
                ghostty_surface_text(surface, cString, UInt(strlen(cString)))
            }
        }

        /// Synthesize a key press+release, bypassing AppKit. Used by the
        /// driver server. Note sendText() goes through the paste path, so
        /// keys like enter must come through here to be encoded as input.
        func sendKey(
            keyCode: UInt32,
            text: String?,
            unshiftedCodepoint: UInt32 = 0,
            mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE
        ) {
            guard let surface else { return }
            lastUserInputAt = Date()
            if keyCode == 36, mods == GHOSTTY_MODS_NONE {
                NotificationCenter.default.post(name: .pigeonSurfaceDidSubmit, object: self)
            }
            var key = ghostty_input_key_s()
            key.keycode = keyCode
            key.mods = mods
            key.consumed_mods = GHOSTTY_MODS_NONE
            key.unshifted_codepoint = unshiftedCodepoint
            key.composing = false

            key.action = GHOSTTY_ACTION_PRESS
            if let text {
                text.withCString { cString in
                    key.text = cString
                    _ = ghostty_surface_key(surface, key)
                }
            } else {
                key.text = nil
                _ = ghostty_surface_key(surface, key)
            }

            key.action = GHOSTTY_ACTION_RELEASE
            key.text = nil
            _ = ghostty_surface_key(surface, key)
        }

        /// The visible viewport only, as plain text. Cheap enough to
        /// sample every second — screenText() walks the whole
        /// scrollback, this reads one screenful.
        func viewportText() -> String {
            guard let surface else { return "" }
            var text = ghostty_text_s()
            let selection = ghostty_selection_s(
                top_left: ghostty_point_s(
                    tag: GHOSTTY_POINT_VIEWPORT,
                    coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                    x: 0, y: 0),
                bottom_right: ghostty_point_s(
                    tag: GHOSTTY_POINT_VIEWPORT,
                    coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                    x: 0, y: 0),
                rectangle: false)
            guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
            defer { ghostty_surface_free_text(surface, &text) }
            guard let ptr = text.text else { return "" }
            return String(cString: ptr)
        }

        /// The full screen contents (scrollback + viewport) as plain text.
        func screenText() -> String {
            guard let surface else { return "" }
            var text = ghostty_text_s()
            let selection = ghostty_selection_s(
                top_left: ghostty_point_s(
                    tag: GHOSTTY_POINT_SCREEN,
                    coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                    x: 0, y: 0),
                bottom_right: ghostty_point_s(
                    tag: GHOSTTY_POINT_SCREEN,
                    coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                    x: 0, y: 0),
                rectangle: false)
            guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
            defer { ghostty_surface_free_text(surface, &text) }
            guard let ptr = text.text else { return "" }
            return String(cString: ptr)
        }

        // MARK: Window lifecycle

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.title = title

            // The surface should immediately own keyboard focus.
            window.makeFirstResponder(self)

            let center = NotificationCenter.default
            center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
            center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
            center.addObserver(
                self,
                selector: #selector(windowKeyStateDidChange),
                name: NSWindow.didBecomeKeyNotification,
                object: window)
            center.addObserver(
                self,
                selector: #selector(windowKeyStateDidChange),
                name: NSWindow.didResignKeyNotification,
                object: window)

            viewDidChangeBackingProperties()
        }

        @objc private func windowKeyStateDidChange(_ notification: Notification) {
            syncFocus()
        }

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result { syncFocus() }
            return result
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result, let surface {
                ghostty_surface_set_focus(surface, false)
            }
            return result
        }

        private func syncFocus() {
            guard let surface else { return }
            let focused = (window?.isKeyWindow ?? false) && window?.firstResponder === self
            ghostty_surface_set_focus(surface, focused)
        }

        // MARK: Geometry

        override func resize(withOldSuperviewSize oldSize: NSSize) {
            super.resize(withOldSuperviewSize: oldSize)
            sizeDidChange(frame.size)
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            sizeDidChange(newSize)
        }

        private func sizeDidChange(_ size: CGSize) {
            guard let surface else { return }
            // libghostty wants the size in actual framebuffer pixels.
            let scaled = convertToBacking(size)
            ghostty_surface_set_size(surface, UInt32(scaled.width), UInt32(scaled.height))
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()

            // Keep the compositor from scaling our layer contents; we
            // render at native resolution ourselves.
            if let window {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer?.contentsScale = window.backingScaleFactor
                CATransaction.commit()
            }

            guard let surface else { return }
            let fbFrame = convertToBacking(frame)
            guard frame.width > 0, frame.height > 0 else { return }
            ghostty_surface_set_content_scale(
                surface,
                fbFrame.width / frame.width,
                fbFrame.height / frame.height)
            ghostty_surface_set_size(surface, UInt32(fbFrame.width), UInt32(fbFrame.height))
        }

        // MARK: Mouse

        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
                owner: self,
                userInfo: nil))
            super.updateTrackingAreas()
        }

        func setMouseShape(_ shape: ghostty_action_mouse_shape_e) {
            let cursor: NSCursor
            switch shape {
            case GHOSTTY_MOUSE_SHAPE_TEXT: cursor = .iBeam
            case GHOSTTY_MOUSE_SHAPE_POINTER: cursor = .pointingHand
            case GHOSTTY_MOUSE_SHAPE_GRAB: cursor = .openHand
            case GHOSTTY_MOUSE_SHAPE_GRABBING: cursor = .closedHand
            case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: cursor = .crosshair
            case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: cursor = .operationNotAllowed
            case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: cursor = .iBeamCursorForVerticalLayout
            default: cursor = .arrow
            }
            mouseShape = cursor
            window?.invalidateCursorRects(for: self)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: mouseShape)
        }

        private func sendMouseButton(_ event: NSEvent, state: ghostty_input_mouse_state_e, button: ghostty_input_mouse_button_e) {
            guard let surface else { return }
            _ = ghostty_surface_mouse_button(surface, state, button, Ghostty.mods(event.modifierFlags))
        }

        override func mouseDown(with event: NSEvent) {
            sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
        }

        override func mouseUp(with event: NSEvent) {
            sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
        }

        override func rightMouseDown(with event: NSEvent) {
            sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
        }

        override func rightMouseUp(with event: NSEvent) {
            sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
        }

        override func otherMouseDown(with event: NSEvent) {
            guard event.buttonNumber == 2 else { return }
            sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_MIDDLE)
        }

        override func otherMouseUp(with event: NSEvent) {
            guard event.buttonNumber == 2 else { return }
            sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_MIDDLE)
        }

        private func sendMousePos(_ event: NSEvent) {
            guard let surface else { return }
            let pos = convert(event.locationInWindow, from: nil)
            // libghostty expects (0, 0) at the top left.
            ghostty_surface_mouse_pos(
                surface,
                pos.x,
                frame.height - pos.y,
                Ghostty.mods(event.modifierFlags))
        }

        override func mouseMoved(with event: NSEvent) { sendMousePos(event) }
        override func mouseDragged(with event: NSEvent) { sendMousePos(event) }
        override func rightMouseDragged(with event: NSEvent) { sendMousePos(event) }
        override func otherMouseDragged(with event: NSEvent) { sendMousePos(event) }

        override func scrollWheel(with event: NSEvent) {
            guard let surface else { return }

            var x = event.scrollingDeltaX
            var y = event.scrollingDeltaY
            let precision = event.hasPreciseScrollingDeltas
            if precision {
                // Trackpad deltas are in points; scale them up so scrolling
                // feels right (same multiplier Ghostty uses).
                x *= 2
                y *= 2
            }

            // ghostty_input_scroll_mods_t is a packed bitfield:
            // bit 0 = precision, bits 1-3 = momentum phase.
            var momentum: Int32 = 0
            switch event.momentumPhase {
            case .began: momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue)
            case .stationary: momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue)
            case .changed: momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
            case .ended: momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue)
            case .cancelled: momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue)
            case .mayBegin: momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue)
            default: momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue)
            }
            let scrollMods: ghostty_input_scroll_mods_t = (precision ? 1 : 0) | (momentum << 1)

            ghostty_surface_mouse_scroll(surface, x, y, scrollMods)
        }

        // MARK: Keyboard

        override func keyDown(with event: NSEvent) {
            guard let surface else {
                super.keyDown(with: event)
                return
            }
            lastUserInputAt = Date()
            // Bare Enter (Return or keypad Enter, no modifiers) reads as
            // "submitted" — shift+Enter is a newline in TUIs like Claude
            // Code and must not light the spinner while composing.
            if event.keyCode == 36 || event.keyCode == 76,
               event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty {
                NotificationCenter.default.post(name: .pigeonSurfaceDidSubmit, object: self)
            }

            // Run the event through the input method stack first. Plain
            // keys produce text via insertText, IME sequences produce
            // marked text and eventually commit through insertText too.
            let markedTextBefore = markedText.length > 0
            keyTextAccumulator = []
            defer { keyTextAccumulator = nil }
            interpretKeyEvents([event])

            // Push the compose state so the terminal renders the preedit
            // text at the cursor. Only clear an existing preedit; a fresh
            // clear would stomp state we never set.
            syncPreedit(clearIfNeeded: markedTextBefore)

            let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
            var key = event.ghosttyKeyEvent(action)

            if let texts = keyTextAccumulator, !texts.isEmpty {
                for text in texts {
                    text.withCString { cString in
                        key.text = cString
                        _ = ghostty_surface_key(surface, key)
                    }
                }
            } else {
                // No committed text: either a non-text key or the IME is
                // holding the key as part of a compose sequence. Also treat
                // the key that just cancelled a compose (had marked text
                // before, none now) as composing so it isn't encoded.
                key.composing = markedText.length > 0 || markedTextBefore
                _ = ghostty_surface_key(surface, key)
            }
        }

        override func keyUp(with event: NSEvent) {
            guard let surface else { return }
            _ = ghostty_surface_key(surface, event.ghosttyKeyEvent(GHOSTTY_ACTION_RELEASE))
        }

        override func flagsChanged(with event: NSEvent) {
            guard let surface else { return }

            // Determine whether this flags change is a press or release of
            // the modifier associated with the keycode.
            let mod: NSEvent.ModifierFlags
            switch Int(event.keyCode) {
            case kVK_Shift, kVK_RightShift: mod = .shift
            case kVK_Control, kVK_RightControl: mod = .control
            case kVK_Option, kVK_RightOption: mod = .option
            case kVK_Command, kVK_RightCommand: mod = .command
            case kVK_CapsLock: mod = .capsLock
            default: return
            }
            let action = event.modifierFlags.contains(mod)
                ? GHOSTTY_ACTION_PRESS
                : GHOSTTY_ACTION_RELEASE

            _ = ghostty_surface_key(surface, event.ghosttyKeyEvent(action))
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            // AppKit routes cmd-modified keys here instead of keyDown. Give
            // libghostty a chance to run its keybindings (cmd+c, cmd+v, ...);
            // anything it doesn't consume falls through to the menu.
            guard let surface,
                  event.type == .keyDown,
                  window?.firstResponder === self
            else { return false }

            // cmd+, belongs to the app (Settings…), never to the
            // terminal — even though ghostty binds it to open_config.
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "," {
                return false
            }

            let key = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
            guard ghostty_surface_key_is_binding(surface, key) else { return false }
            lastUserInputAt = Date()
            _ = ghostty_surface_key(surface, key)
            return true
        }
    }
}

// MARK: NSTextInputClient

extension Ghostty.SurfaceView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let s as NSAttributedString: text = s.string
        case let s as String: text = s
        default: return
        }

        unmarkText()

        if keyTextAccumulator != nil {
            // Inside keyDown: attach the text to the key event so libghostty
            // sees key + text together (needed for keybindings and encoding).
            keyTextAccumulator?.append(text)
        } else if let surface {
            // Text arriving outside a key event (e.g. IME candidate
            // selection by mouse, dictation).
            text.withCString { cString in
                ghostty_surface_text(surface, cString, UInt(strlen(cString)))
            }
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let s as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: s)
        case let s as String:
            markedText = NSMutableAttributedString(string: s)
        default:
            break
        }

        // Outside a keyDown (e.g. keyboard layout change mid-compose) the
        // preedit must be pushed immediately; inside keyDown the caller
        // syncs after interpretKeyEvents returns.
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    /// Mirror the marked-text state into libghostty so the renderer draws
    /// the composing text at the cursor.
    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            markedText.string.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(strlen(ptr)))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(location: 0, length: markedText.length - 1)
    }

    func selectedRange() -> NSRange {
        NSRange()
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Position the IME candidate window at the cursor.
        guard let surface, let window else { return .zero }
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        // libghostty coordinates are top-left origin, AppKit is bottom-left.
        let viewRect = NSMakeRect(x, frame.height - y - height, width, height)
        let winRect = convert(viewRect, to: nil)
        return window.convertToScreen(winRect)
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    override func doCommand(by selector: Selector) {
        // Do nothing. Control sequences (arrows, enter, etc.) are encoded
        // from the raw key event by libghostty; letting AppKit "handle"
        // them here would just beep.
    }
}
