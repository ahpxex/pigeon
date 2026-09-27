import AppKit
import Foundation

/// Driver routes for cmd+click links. The menu is a popup the driver
/// can't click, so these expose what it shows and let a test dismiss it.
///
///   POST /links/resolve  <- {text, id?, token?}  (id: tab whose cwd to
///                           resolve against, default selected; token: true
///                           resolves like the bare-name cmd+click fallback)
///                        -> {kind: url|file|directory|missing|none, target,
///                            line, column, cwd,
///                            menu: [titles; submenus as {title, items}]}|file|directory|missing, target, cwd,
///                            menu: [titles; submenus as {title, items}]}
///   POST /input/click    <- {x, y, cmd?}  left click in the selected tab at
///                           surface points (top-left origin), through the
///                           kernel's mouse path — cmd follows links
///   GET  /links/token    -> {tokens}  readings of the text under the pointer
///                           (what the bare-name fallback would resolve)
///   GET  /links/menu     -> {open, menu}  the link menu being tracked
///   POST /links/menu/cancel -> dismiss it
extension DriverServer {
    @MainActor
    func handleLinksRoute(_ request: HTTPRequest, manager: TabManager) -> HTTPResponse? {
        switch (request.method, request.path) {
        case ("POST", "/links/resolve"):
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let text = json["text"] as? String
            else { return HTTPResponse(status: 400, error: "need {text, id?}") }
            let tab = (json["id"] as? String).flatMap { id in
                TabManager.all.flatMap(\.tabs).first { $0.id.uuidString == id }
            } ?? manager.selectedTab
            guard let tab else { return HTTPResponse(status: 404, error: "tab not found") }

            let cwd = tab.surfaceView.pwd
            let link: TerminalLink?
            if json["token"] as? Bool == true {
                link = TerminalLink.resolveToken(text, cwd: cwd).map { .file($0) }
            } else {
                link = TerminalLink.resolve(text, cwd: cwd)
            }
            var result: [String: Any] = ["cwd": cwd ?? NSNull()]
            switch link {
            case nil:
                result["kind"] = "none"
            case .url(let url)?:
                result["kind"] = "url"
                result["target"] = url.absoluteString
            case .file(let target)?:
                result["kind"] = target.isDirectory ? "directory" : "file"
                result["target"] = target.url.path
                result["line"] = target.line ?? NSNull()
                result["column"] = target.column ?? NSNull()
            case .missing(let path)?:
                result["kind"] = "missing"
                result["target"] = path
            }
            result["menu"] = link.flatMap(TerminalLinkMenu.makeMenu).map(Self.describe) ?? []
            return HTTPResponse(json: result)

        case ("POST", "/input/click"):
            guard let tab = manager.selectedTab else {
                return HTTPResponse(status: 404, error: "no selected tab")
            }
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let x = json["x"] as? Double, let y = json["y"] as? Double
            else { return HTTPResponse(status: 400, error: "need {x, y, cmd?}") }
            let modifiers: NSEvent.ModifierFlags = json["cmd"] as? Bool == true ? .command : []
            tab.surfaceView.click(at: CGPoint(x: x, y: y), modifiers: modifiers)
            return HTTPResponse(json: ["ok": true])

        case ("GET", "/links/token"):
            guard let tab = manager.selectedTab else {
                return HTTPResponse(status: 404, error: "no selected tab")
            }
            return HTTPResponse(json: ["tokens": tab.surfaceView.tokensUnderPointer()])

        case ("GET", "/links/menu"):
            let menu = TerminalLinkMenu.openMenu
            return HTTPResponse(json: ["open": menu != nil, "menu": menu.map(Self.describe) ?? []])

        case ("POST", "/links/menu/cancel"):
            TerminalLinkMenu.openMenu?.cancelTracking()
            return HTTPResponse(json: ["ok": true])

        default:
            return nil
        }
    }

    @MainActor
    private static func describe(_ menu: NSMenu) -> [Any] {
        menu.items.map { item -> Any in
            if item.isSeparatorItem { return "---" }
            if let submenu = item.submenu {
                return ["title": item.title, "items": describe(submenu)]
            }
            return item.title
        }
    }
}
