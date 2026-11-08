import Foundation
import Network

/// Waits for one browser redirect on 127.0.0.1:<port> and returns its URL (path + query).
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private var continuation: CheckedContinuation<URL, Error>?
    private let queue = DispatchQueue(label: "linker.loopback")

    init(port: UInt16) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
    }

    func waitForCallback() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                queue.async {
                    self.continuation = c
                    self.listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
                    self.listener.stateUpdateHandler = { [weak self] state in
                        if case .failed(let e) = state { self?.finish(.failure(e)) }
                    }
                    self.listener.start(queue: self.queue)
                }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            // "GET /callback?code=…&state=… HTTP/1.1"
            let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET", parts[1].hasPrefix("/callback"),
                  let url = URL(string: "http://127.0.0.1\(parts[1])") else {
                self.respond(conn, status: "404 Not Found", body: "Not found")
                return
            }
            self.respond(conn, status: "200 OK", body: """
            <!doctype html><meta charset="utf-8"><title>Linker</title>
            <body style="font:15px -apple-system;display:grid;place-items:center;height:90vh;color:#333">
            <div>Linker is signed in. You can close this tab.</div></body>
            """)
            self.finish(.success(url))
        }
    }

    private func respond(_ conn: NWConnection, status: String, body: String) {
        let data = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        listener.cancel()
        c.resume(with: result)
    }
}
