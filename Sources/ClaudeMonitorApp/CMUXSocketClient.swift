import Foundation
import ClaudeMonitorCore

/// Lightweight Unix domain socket client for CMUX's JSON-over-socket API.
/// Protocol: send `{"method": "...", "params": {...}}\n`, receive JSON response line.
class CMUXSocketClient {
    private let explicitPath: String?

    init(socketPath: String? = nil) {
        self.explicitPath = socketPath
    }

    /// Resolve the socket path fresh on every call. The monitor app is launched
    /// from Finder/login and does not inherit `$CMUX_SOCKET_PATH`, and cmux's
    /// socket location can change (XDG state dir vs legacy Application Support),
    /// so we re-discover it each time rather than freezing it at init.
    private var socketPath: String {
        CMUXSocketPath.resolve(
            explicit: explicitPath,
            env: ProcessInfo.processInfo.environment,
            home: NSHomeDirectory(),
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    /// Send a JSON-RPC-style request and return the parsed response.
    func send(method: String, params: [String: Any]? = nil) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            debugLog("CMUXSocket: socket() failed: \(errno)")
            return nil
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            debugLog("CMUXSocket: path too long")
            return nil
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dst, src.baseAddress!, src.count)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            debugLog("CMUXSocket: connect failed: \(errno)")
            return nil
        }

        // Build request JSON
        var request: [String: Any] = ["method": method]
        if let params = params {
            request["params"] = params
        }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: request),
              var jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }
        jsonString += "\n"

        // Send
        guard let sendData = jsonString.data(using: .utf8) else { return nil }
        let sent = sendData.withUnsafeBytes { buf in
            Darwin.send(fd, buf.baseAddress!, buf.count, 0)
        }
        guard sent == sendData.count else {
            debugLog("CMUXSocket: send failed")
            return nil
        }

        // Receive response (read until newline or EOF, up to 64KB)
        var responseData = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            responseData.append(contentsOf: buf[..<n])
            if buf[..<n].contains(UInt8(ascii: "\n")) { break }
            if responseData.count > 65536 { break }
        }

        guard !responseData.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            return nil
        }
        return parsed
    }

    /// Send a request and unwrap cmux's response envelope.
    /// cmux wraps all responses: `{"result": {...}, "ok": true/false, "error": {...}}`.
    /// Returns the `result` dict if `ok == true`, nil otherwise.
    func sendUnwrapped(method: String, params: [String: Any]? = nil) -> [String: Any]? {
        guard let response = send(method: method, params: params),
              response["ok"] as? Bool == true,
              let result = response["result"] as? [String: Any] else {
            return nil
        }
        return result
    }

    /// Ping the CMUX socket to check if it's alive.
    func isAvailable() -> Bool {
        guard let response = send(method: "system.ping") else { return false }
        return response["ok"] as? Bool == true
    }
}
