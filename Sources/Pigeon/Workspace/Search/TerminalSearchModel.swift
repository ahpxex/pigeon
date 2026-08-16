import AppKit
import Combine
import SwiftUI

/// Scrollback search for one tab: scans the full screen buffer through
/// rectangle text dumps (one line per screen row), maps characters to
/// grid cells via display width (wide chars occupy two cells but dump
/// as one character), and navigates by exact row scrolling.
///
/// Known v1 limits: matches spanning a soft-wrap row boundary are not
/// found (rectangle dumps split rows); match positions go stale while
/// the terminal keeps printing (rescan happens on query change, open,
/// and jump), and only visible highlights are refreshed live.
@MainActor
final class TerminalSearchModel: ObservableObject {
    struct Match: Equatable {
        /// Screen-space (scrollback-absolute) position, in cells.
        let row: Int
        let col: Int
        let length: Int
    }

    @Published private(set) var isOpen = false
    /// Bumped every open(); the find field grabs first responder when
    /// it changes (cmd+F while already open refocuses the field).
    @Published private(set) var focusToken = 0
    @Published var query = "" {
        didSet { scheduleRescan() }
    }
    @Published private(set) var matches: [Match] = []
    @Published private(set) var currentIndex: Int?
    /// Highlight rects in surface-view coordinates.
    @Published private(set) var visibleRects: [CGRect] = []
    @Published private(set) var currentRect: CGRect?

    private weak var surfaceView: Ghostty.SurfaceView?
    private var rescanTask: Task<Void, Never>?
    private var overlayTimer: Timer?
    /// Cap pathological queries (e.g. a single space over a huge buffer).
    private static let maxMatches = 2000

    func open(surfaceView: Ghostty.SurfaceView) {
        self.surfaceView = surfaceView
        isOpen = true
        focusToken += 1
        rescan()
        startOverlayTimer()
    }

    func close() {
        isOpen = false
        overlayTimer?.invalidate()
        overlayTimer = nil
        rescanTask?.cancel()
        matches = []
        currentIndex = nil
        visibleRects = []
        currentRect = nil
        if let surfaceView {
            surfaceView.window?.makeFirstResponder(surfaceView)
        }
    }

    func next() { step(1) }
    func previous() { step(-1) }

    private func step(_ direction: Int) {
        guard !matches.isEmpty else { return }
        let index: Int
        if let current = currentIndex {
            index = (current + direction + matches.count) % matches.count
        } else {
            index = direction >= 0 ? 0 : matches.count - 1
        }
        jump(to: index)
    }

    /// Scroll the viewport so the match is centered, then refresh
    /// highlights. scroll_to_bottom anchors the scroll offset to a known
    /// row, making the follow-up line scroll exact.
    private func jump(to index: Int) {
        guard let view = surfaceView, let grid = view.searchGrid(),
              matches.indices.contains(index) else { return }
        currentIndex = index
        let match = matches[index]
        let total = view.totalScreenRows(cols: grid.cols, viewportRows: grid.rows)
        let maxTop = max(0, total - grid.rows)
        let target = min(max(0, match.row - grid.rows / 2), maxTop)
        view.scrollToBottom()
        view.scrollLines(target - maxTop)
        refreshOverlay()
    }

    // MARK: Scanning

    private func scheduleRescan() {
        guard isOpen else { return }
        rescanTask?.cancel()
        rescanTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self.rescan()
        }
    }

    /// Full-buffer scan in row chunks. Chunks are rectangle dumps, so
    /// line index == row index within the chunk.
    func rescan() {
        matches = []
        currentIndex = nil
        defer { refreshOverlay() }
        guard let view = surfaceView, let grid = view.searchGrid(),
              query.count >= 1 else { return }

        let total = view.totalScreenRows(cols: grid.cols, viewportRows: grid.rows)
        var found: [Match] = []
        let chunkRows = 1024
        var row = 0
        scan: while row < total {
            let last = min(row + chunkRows - 1, total - 1)
            guard let text = view.readScreenRows(row, last, cols: grid.cols) else { break }
            for (offset, line) in text.components(separatedBy: "\n").enumerated() {
                Self.matches(of: query, in: line).forEach { col, length in
                    found.append(Match(row: row + offset, col: col, length: length))
                }
                if found.count >= Self.maxMatches { break scan }
            }
            row = last + 1
        }
        matches = found
    }

    /// Case-insensitive literal matches in one dumped row, as
    /// (cell column, cell length) pairs.
    static func matches(of query: String, in line: String) -> [(Int, Int)] {
        guard !query.isEmpty else { return [] }
        // Prefix display widths: cellAt[i] = cell column of character i.
        let chars = Array(line)
        var cellAt = [Int](repeating: 0, count: chars.count + 1)
        for (i, ch) in chars.enumerated() {
            cellAt[i + 1] = cellAt[i] + displayWidth(ch)
        }

        var result: [(Int, Int)] = []
        var searchStart = line.startIndex
        while let range = line.range(
            of: query, options: .caseInsensitive, range: searchStart..<line.endIndex
        ) {
            let start = line.distance(from: line.startIndex, to: range.lowerBound)
            let end = line.distance(from: line.startIndex, to: range.upperBound)
            result.append((cellAt[start], max(1, cellAt[end] - cellAt[start])))
            searchStart = range.upperBound
        }
        return result
    }

    /// GUI processes start in the C locale, where wcwidth reports CJK
    /// as narrow; force a UTF-8 ctype locale once (same as Ghostty's
    /// standalone ensureLocale) so widths match the terminal grid.
    private static let utf8Locale: Void = {
        _ = setlocale(LC_CTYPE, "UTF-8")
    }()

    /// Cells occupied by one grapheme cluster: wide (CJK, most emoji)
    /// = 2, everything else = 1. Mirrors the kernel's wcwidth-based
    /// layout closely enough for highlight placement.
    static func displayWidth(_ ch: Character) -> Int {
        _ = utf8Locale
        guard let scalar = ch.unicodeScalars.first else { return 1 }
        let width = wcwidth(Int32(bitPattern: scalar.value))
        return width == 2 ? 2 : 1
    }

    // MARK: Overlay

    private func startOverlayTimer() {
        overlayTimer?.invalidate()
        overlayTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshOverlay() }
        }
    }

    /// Recompute highlight rects for matches currently in the viewport,
    /// straight from a fresh viewport dump (immune to stale scan data).
    func refreshOverlay() {
        guard isOpen, let view = surfaceView, let grid = view.searchGrid(),
              !query.isEmpty,
              let viewport = view.readViewport(rows: grid.rows, cols: grid.cols)
        else {
            visibleRects = []
            currentRect = nil
            return
        }

        let cell = view.cellSize
        guard cell.width > 0, cell.height > 0 else { return }
        let originX = viewport.originX
        let originY = Ghostty.SurfaceView.windowPaddingY()

        var rects: [CGRect] = []
        for (row, line) in viewport.text.components(separatedBy: "\n").enumerated() {
            for (col, length) in Self.matches(of: query, in: line) {
                rects.append(CGRect(
                    x: originX + Double(col) * cell.width,
                    y: originY + Double(row) * cell.height,
                    width: Double(length) * cell.width,
                    height: cell.height))
            }
        }
        visibleRects = rects

        // The current match gets its own accent rect when visible.
        currentRect = nil
        if let index = currentIndex, matches.indices.contains(index) {
            let match = matches[index]
            if let pos = view.viewportPosition(
                row: match.row, col: match.col,
                length: match.length, cols: grid.cols
            ) {
                currentRect = CGRect(
                    x: originX + Double(pos.col) * cell.width,
                    y: originY + Double(pos.row) * cell.height,
                    width: Double(match.length) * cell.width,
                    height: cell.height)
            }
        }
    }
}
