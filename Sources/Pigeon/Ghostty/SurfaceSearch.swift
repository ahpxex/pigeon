import AppKit
import GhosttyKit

/// Text-probe primitives for scrollback search, built entirely on the
/// embedder API (no kernel changes):
///
/// - `ghostty_surface_read_text` with SCREEN-space rectangle selections
///   dumps arbitrary row ranges; rectangle mode emits exactly one output
///   line per screen row (soft-wrapped rows are NOT merged), so line
///   index == row index.
/// - The returned `ghostty_text_s` carries viewport info when the
///   selection intersects it: `offset_start` is the clamped top-left as
///   a viewport cell offset (row*cols+col) and `tl_px_x/y` are unscaled
///   view coordinates — enough to place highlight overlays.
/// - `ghostty_surface_binding_action` performs `scroll_to_bottom` /
///   `scroll_page_lines:N` for exact row-precise scrolling.
///
/// Wide characters occupy two cells but dump as one character; column
/// math therefore goes through display-width prefix sums (see
/// TerminalSearchModel).
extension Ghostty.SurfaceView {
    struct SearchGrid {
        let rows: Int
        let cols: Int
    }

    /// Current terminal grid dimensions.
    func searchGrid() -> SearchGrid? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        guard size.columns > 0, size.rows > 0 else { return nil }
        return SearchGrid(rows: Int(size.rows), cols: Int(size.columns))
    }

    /// Dump screen-space rows [first...last] as text, one line per row
    /// (rectangle selection). Returns nil when the range is outside the
    /// screen (used to discover the total row count).
    func readScreenRows(_ first: Int, _ last: Int, cols: Int) -> String? {
        guard let surface, first >= 0, last >= first else { return nil }
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: 0, y: UInt32(first)),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(cols - 1), y: UInt32(last)),
            rectangle: true)
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text else { return nil }
        return String(cString: ptr)
    }

    /// Dump the visible viewport, one line per row, plus the content
    /// origin (left padding) in view points. Coordinates must be EXACT:
    /// the TOP_LEFT/BOTTOM_RIGHT coord shortcuts return pins whose x is
    /// not the row edge, which collapses rectangle dumps to one column.
    func readViewport(rows: Int, cols: Int) -> (text: String, originX: Double)? {
        guard let surface, rows > 0, cols > 0 else { return nil }
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: 0, y: 0),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(cols - 1), y: UInt32(rows - 1)),
            rectangle: true)
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text else { return nil }
        return (String(cString: ptr), text.tl_px_x)
    }

    /// Where a screen-space cell range currently sits in the viewport,
    /// or nil when it is scrolled out of view. Returns viewport row/col
    /// of the range start (clamped by the kernel if partially visible).
    func viewportPosition(row: Int, col: Int, length: Int, cols: Int) -> (row: Int, col: Int)? {
        guard let surface, row >= 0, col >= 0, length > 0 else { return nil }
        var text = ghostty_text_s()
        let endX = min(col + length - 1, cols - 1)
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(col), y: UInt32(row)),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(endX), y: UInt32(row)),
            rectangle: true)
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        // tl_px == -1 marks "selection does not intersect the viewport".
        guard text.tl_px_x >= 0 else { return nil }
        let offset = Int(text.offset_start)
        return (offset / cols, offset % cols)
    }

    /// Total rows in screen space (scrollback + viewport), discovered by
    /// binary-searching the largest readable row.
    func totalScreenRows(cols: Int, viewportRows: Int) -> Int {
        // Grow an upper bound first; reads past the end fail.
        var hi = max(viewportRows, 64)
        while readScreenRows(hi, hi, cols: cols) != nil {
            if hi > 4_000_000 { return hi }  // safety valve
            hi *= 2
        }
        var lo = 0  // lo = known readable (row 0 always exists), hi = known unreadable
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if readScreenRows(mid, mid, cols: cols) != nil { lo = mid } else { hi = mid }
        }
        return lo + 1
    }

    @discardableResult
    func performBinding(_ action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString {
            ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count))
        }
    }

    /// Scroll the viewport down by `delta` rows (negative = up), exactly.
    func scrollLines(_ delta: Int) {
        var remaining = delta
        // scroll_page_lines takes an i16; chunk huge jumps.
        while remaining != 0 {
            let step = max(-30_000, min(30_000, remaining))
            performBinding("scroll_page_lines:\(step)")
            remaining -= step
        }
    }

    func scrollToBottom() {
        performBinding("scroll_to_bottom")
    }

    /// Top window padding in view points (config window-padding-y);
    /// content rows start below it.
    static func windowPaddingY() -> Double {
        guard let config = Ghostty.App.shared.config else { return 2 }
        var value: UInt32 = 2
        let key = "window-padding-y"
        _ = withUnsafeMutablePointer(to: &value) { ptr in
            ghostty_config_get(config, ptr, key, UInt(key.count))
        }
        return Double(value)
    }
}
