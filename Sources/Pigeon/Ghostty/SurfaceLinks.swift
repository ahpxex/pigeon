import AppKit
import GhosttyKit

/// cmd+click on names the kernel's link regex can't see: bare file names
/// in `ls` output, `` `a.swift` ``, `src/`, `run.sh*`. When a cmd+click
/// release was not taken by the kernel as a link, take the
/// whitespace-delimited token under the pointer and, if it names an
/// existing file or directory (relative to the tab's cwd), show the same
/// link menu. Existence is the whole test — ordinary words never react —
/// which is also why this can't be a kernel regex: highlighting runs on the
/// render thread and can't consult the file system.
extension Ghostty.SurfaceView {
    func followTokenLink(modifiers: NSEvent.ModifierFlags) {
        // Exactly cmd, like the kernel's link modifier check.
        let relevant = modifiers.intersection([.shift, .control, .option, .command])
        guard relevant == .command,
              let surface,
              // A TUI with mouse reporting owns its clicks (the kernel
              // doesn't follow links there either).
              !ghostty_surface_mouse_captured(surface),
              let target = tokensUnderPointer().lazy
                  .compactMap({ TerminalLink.resolveToken($0, cwd: self.pwd) }).first
        else { return }
        TerminalLinkMenu.present(.file(target), in: self)
    }

    /// Readings of the text under the pointer, best first: the
    /// whitespace-delimited token, then — for names with spaces, which
    /// `ls` prints unquoted — spans joining up to 3 neighbouring words on
    /// each side across *single* spaces (listing columns are separated by
    /// runs of spaces, so they never merge), longest first. Callers take
    /// the first that exists on disk.
    func tokensUnderPointer() -> [String] {
        guard let surface, let grid = searchGrid() else { return [] }
        var word = ghostty_text_s()
        guard ghostty_surface_quicklook_word(surface, &word) else { return [] }
        // tl_px_x < 0 marks "not in the viewport".
        let offset = word.tl_px_x >= 0 ? Int(word.offset_start) : nil
        ghostty_surface_free_text(surface, &word)
        guard let offset else { return [] }

        let row = offset / grid.cols
        guard let line = readViewportRow(row, cols: grid.cols) else { return [] }
        return Self.tokens(in: line, atCell: offset % grid.cols)
    }

    /// See `tokensUnderPointer`. Empty if cell `column` of the dumped row
    /// is blank. Wide characters span two cells.
    static func tokens(in line: String, atCell column: Int, maxJoin: Int = 3) -> [String] {
        let chars = Array(line)
        var cell = 0
        var hit: Int?
        for (index, ch) in chars.enumerated() {
            let width = Ghostty.cellWidth(ch)
            if column < cell + width { hit = index; break }
            cell += width
        }
        guard let hit, !chars[hit].isWhitespace else { return [] }
        var lower = hit
        var upper = hit
        while lower > 0, !chars[lower - 1].isWhitespace { lower -= 1 }
        while upper + 1 < chars.count, !chars[upper + 1].isWhitespace { upper += 1 }

        // Word starts to the left / word ends to the right that are
        // reachable across exactly one space each.
        var starts = [lower]
        while starts.count <= maxJoin, let s = starts.last,
              s >= 2, chars[s - 1] == " ", !chars[s - 2].isWhitespace {
            var t = s - 2
            while t > 0, !chars[t - 1].isWhitespace { t -= 1 }
            starts.append(t)
        }
        var ends = [upper]
        while ends.count <= maxJoin, let e = ends.last,
              e + 2 < chars.count, chars[e + 1] == " ", !chars[e + 2].isWhitespace {
            var t = e + 2
            while t + 1 < chars.count, !chars[t + 1].isWhitespace { t += 1 }
            ends.append(t)
        }
        let spans = starts.flatMap { s in ends.map { (s, $0) } }
            .filter { $0 != (lower, upper) }
            .sorted { $0.1 - $0.0 > $1.1 - $1.0 }
        return [String(chars[lower...upper])] + spans.map { String(chars[$0.0...$0.1]) }
    }

    /// One viewport row as text (rectangle read, so leading blanks are
    /// kept and cell columns line up from the left edge).
    private func readViewportRow(_ row: Int, cols: Int) -> String? {
        guard let surface, row >= 0, cols > 0 else { return nil }
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                x: 0, y: UInt32(row)),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(cols - 1), y: UInt32(row)),
            rectangle: true)
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return text.text.map { String(cString: $0) }
    }
}

extension Ghostty.SurfaceView {
    /// The kernel's regex stops short of some location suffixes
    /// (`src/a.ts(12,4)` matches as `src/a.ts`). If the token under the
    /// pointer names the same file *with* a location, keep the location.
    /// Must not run inside the kernel's OPEN_URL callout: that holds the
    /// renderer mutex, which the screen read below takes too.
    func addingPointerLocation(to link: TerminalLink) -> TerminalLink {
        guard case .file(let target) = link, target.line == nil, !target.isDirectory,
              let token = tokensUnderPointer().first,
              let located = TerminalLink.resolveToken(token, cwd: pwd),
              located.url == target.url, located.line != nil
        else { return link }
        return .file(located)
    }
}
