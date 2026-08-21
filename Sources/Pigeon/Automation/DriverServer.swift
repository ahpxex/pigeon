import AppKit
import Foundation
import GhosttyKit
import Network
import SwiftUI

/// Debug automation server: lets an external agent drive Pigeon over
/// localhost HTTP, Chrome-DevTools style. Only starts when the
/// PIGEON_DRIVER_PORT environment variable is set, and only binds to
/// 127.0.0.1.
///
/// Protocol (all JSON unless noted):
///   GET  /state             -> {tabs: [{id, title, selected}], windowNumber, frame}
///   POST /tabs/new          -> {id}
///   POST /tabs/select       <- {"id": "..."}
///   POST /tabs/close        <- {"id": "..."}
///   POST /tabs/move         <- {"id": "...", "index": 0}
///   POST /tabs/rename       <- {"id": "...", "title": "..."} (empty resets)
///   POST /tabs/icon         <- {"id": "...", "icon": "1F54A"}
///   POST /groups/new        <- {"name": "..."} -> {id}
///   POST /groups/assign     <- {"tabId": "...", "groupId": "..."|null}
///   POST /input/text        <- raw body, pasted into the selected tab
///                              (goes through the paste path; use /input/key
///                              for enter/escape/ctrl-x)
///   POST /input/key         <- {"key": "enter"} — named key or "ctrl-x"
///   GET  /text[?id=...]     -> raw screen text of the tab (default: selected)
///   GET  /sidebar           -> {collapsed, width}
///   POST /sidebar           <- {"collapsed": bool?, "width": number?}
///   GET  /settings          -> {labelStyle, iconCategory, appearance, accentHex}
///   POST /settings          <- partial update of the same keys
///                              (iconCategory/accentHex accept null)
///   GET  /agent/info        -> {port, token, defaultProvider, defaultModel}
///   POST /agent/provider    <- {name, baseURL, model, apiKey?} upsert + set default
///   POST /agent/default     <- {name, model?} switch default only, no mutation
///   POST /agent/provider/remove <- {name} (custom providers only)
final class DriverServer {
    static let shared = DriverServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "pigeon.driver")

    private init() {}

    func startIfConfigured() {
        guard let portString = ProcessInfo.processInfo.environment["PIGEON_DRIVER_PORT"],
              let portNumber = UInt16(portString),
              let port = NWEndpoint.Port(rawValue: portNumber)
        else { return }

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        guard let listener = try? NWListener(using: params) else {
            Ghostty.logger.error("driver: failed to listen on port \(portNumber)")
            return
        }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receiveRequest(connection, buffer: Data())
        }
        listener.start(queue: queue)
        Ghostty.logger.info("driver: listening on 127.0.0.1:\(portNumber)")
    }

    // MARK: HTTP plumbing

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, complete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = HTTPRequest(parsing: buffer) {
                self.handle(request) { response in
                    connection.send(
                        content: response.serialized,
                        completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if complete || buffer.count > 1024 * 1024 {
                connection.cancel()
            } else {
                self.receiveRequest(connection, buffer: buffer)
            }
        }
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data

        init?(parsing data: Data) {
            guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8)
            else { return nil }
            let lines = head.components(separatedBy: "\r\n")
            let parts = lines[0].components(separatedBy: " ")
            guard parts.count >= 2 else { return nil }

            var contentLength = 0
            for line in lines.dropFirst() {
                let kv = line.split(separator: ":", maxSplits: 1)
                if kv.count == 2, kv[0].lowercased() == "content-length" {
                    contentLength = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
            let bodyStart = headerEnd.upperBound
            guard data.count - bodyStart >= contentLength else { return nil }

            self.method = parts[0]
            let url = parts[1]
            if let qIndex = url.firstIndex(of: "?") {
                self.path = String(url[..<qIndex])
                var query: [String: String] = [:]
                for pair in url[url.index(after: qIndex)...].split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    guard kv.count == 2 else { continue }
                    query[String(kv[0])] = kv[1].removingPercentEncoding ?? String(kv[1])
                }
                self.query = query
            } else {
                self.path = url
                self.query = [:]
            }
            self.body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        }
    }

    private struct HTTPResponse {
        var status = 200
        var contentType = "application/json"
        var body: Data

        init(json object: Any) {
            body = (try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys])) ?? Data()
        }

        init(text: String) {
            contentType = "text/plain; charset=utf-8"
            body = Data(text.utf8)
        }

        init(status: Int, error message: String) {
            self.status = status
            body = (try? JSONSerialization.data(
                withJSONObject: ["error": message])) ?? Data()
        }

        var serialized: Data {
            let reason = status == 200 ? "OK" : "Error"
            var head = "HTTP/1.1 \(status) \(reason)\r\n"
            head += "Content-Type: \(contentType)\r\n"
            head += "Content-Length: \(body.count)\r\n"
            head += "Connection: close\r\n\r\n"
            var data = Data(head.utf8)
            data.append(body)
            return data
        }
    }

    // MARK: Request handling

    private func handle(_ request: HTTPRequest, completion: @escaping (HTTPResponse) -> Void) {
        // All app/libghostty state must be touched on the main thread.
        DispatchQueue.main.async {
            let response = self.handleOnMain(request)
            self.queue.async { completion(response) }
        }
    }

    @MainActor
    private func handleOnMain(_ request: HTTPRequest) -> HTTPResponse {
        // App-scoped requests act on the frontmost window's manager;
        // tab-id-addressed requests are resolved across all windows.
        guard let manager = TabManager.forKeyWindow else {
            return HTTPResponse(status: 500, error: "no terminal window")
        }

        switch (request.method, request.path) {
        case ("GET", "/state"):
            let managers = TabManager.all
            let window = manager.window
                ?? manager.tabs.first?.surfaceView.window
                ?? NSApp.windows.first { $0.isVisible }
            var frame: [String: Double] = [:]
            if let f = window?.frame, let screen = window?.screen {
                // CG coordinates (top-left origin) so screencapture -R
                // could consume them directly if ever needed.
                frame = [
                    "x": f.origin.x,
                    "y": screen.frame.height - f.origin.y - f.height,
                    "w": f.width,
                    "h": f.height,
                ]
            }
            var tabsJSON: [[String: Any]] = []
            for m in managers {
                for tab in m.tabs {
                    tabsJSON.append([
                        "id": tab.id.uuidString,
                        "title": tab.displayTitle,
                        "shellTitle": tab.surfaceView.title,
                        "pwd": tab.surfaceView.pwd as Any,
                        "selected": tab.id == m.selectedTabID,
                        "icon": tab.iconCode,
                        "groupId": tab.groupID?.uuidString as Any,
                        "windowNumber": m.window?.windowNumber ?? -1,
                    ])
                }
            }
            let groupsJSON: [[String: Any]] = managers.flatMap(\.groups).map { group in
                [
                    "id": group.id.uuidString,
                    "name": group.name,
                    "expanded": group.isExpanded,
                ]
            }
            let windowsJSON: [[String: Any]] = managers.map { m in
                [
                    "windowNumber": m.window?.windowNumber ?? -1,
                    "tabs": m.tabs.count,
                    "key": m === manager,
                ]
            }
            let increments = window?.contentResizeIncrements ?? NSSize(width: 0, height: 0)
            let incrementsJSON: [String: Double] = [
                "w": Double(increments.width),
                "h": Double(increments.height),
            ]
            return HTTPResponse(json: [
                "tabs": tabsJSON,
                "groups": groupsJSON,
                "windows": windowsJSON,
                "windowNumber": window?.windowNumber ?? -1,
                "frame": frame,
                "resizeIncrements": incrementsJSON,
            ])

        case ("POST", "/windows/new"):
            NotificationCenter.default.post(
                name: .pigeonNewWindow, object: nil, userInfo: ["id": UUID()])
            return HTTPResponse(json: ["ok": true])

        case ("POST", "/windows/select"):
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let number = json["windowNumber"] as? Int,
                  let target = TabManager.all.first(where: { $0.window?.windowNumber == number })
            else { return HTTPResponse(status: 404, error: "window not found") }
            target.window?.makeKeyAndOrderFront(nil)
            return HTTPResponse(json: ["ok": true])

        case ("POST", "/tabs/new"):
            guard let tab = manager.newTab() else {
                return HTTPResponse(status: 500, error: "failed to create tab")
            }
            return HTTPResponse(json: ["id": tab.id.uuidString])

        case ("POST", "/tabs/select"):
            guard let (owner, tab) = locateTab(from: request) else {
                return HTTPResponse(status: 404, error: "tab not found")
            }
            owner.select(tab)
            owner.window?.makeKeyAndOrderFront(nil)
            return HTTPResponse(json: ["ok": true])

        case ("POST", "/tabs/close"):
            guard let (owner, tab) = locateTab(from: request) else {
                return HTTPResponse(status: 404, error: "tab not found")
            }
            // Driver closes never prompt — tests need determinism.
            owner.close(tab, confirmIfNeeded: false)
            return HTTPResponse(json: ["ok": true])

        case ("POST", "/tabs/move"):
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let id = json["id"] as? String,
                  let index = json["index"] as? Int,
                  let (owner, tab) = locateTab(id: id)
            else { return HTTPResponse(status: 400, error: "need {id, index}") }
            owner.move(tabID: tab.id, toIndex: index)
            return HTTPResponse(json: ["ok": true])

        case ("POST", "/tabs/rename"):
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let id = json["id"] as? String,
                  let title = json["title"] as? String,
                  let (_, tab) = locateTab(id: id)
            else { return HTTPResponse(status: 400, error: "need {id, title}") }
            tab.customTitle = title.isEmpty ? nil : title
            return HTTPResponse(json: ["ok": true])

        case ("POST", "/tabs/summarize"):
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let id = json["id"] as? String,
                  let (_, tab) = locateTab(id: id)
            else { return HTTPResponse(status: 400, error: "need {id}") }
            tab.customTitle = nil
            TabTitleSummarizer.shared.summarize(tab)
            return HTTPResponse(json: ["ok": true])

        case ("POST", "/tabs/icon"):
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let id = json["id"] as? String,
                  let icon = json["icon"] as? String,
                  let (_, tab) = locateTab(id: id),
                  TabIcon.codes.contains(icon)
            else { return HTTPResponse(status: 400, error: "need {id, icon} with a known icon code") }
            tab.iconCode = icon
            return HTTPResponse(json: ["ok": true])

        case ("POST", "/groups/new"):
            let json = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            let group = manager.createGroup(named: json["name"] as? String)
            return HTTPResponse(json: ["id": group.id.uuidString])

        case ("POST", "/groups/expand"):
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let id = json["id"] as? String,
                  let expanded = json["expanded"] as? Bool,
                  let group = manager.groups.first(where: { $0.id.uuidString == id })
            else { return HTTPResponse(status: 400, error: "need {id, expanded}") }
            manager.setExpanded(group, expanded: expanded)
            return HTTPResponse(json: ["ok": true])

        case ("POST", "/groups/assign"):
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let tabID = json["tabId"] as? String,
                  let tab = manager.tabs.first(where: { $0.id.uuidString == tabID })
            else { return HTTPResponse(status: 400, error: "need {tabId, groupId|null}") }
            if let groupID = json["groupId"] as? String {
                guard let group = manager.groups.first(where: { $0.id.uuidString == groupID })
                else { return HTTPResponse(status: 404, error: "group not found") }
                manager.assign(tab, to: group)
            } else {
                manager.assign(tab, to: nil)
            }
            return HTTPResponse(json: ["ok": true])

        case ("POST", "/input/text"):
            guard let tab = manager.selectedTab else {
                return HTTPResponse(status: 404, error: "no selected tab")
            }
            guard let text = String(data: request.body, encoding: .utf8) else {
                return HTTPResponse(status: 400, error: "body must be utf8 text")
            }
            tab.surfaceView.sendText(text)
            return HTTPResponse(json: ["ok": true])

        case ("POST", "/input/key"):
            guard let tab = manager.selectedTab else {
                return HTTPResponse(status: 404, error: "no selected tab")
            }
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let name = json["key"] as? String
            else { return HTTPResponse(status: 400, error: "body must be {\"key\": ...}") }
            guard sendNamedKey(name, to: tab.surfaceView) else {
                return HTTPResponse(status: 400, error: "unknown key: \(name)")
            }
            return HTTPResponse(json: ["ok": true])

        case ("GET", "/text"):
            let target: TerminalTab?
            if let id = request.query["id"] {
                target = locateTab(id: id)?.tab
            } else {
                target = manager.selectedTab
            }
            guard let tab = target else {
                return HTTPResponse(status: 404, error: "tab not found")
            }
            return HTTPResponse(text: tab.surfaceView.screenText())

        case ("POST", "/search"):
            guard let tab = manager.selectedTab else {
                return HTTPResponse(status: 404, error: "no selected tab")
            }
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let query = json["query"] as? String
            else { return HTTPResponse(status: 400, error: "body must be {\"query\": ...}") }
            if !tab.search.isOpen {
                tab.search.open(surfaceView: tab.surfaceView)
            }
            tab.search.query = query
            tab.search.rescan()
            return HTTPResponse(json: searchJSON(tab.search))

        case ("POST", "/search/next"), ("POST", "/search/prev"):
            guard let tab = manager.selectedTab, tab.search.isOpen else {
                return HTTPResponse(status: 404, error: "search not open")
            }
            if request.path == "/search/next" { tab.search.next() }
            else { tab.search.previous() }
            return HTTPResponse(json: searchJSON(tab.search))

        case ("GET", "/search"):
            guard let tab = manager.selectedTab else {
                return HTTPResponse(status: 404, error: "no selected tab")
            }
            tab.search.refreshOverlay()
            return HTTPResponse(json: searchJSON(tab.search))

        case ("POST", "/search/close"):
            guard let tab = manager.selectedTab else {
                return HTTPResponse(status: 404, error: "no selected tab")
            }
            tab.search.close()
            return HTTPResponse(json: ["ok": true])

        case ("GET", "/sidebar"):
            let workspace = manager.workspace
            return HTTPResponse(json: [
                "collapsed": workspace.sidebarCollapsed,
                "width": workspace.sidebarWidth,
            ])

        case ("POST", "/sidebar"):
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
            else { return HTTPResponse(status: 400, error: "body must be JSON") }
            let workspace = manager.workspace
            if let collapsed = json["collapsed"] as? Bool {
                workspace.sidebarCollapsed = collapsed
            }
            if let width = json["width"] as? Double {
                workspace.sidebarWidth = WorkspaceState.clampWidth(width)
            }
            return HTTPResponse(json: [
                "collapsed": workspace.sidebarCollapsed,
                "width": workspace.sidebarWidth,
            ])

        case ("GET", "/kernel"):
            return HTTPResponse(json: kernelJSON())

        case ("POST", "/kernel"):
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
            else { return HTTPResponse(status: 400, error: "body must be JSON") }
            let kernel = KernelSettings.shared
            if let v = json["fontFamily"] as? String { kernel.fontFamily = v }
            if let v = json["fontSize"] as? Double { kernel.fontSize = v }
            if json.keys.contains("theme") {
                let id = json["theme"] as? String
                guard id == nil || TerminalTheme.theme(id: id) != nil else {
                    return HTTPResponse(status: 400, error: "unknown theme")
                }
                kernel.themeID = id
            }
            if let v = json["cursorStyle"] as? String,
               let style = KernelSettings.CursorStyle(rawValue: v) {
                kernel.cursorStyle = style
            }
            if let v = json["backgroundOpacity"] as? Double { kernel.backgroundOpacity = v }
            kernel.apply()
            return HTTPResponse(json: kernelJSON())

        case ("POST", "/ui/open-settings"):
            Ghostty.App.openSettingsWindow()
            return HTTPResponse(json: [
                "windows": NSApp.windows.filter(\.isVisible).map(\.windowNumber),
            ])

        case ("POST", "/config/reload"):
            Ghostty.App.shared.reloadConfig()
            var fontSize: Float = -1
            var family: UnsafePointer<CChar>? = nil
            if let config = Ghostty.App.shared.config {
                let sizeKey = "font-size"
                _ = withUnsafeMutablePointer(to: &fontSize) {
                    ghostty_config_get(config, $0, sizeKey, UInt(sizeKey.count))
                }
                let familyKey = "font-family"
                _ = withUnsafeMutablePointer(to: &family) {
                    ghostty_config_get(config, $0, familyKey, UInt(familyKey.count))
                }
            }
            return HTTPResponse(json: [
                "ok": true,
                "path": Ghostty.ConfigStore.configFileURL.path,
                "configFontSize": Double(fontSize),
                "configFontFamily": family.map { String(cString: $0) } as Any,
            ])

        case ("POST", "/agent/provider"):
            // Test/automation hook: upsert a custom provider and make it
            // the default. {name, baseURL, model, apiKey}
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let name = json["name"] as? String,
                  let baseURL = json["baseURL"] as? String,
                  let model = json["model"] as? String
            else { return HTTPResponse(status: 400, error: "need {name, baseURL, model, apiKey?}") }
            let agent = AgentSettings.shared
            var provider: AgentProvider
            if let existing = agent.providers.first(where: { $0.name == name }) {
                provider = existing
            } else {
                provider = agent.addCustomProvider()
                provider.name = name
            }
            if !provider.isBuiltin {
                provider.baseURL = baseURL
                provider.models = [model]
            }
            if !provider.models.contains(model) { provider.models.append(model) }
            provider.selectedModel = model
            agent.update(provider)
            if let key = json["apiKey"] as? String {
                agent.setAPIKey(key, for: provider)
            }
            agent.defaultProviderID = provider.id
            return HTTPResponse(json: ["id": provider.id.uuidString, "agentPort": Int(AgentServer.shared.port)])

        case ("GET", "/agent/info"):
            // Eval/automation hook: where the agent endpoint lives, the
            // per-launch bearer token, and the active provider (so a test
            // run can restore it afterwards). Driver-only, dev-only.
            let agent = AgentSettings.shared
            let provider = agent.providers.first { $0.id == agent.defaultProviderID }
            return HTTPResponse(json: [
                "port": Int(AgentServer.shared.port),
                "token": AgentServer.shared.token,
                "defaultProvider": provider?.name as Any,
                "defaultModel": provider?.selectedModel as Any,
            ])

        case ("POST", "/agent/default"):
            // Switch the default provider (and optionally its model)
            // without touching URL or API key — safe to use for restore.
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let name = json["name"] as? String
            else { return HTTPResponse(status: 400, error: "need {name, model?}") }
            let agent = AgentSettings.shared
            guard var provider = agent.providers.first(where: { $0.name == name }) else {
                return HTTPResponse(status: 404, error: "provider not found")
            }
            if let model = json["model"] as? String, !model.isEmpty {
                if !provider.models.contains(model) { provider.models.append(model) }
                provider.selectedModel = model
                agent.update(provider)
            }
            agent.defaultProviderID = provider.id
            return HTTPResponse(json: ["ok": true])

        case ("POST", "/agent/provider/remove"):
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let name = json["name"] as? String
            else { return HTTPResponse(status: 400, error: "need {name}") }
            let agent = AgentSettings.shared
            guard let provider = agent.providers.first(where: { $0.name == name }) else {
                return HTTPResponse(status: 404, error: "provider not found")
            }
            guard !provider.isBuiltin else {
                return HTTPResponse(status: 400, error: "cannot remove builtin provider")
            }
            agent.remove(provider)
            return HTTPResponse(json: ["ok": true])

        case ("GET", "/settings"):
            return HTTPResponse(json: settingsJSON())

        case ("POST", "/settings"):
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
            else { return HTTPResponse(status: 400, error: "body must be JSON") }
            let settings = AppSettings.shared
            if let raw = json["labelStyle"] as? String {
                guard let style = AppSettings.LabelStyle(rawValue: raw)
                else { return HTTPResponse(status: 400, error: "bad labelStyle") }
                settings.labelStyle = style
            }
            if json.keys.contains("iconCategory") {
                settings.iconCategory = json["iconCategory"] as? String
            }
            if let raw = json["appearance"] as? String {
                guard let appearance = AppSettings.Appearance(rawValue: raw)
                else { return HTTPResponse(status: 400, error: "bad appearance") }
                settings.appearance = appearance
            }
            if json.keys.contains("accentHex") {
                settings.accentHex = json["accentHex"] as? String
            }
            if let enabled = json["aiTabTitles"] as? Bool {
                settings.aiTabTitles = enabled
            }
            return HTTPResponse(json: settingsJSON())

        default:
            return HTTPResponse(status: 404, error: "unknown endpoint \(request.method) \(request.path)")
        }
    }

    @MainActor
    private func searchJSON(_ search: TerminalSearchModel) -> [String: Any] {
        var json: [String: Any] = [
            "open": search.isOpen,
            "query": search.query,
            "count": search.matches.count,
            "visible": search.visibleRects.map(rectJSON),
        ]
        if let index = search.currentIndex { json["index"] = index }
        if let rect = search.currentRect { json["current"] = rectJSON(rect) }
        return json
    }

    private func rectJSON(_ rect: CGRect) -> [String: Double] {
        ["x": rect.minX, "y": rect.minY, "w": rect.width, "h": rect.height]
    }

    @MainActor
    private func kernelJSON() -> [String: Any] {
        let kernel = KernelSettings.shared
        return [
            "fontFamily": kernel.fontFamily,
            "fontSize": kernel.fontSize,
            "theme": kernel.themeID as Any,
            "cursorStyle": kernel.cursorStyle.rawValue,
            "backgroundOpacity": kernel.backgroundOpacity,
        ]
    }

    @MainActor
    private func settingsJSON() -> [String: Any] {
        let settings = AppSettings.shared
        return [
            "labelStyle": settings.labelStyle.rawValue,
            "iconCategory": settings.iconCategory as Any,
            "appearance": settings.appearance.rawValue,
            "accentHex": settings.accentHex as Any,
            "aiTabTitles": settings.aiTabTitles,
        ]
    }

    /// Named keys for /input/key. Keycodes are macOS virtual keycodes.
    @MainActor
    private func sendNamedKey(_ name: String, to view: Ghostty.SurfaceView) -> Bool {
        switch name {
        case "enter": view.sendKey(keyCode: 36, text: "\r", unshiftedCodepoint: 0x0D)
        case "tab": view.sendKey(keyCode: 48, text: "\t", unshiftedCodepoint: 0x09)
        case "escape": view.sendKey(keyCode: 53, text: "\u{1B}", unshiftedCodepoint: 0x1B)
        case "backspace": view.sendKey(keyCode: 51, text: "\u{7F}", unshiftedCodepoint: 0x7F)
        case "up": view.sendKey(keyCode: 126, text: nil)
        case "down": view.sendKey(keyCode: 125, text: nil)
        case "left": view.sendKey(keyCode: 123, text: nil)
        case "right": view.sendKey(keyCode: 124, text: nil)
        default:
            if name.hasPrefix("ctrl-"), name.count == 6,
               let letter = name.last?.asciiValue,
               letter >= UInt8(ascii: "a"), letter <= UInt8(ascii: "z") {
                // Encode as the corresponding C0 byte.
                let c0 = String(UnicodeScalar(letter - UInt8(ascii: "a") + 1))
                view.sendKey(
                    keyCode: 0,
                    text: c0,
                    unshiftedCodepoint: UInt32(letter),
                    mods: GHOSTTY_MODS_CTRL)
                return true
            }
            if name.hasPrefix("cmd-"), name.count == 5,
               let letter = name.last?.asciiValue,
               letter >= UInt8(ascii: "a"), letter <= UInt8(ascii: "z") {
                // Runs the ghostty keybinding path (cmd+w close tab, ...),
                // same as performKeyEquivalent would for real input.
                view.sendKey(
                    keyCode: 0,
                    text: nil,
                    unshiftedCodepoint: UInt32(letter),
                    mods: GHOSTTY_MODS_SUPER)
                return true
            }
            return false
        }
        return true
    }

    /// Resolve a tab id to its owning manager and tab, across all windows.
    @MainActor
    private func locateTab(id: String) -> (owner: TabManager, tab: TerminalTab)? {
        for manager in TabManager.all {
            if let tab = manager.tabs.first(where: { $0.id.uuidString == id }) {
                return (manager, tab)
            }
        }
        return nil
    }

    @MainActor
    private func locateTab(from request: HTTPRequest) -> (owner: TabManager, tab: TerminalTab)? {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let id = json["id"] as? String
        else { return nil }
        return locateTab(id: id)
    }
}
