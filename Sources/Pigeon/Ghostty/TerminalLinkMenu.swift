import AppKit
import UniformTypeIdentifiers

/// What cmd+click on a terminal link does. Web URLs open directly; files
/// and directories get a small menu at the pointer (open with the type's
/// default app, open with another app, reveal in Finder, copy path), so a
/// stray click never launches something unexpected.
@MainActor
enum TerminalLinkMenu {
    /// Opens a web URL now; pops the file menu up at the pointer on the
    /// next run-loop pass. Deferred on purpose: popUp runs a nested
    /// tracking loop, and callers are GCD main-queue blocks (the kernel's
    /// OPEN_URL hop, driver requests) or mouse handlers mid-release. GCD
    /// never drains the main queue re-entrantly, so a menu tracked inside
    /// such a block would stall every wakeup/tick — and the driver — until
    /// it closed. A run-loop block leaves the main queue free.
    static func present(_ link: TerminalLink, in view: NSView) {
        if case .url(let url) = link {
            NSWorkspace.shared.open(url)
            return
        }
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                guard let window = view.window, let menu = makeMenu(for: link) else { return }
                let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                openMenu = menu
                defer { openMenu = nil }
                menu.popUp(positioning: nil, at: point, in: view)
            }
        }
        // perform only enqueues; it does not wake a sleeping run loop.
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// The menu currently being tracked, for the driver (which can't
    /// click a popup) to inspect and dismiss.
    private(set) static weak var openMenu: NSMenu?

    /// Opens a file with the editor for its type, falling back to the
    /// system text editor (GHOSTTY_ACTION_OPEN_URL_KIND_TEXT, e.g.
    /// write_scrollback_file:open).
    static func openAsText(_ url: URL) {
        let app = NSWorkspace.shared.urlForApplication(toOpen: url)
            ?? NSWorkspace.shared.urlForApplication(toOpen: .plainText)
        guard let app else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The menu for a file-system link; nil for web URLs, which open directly.
    static func makeMenu(for link: TerminalLink) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false

        switch link {
        case .url:
            return nil

        case .file(let target):
            let url = target.url
            menu.addItem(header(
                (url.path as NSString).abbreviatingWithTildeInPath + (locationSuffix(target) ?? ""),
                image: NSWorkspace.shared.icon(forFile: url.path)))
            menu.addItem(.separator())

            let isText = !target.isDirectory && isTextFile(url)
            let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
                ?? (isText ? NSWorkspace.shared.urlForApplication(toOpen: .plainText) : nil)
            // A location only means something to an editor that can jump
            // to it; VS Code is the one we speak to (vscode://file/…:L:C).
            let vscode = target.line != nil ? VSCode.appURL : nil
            if let vscode, let suffix = locationSuffix(target) {
                menu.addItem(ClosureMenuItem("Open in \(appName(vscode)) at \(suffix.dropFirst())",
                                             image: appIcon(vscode)) {
                    open(target, with: vscode)
                })
            }
            if let defaultApp {
                if vscode == nil || !VSCode.isVSCode(defaultApp) {
                    menu.addItem(ClosureMenuItem("Open in \(appName(defaultApp))", image: appIcon(defaultApp)) {
                        open(target, with: defaultApp)
                    })
                }
            } else {
                // No handler registered: Launch Services offers its own
                // "choose an application" prompt.
                menu.addItem(ClosureMenuItem("Open") { NSWorkspace.shared.open(url) })
            }
            menu.addItem(openWithItem(for: target, defaultApp: defaultApp, includeTextEditors: isText))
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            })
            menu.addItem(ClosureMenuItem("Copy Path") { copy(url.path) })

        case .missing(let path):
            menu.addItem(header("Not found: \((path as NSString).abbreviatingWithTildeInPath)", image: nil))
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Copy Path") { copy(path) })
        }
        return menu
    }

    // MARK: - Pieces

    private static func header(_ title: String, image: NSImage?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.image = image.map(menuSized)
        return item
    }

    /// "Open With ▸": every app that claims the file (plus text editors
    /// for text files whose type nobody registered, e.g. `.zig`), default
    /// first, then "Other…".
    private static func openWithItem(
        for target: TerminalLink.FileTarget, defaultApp: URL?, includeTextEditors: Bool
    ) -> NSMenuItem {
        let url = target.url
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        if includeTextEditors {
            apps += NSWorkspace.shared.urlsForApplications(toOpen: .plainText)
        }
        let key = { (app: URL) in app.standardizedFileURL.path }
        var seen = Set<String>()
        apps = apps.filter { seen.insert(key($0)).inserted }
            .sorted { appName($0).localizedCaseInsensitiveCompare(appName($1)) == .orderedAscending }
        if let defaultApp, let index = apps.firstIndex(where: { key($0) == key(defaultApp) }) {
            apps.insert(apps.remove(at: index), at: 0)
        }

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for app in apps {
            let isDefault = defaultApp.map { key($0) == key(app) } ?? false
            let title = isDefault ? "\(appName(app)) (default)" : appName(app)
            submenu.addItem(ClosureMenuItem(title, image: appIcon(app)) { open(target, with: app) })
        }
        if !apps.isEmpty { submenu.addItem(.separator()) }
        submenu.addItem(ClosureMenuItem("Other…") { chooseApp(for: target) })

        let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private static func chooseApp(for target: TerminalLink.FileTarget) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose an application to open \(target.url.lastPathComponent)"
        guard panel.runModal() == .OK, let app = panel.url else { return }
        open(target, with: app)
    }

    /// Opens the target with `app`; VS Code gets the line/column too.
    private static func open(_ target: TerminalLink.FileTarget, with app: URL) {
        let url = VSCode.isVSCode(app) ? VSCode.gotoURL(for: target) ?? target.url : target.url
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// ":12:4" / ":12" for a target with a location.
    private static func locationSuffix(_ target: TerminalLink.FileTarget) -> String? {
        guard let line = target.line else { return nil }
        return target.column.map { ":\(line):\($0)" } ?? ":\(line)"
    }

    private static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private static func appName(_ app: URL) -> String {
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private static func appIcon(_ app: URL) -> NSImage {
        menuSized(NSWorkspace.shared.icon(forFile: app.path))
    }

    private static func menuSized(_ image: NSImage) -> NSImage {
        let copy = image.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    /// Text by declared type, or — for types nobody registered — by a
    /// NUL-byte sniff of the first 4 KB (empty files count as text).
    static func isTextFile(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            if type.conforms(to: .text) { return true }
            if !type.isDynamic { return false }
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        return !head.contains(0)
    }
}

/// NSMenuItem that runs a closure. The menu retains the item and the item
/// is its own target, so nothing else has to outlive the popup.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, image: NSImage? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        self.image = image
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() { handler() }
}

/// VS Code is the one editor we open *at a location*: its URL handler
/// takes `vscode://file/<absolute path>:<line>[:<column>]`.
enum VSCode {
    static let bundleIdentifier = "com.microsoft.VSCode"

    static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    static func isVSCode(_ app: URL) -> Bool {
        Bundle(url: app)?.bundleIdentifier == bundleIdentifier
    }

    /// Nil when there is no line to go to (plain open is then the same).
    static func gotoURL(for target: TerminalLink.FileTarget) -> URL? {
        guard let line = target.line, !target.isDirectory else { return nil }
        var components = URLComponents()
        components.scheme = "vscode"
        components.host = "file"
        components.path = target.url.path + ":\(line)" + (target.column.map { ":\($0)" } ?? "")
        return components.url
    }
}
