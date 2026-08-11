import AppKit
import GhosttyKit
import os

/// Namespace for everything that talks to libghostty.
enum Ghostty {
    static let logger = Logger(subsystem: "dev.ahpx.pigeon", category: "ghostty")

    /// One-time global initialization of libghostty. Must complete
    /// successfully before any other libghostty API is used.
    static let initialized: Bool = {
        ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS
    }()

    /// Translate AppKit modifier flags to the libghostty mods bitmask.
    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

        // Sided input. libghostty only needs to know when the right-side
        // variant is pressed (e.g. for "right-option-key" configs).
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

        return ghostty_input_mods_e(mods)
    }
}

extension NSEvent {
    /// Build a libghostty key event from this NSEvent. The `text` and
    /// `composing` fields are left unset: text has C-string lifetime
    /// requirements so the caller must set it within a `withCString` scope.
    func ghosttyKeyEvent(_ action: ghostty_input_action_e) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(keyCode)
        key.text = nil
        key.composing = false
        key.mods = Ghostty.mods(modifierFlags)

        // macOS gives us no direct way to know which modifiers were consumed
        // to produce the text. Heuristic used by Ghostty itself: control and
        // command never contribute to text translation, everything else did.
        key.consumed_mods = Ghostty.mods(modifierFlags.subtracting([.control, .command]))

        // The unshifted codepoint is the character with no modifiers applied.
        key.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp {
            if let chars = characters(byApplyingModifiers: []),
               let cp = chars.unicodeScalars.first {
                key.unshifted_codepoint = cp.value
            }
        }

        return key
    }
}
