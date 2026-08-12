import AppKit

/// Curated OpenMoji artwork bundled as PNG resources.
/// Source: https://openmoji.org — CC BY-SA 4.0.
enum TabIcon {
    /// Hex codepoints matching the bundled `<code>.png` resources.
    static let codes: [String] = [
        // Animals
        "1F54A", "1F426", "1F99C", "1F989", "1F98A", "1F427", "1F43C",
        "1F422", "1F419", "1F41D", "1F98B", "1F420", "1F40B", "1F985",
        "1F408", "1F415", "1F439",
        // Plants
        "1F335", "1F33F", "1F341", "1F338", "1F344", "1F337",
        // Food
        "1F353", "1F34B", "1F349", "1F351", "1F352", "1F95D", "1F9C1",
        "1F36A", "2615", "1F9CB",
        // Objects
        "1F680", "1F6F8", "2693", "1F3AF", "1F3B2", "1F9E9", "1F511",
        "1F52D", "1F9ED", "231B", "1F4E6", "1F9F2", "1F4A1",
        // Symbols & nature
        "2B50", "26A1", "1F525", "1F308", "2744", "1F30A", "1F319",
        "1F48E", "1F3B5", "26F5",
    ]

    static func random() -> String {
        codes.randomElement() ?? "1F54A"
    }

    private static var cache: [String: NSImage] = [:]

    /// Bundled image for a code; cached because sidebar rows redraw often.
    @MainActor
    static func image(for code: String) -> NSImage? {
        if let cached = cache[code] { return cached }
        guard let url = Bundle.main.url(forResource: code, withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        cache[code] = image
        return image
    }
}
