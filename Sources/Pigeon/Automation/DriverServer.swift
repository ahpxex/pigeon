import AppKit
import Foundation
import GhosttyKit
import Network

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
        let manager = TabManager.shared

        switch (request.method, request.path) {
        case ("GET", "/state"):
            let window = manager.tabs.first?.surfaceView.window
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
            return HTTPResponse(json: [
                "tabs": manager.tabs.map { tab in
                    [
                        "id": tab.id.uuidString,
                        "title": tab.customTitle ?? tab.surfaceView.title,
                        "shellTitle": tab.surfaceView.title,
                        "selected": tab.id == manager.selectedTabID,
                        "icon": tab.iconCode,
                        "groupId": tab.groupID?.uuidString as Any,
                    ]
                },
                "groups": manager.groups.map { group in
                    [
                        "id": group.id.uuidString,
                        "name": group.name,
                        "expanded": group.isExpanded,
                    ]
                },
                "windowNumber": window?.windowNumber ?? -1,
                "frame": frame,
            ])

        case ("POST", "/tabs/new"):
            guard let tab = manager.newTab() else {
                return HTTPResponse(status: 500, error: "failed to create tab")
            }
            return HTTPResponse(json: ["id": tab.id.uuidString])

        case ("POST", "/tabs/select"):
            guard let tab = tab(in: manager, from: request) else {
                return HTTPResponse(status: 404, error: "tab not found")
            }
            manager.select(tab)
            return HTTPResponse(json: ["ok": true])

        case ("POST", "/tabs/close"):
            guard let tab = tab(in: manager, from: request) else {
                return HTTPResponse(status: 404, error: "tab not found")
            }
            manager.close(tab)
            return HTTPResponse(json: ["ok": true])

        case ("POST", "/tabs/move"):
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let id = json["id"] as? String,
                  let index = json["index"] as? Int,
                  let tab = manager.tabs.first(where: { $0.id.uuidString == id })
            else { return HTTPResponse(status: 400, error: "need {id, index}") }
            manager.move(tabID: tab.id, toIndex: index)
            return HTTPResponse(json: ["ok": true])

        case ("POST", "/tabs/rename"):
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let id = json["id"] as? String,
                  let title = json["title"] as? String,
                  let tab = manager.tabs.first(where: { $0.id.uuidString == id })
            else { return HTTPResponse(status: 400, error: "need {id, title}") }
            tab.customTitle = title.isEmpty ? nil : title
            return HTTPResponse(json: ["ok": true])

        case ("POST", "/tabs/icon"):
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let id = json["id"] as? String,
                  let icon = json["icon"] as? String,
                  let tab = manager.tabs.first(where: { $0.id.uuidString == id }),
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
                target = manager.tabs.first { $0.id.uuidString == id }
            } else {
                target = manager.selectedTab
            }
            guard let tab = target else {
                return HTTPResponse(status: 404, error: "tab not found")
            }
            return HTTPResponse(text: tab.surfaceView.screenText())

        case ("GET", "/sidebar"):
            let workspace = WorkspaceState.shared
            return HTTPResponse(json: [
                "collapsed": workspace.sidebarCollapsed,
                "width": workspace.sidebarWidth,
            ])

        case ("POST", "/sidebar"):
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
            else { return HTTPResponse(status: 400, error: "body must be JSON") }
            let workspace = WorkspaceState.shared
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

        default:
            return HTTPResponse(status: 404, error: "unknown endpoint \(request.method) \(request.path)")
        }
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
            // "ctrl-x" for any letter: encode as the corresponding C0 byte.
            guard name.hasPrefix("ctrl-"), name.count == 6,
                  let letter = name.last?.asciiValue,
                  letter >= UInt8(ascii: "a"), letter <= UInt8(ascii: "z")
            else { return false }
            let c0 = String(UnicodeScalar(letter - UInt8(ascii: "a") + 1))
            view.sendKey(
                keyCode: 0,
                text: c0,
                unshiftedCodepoint: UInt32(letter),
                mods: GHOSTTY_MODS_CTRL)
        }
        return true
    }

    @MainActor
    private func tab(in manager: TabManager, from request: HTTPRequest) -> TerminalTab? {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let id = json["id"] as? String
        else { return nil }
        return manager.tabs.first { $0.id.uuidString == id }
    }
}
