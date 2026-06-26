import Foundation
import Network
import os
import VisionCore

/// HTTP MCP server — listens for `POST /mcp` requests and dispatches them through
/// `MCPServer.computeResponse`, enabling remote nodes to use Mac Vision capabilities
/// over the network without local `macvis` installations.
///
/// Transport: HTTP/1.1, one request per connection (Connection: close). Each JSON-RPC
/// request is handled in an isolated Task; the server itself is stateless.
enum HTTPServer {
    static func run(host: String, port: UInt16) async -> Int32 {
        guard let listener = makeListener(host: host, port: port) else {
            IO.warn("error: failed to create listener on \(host):\(port)")
            return ExitCode.runtimeError.rawValue
        }

        let listenerFailed = OSAllocatedUnfairLock(initialState: false)
        let (connStream, connCont) = AsyncStream<NWConnection>.makeStream()

        listener.newConnectionHandler = { conn in connCont.yield(conn) }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let portStr = listener.port.map { "\($0)" } ?? "\(port)"
                IO.warn("macvis serve: listening on \(host):\(portStr) (HTTP MCP)")
            case .failed(let err):
                IO.warn("error: listener failed: \(err)")
                listenerFailed.withLock { $0 = true }
                connCont.finish()
            case .cancelled:
                connCont.finish()
            default:
                break
            }
        }
        listener.start(queue: .global(qos: .userInitiated))

        for await conn in connStream {
            Task { await handle(conn) }
        }

        listener.cancel()
        return listenerFailed.withLock { $0 } ? ExitCode.runtimeError.rawValue : ExitCode.success.rawValue
    }

    // MARK: - private

    private static func makeListener(host: String, port: UInt16) -> NWListener? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            IO.warn("error: invalid port value \(port)"); return nil
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if host != "0.0.0.0" && host != "::" {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host), port: nwPort)
        }
        guard let listener = try? NWListener(using: params, on: nwPort) else {
            IO.warn("error: could not bind to \(host):\(port) (port may be in use)"); return nil
        }
        // Cap concurrent connections: each handle() holds up to ~20 MB; 32 gives plenty
        // of headroom for any realistic single-Mac workload without unbounded memory use.
        listener.newConnectionLimit = 32
        return listener
    }

    private static func handle(_ conn: NWConnection) async {
        conn.start(queue: .global(qos: .userInitiated))
        defer { conn.cancel() }

        guard let raw = await receiveHTTPRequest(conn) else { return }

        let req: HTTPRequest
        do {
            req = try HTTPParser.parse(raw)
        } catch {
            let errJSON = #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#
            await sendHTTPResponse(conn, status: 400, body: Data(errJSON.utf8), contentType: "application/json")
            return
        }

        guard req.method == "POST", req.path == "/mcp" else {
            let msg = "macvis serve only handles POST /mcp"
            await sendHTTPResponse(conn, status: 404, body: Data(msg.utf8))
            return
        }

        guard let rpcObj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            // Return a JSON-RPC error envelope so MCP clients get structured feedback.
            let errJSON = #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#
            await sendHTTPResponse(conn, status: 400, body: Data(errJSON.utf8), contentType: "application/json")
            return
        }

        guard let resp = await MCPServer.computeResponse(for: rpcObj) else {
            // Notification — no MCP response expected; 204 signals "no content" cleanly.
            await sendHTTPResponse(conn, status: 204, body: Data())
            return
        }

        let requestId: Any = rpcObj["id"] ?? NSNull()
        guard let respData = try? JSONSerialization.data(withJSONObject: resp,
                                                          options: [.withoutEscapingSlashes]) else {
            let errObj: [String: Any] = ["jsonrpc": "2.0", "id": requestId,
                                         "error": ["code": -32603, "message": "Internal error"] as [String: Any]]
            let errData = (try? JSONSerialization.data(withJSONObject: errObj))
                ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
            await sendHTTPResponse(conn, status: 500, body: errData, contentType: "application/json")
            return
        }

        await sendHTTPResponse(conn, status: 200, body: respData, contentType: "application/json")
    }

    /// Accumulate raw bytes until we have the complete HTTP request:
    /// all headers (`\r\n\r\n`) plus exactly `Content-Length` body bytes.
    private static func receiveHTTPRequest(_ conn: NWConnection) async -> Data? {
        let sep = Data("\r\n\r\n".utf8)
        var buf = Data()
        var expectedBodyLen: Int? = nil
        var bodyStartOffset: Int? = nil  // cached once so break-check is O(1) per chunk
        var peerClosed = false            // distinguish cap-hit from dropped connection

        while buf.count < 20_971_520 {  // soft 20 MB cap; one 64 KB chunk may push buf up to ~20.06 MB
            let chunk = await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                    // Deliver data even when a connection-end error arrives simultaneously
                    // (TCP FIN + data in the same callback invocation from standard clients).
                    if let data, !data.isEmpty { c.resume(returning: data) }
                    else {
                        if let error { IO.warn("macvis serve: receive error: \(error)") }
                        c.resume(returning: nil)
                    }
                }
            }
            guard let chunk, !chunk.isEmpty else { peerClosed = true; break }
            buf.append(chunk)

            // Once we see the header terminator, lock in the expected body length
            if expectedBodyLen == nil, let sepRange = buf.range(of: sep) {
                bodyStartOffset = buf.distance(from: buf.startIndex, to: sepRange.upperBound)
                let headerBytes = Data(buf[buf.startIndex ..< sepRange.lowerBound])
                guard let headerStr = String(data: headerBytes, encoding: .utf8) else {
                    // Non-UTF-8 headers: reject immediately. Without this guard the loop
                    // would continue to the 20 MB cap (expectedBodyLen stays nil).
                    let errJSON = #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#
                    await sendHTTPResponse(conn, status: 400, body: Data(errJSON.utf8), contentType: "application/json")
                    return nil
                }
                let hLines = headerStr.components(separatedBy: "\r\n")
                // Method from request line (first element) — needed for 411 check below.
                let reqMethod = String(hLines.first?.split(separator: " ", maxSplits: 1).first ?? "")
                for line in hLines {
                    if line.lowercased().hasPrefix("content-length:") {
                        let val = line.dropFirst("content-length:".count)
                            .trimmingCharacters(in: .whitespaces)
                        // Non-numeric CL → 0: fires body-complete check on first chunk;
                        // HTTPParser treats non-numeric CL as absent and returns raw bytes.
                        if let cl = Int(val), cl >= 0 { expectedBodyLen = cl } else { expectedBodyLen = 0 }
                        break
                    }
                }
                if expectedBodyLen == nil {
                    // POST/PUT/PATCH MUST include Content-Length — reject with 411.
                    // GET/HEAD/DELETE legitimately have no body; default their CL to 0.
                    // RFC 9110 §15.5.12 forbids 411 for methods that do not carry a body.
                    let bodyMethod = reqMethod == "POST" || reqMethod == "PUT" || reqMethod == "PATCH"
                    if bodyMethod {
                        let errJSON = #"{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Length Required"}}"#
                        await sendHTTPResponse(conn, status: 411, body: Data(errJSON.utf8), contentType: "application/json")
                        return nil
                    }
                    expectedBodyLen = 0
                }
            }

            // Stop when we have headers + full body (O(1) — no re-scan for separator)
            if let want = expectedBodyLen, let bodyStart = bodyStartOffset {
                if buf.count - bodyStart >= want { break }
            }
        }

        if let want = expectedBodyLen {
            // Dead peer — return nil regardless of declared CL; nothing to respond to.
            if peerClosed { return nil }
            // Body incomplete at loop exit (cap hit before full receipt, or want > cap).
            // -32001: server-defined "payload too large" (not -32600 "Invalid Request",
            // which is reserved for structurally malformed JSON-RPC objects).
            if let bodyStart = bodyStartOffset, buf.count - bodyStart < want {
                let errJSON = #"{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"Payload too large"}}"#
                await sendHTTPResponse(conn, status: 413, body: Data(errJSON.utf8), contentType: "application/json")
                return nil
            }
        }

        if peerClosed { return nil }
        return buf.isEmpty ? nil : buf
    }

    private static func sendHTTPResponse(
        _ conn: NWConnection,
        status: Int,
        body: Data,
        contentType: String = "text/plain"
    ) async {
        let phrase = httpPhrase(status)
        // RFC 9110 §15.3.5: 204 MUST NOT carry body or body-related headers.
        let bodyHeaders = status == 204 ? "" :
            "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        let header = "HTTP/1.1 \(status) \(phrase)\r\nConnection: close\r\n\(bodyHeaders)\r\n"
        var resp = Data(header.utf8)
        if status != 204 { resp.append(body) }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            conn.send(content: resp, completion: .contentProcessed { error in
                if let error { IO.warn("macvis serve: send error (\(status)): \(error)") }
                c.resume()
            })
        }
    }

    private static func httpPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 411: return "Length Required"
        case 413: return "Content Too Large"
        case 500: return "Internal Server Error"
        default: return "Status \(status)"
        }
    }
}
