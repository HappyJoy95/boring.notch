import Foundation
import Darwin
import Security

/// Independent, versioned bridge owned and distributed by Boring Notch.
enum WorkBuddyInstructionSender {
    struct Configuration: Decodable {
        let port: Int
        let token: String
    }
    static var extensionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".workbuddy/extensions")
    }
    private static func configuration() -> (Configuration, String)? {
        for id in ["boring-notch-bridge"] {
            let file = extensionsRoot.appendingPathComponent(id + "/bridge-config.json")
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_uid == getuid(),
                  info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
                  info.st_size < 4096,
                  let data = try? Data(contentsOf: file),
                  let value = try? JSONDecoder().decode(Configuration.self, from: data),
                  (1024...65535).contains(value.port),
                  value.token.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { continue }
            return (value, id)
        }
        return nil
    }

    static func send(taskID: String, prompt: String, requestID: String) async -> String {
        guard taskID.hasPrefix("workbuddy:"), UUID(uuidString: requestID) != nil else { return "invalid" }
        let sessionID = String(taskID.dropFirst("workbuddy:".count))
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: sessionID) != nil, !text.isEmpty, text.utf16.count <= 12000 else { return "invalid" }
        do { try WorkBuddyTasksReader.validatePinnedTask(taskID) } catch { return "notPinned" }
        guard let (config, id) = configuration() else { return "unavailable" }
        // Check the independent bridge before any send; never retry a dispatch automatically.
        guard await health(config, id: id) else { return "unavailable" }
        let body: [String: Any] = ["schema_version": 1, "command_id": requestID,
                                 "session_id": sessionID, "prompt": text]
        guard let response = await request(config, path: "/v1/instructions/send", body: body) else { return "unknown" }
        return receipt(response, requestID: requestID)
    }

    static func receipt(_ object: [String: Any], requestID: String) -> String {
        guard object["schema_version"] as? Int == 1,
              object["command_id"] as? String == requestID,
              let accepted = object["accepted"] as? Bool else { return "unknown" }
        if accepted {
            guard let status = object["status"] as? String, ["submitted", "queued"].contains(status) else { return "unknown" }
            return status
        }
        if let status = object["status"] as? String,
           ["failed", "unknown", "invalid", "notPinned", "busy"].contains(status) { return status }
        return object["error_code"] as? String == "invalid_payload" ? "invalid" : "unknown"
    }

    static func probe(taskID: String) async -> String {
        do { try WorkBuddyTasksReader.validatePinnedTask(taskID) } catch { return "notPinned" }
        guard let (config, id) = configuration() else { return "missing" }
        guard await health(config, id: id) else { return "unavailable" }
        guard let value = await request(config, path: "/v1/probe?session_id=" + String(taskID.dropFirst("workbuddy:".count)), body: nil)
        else { return "unavailable" }
        return value["status"] as? String == "ready" ? "ready" : "unavailable"
    }

    private static func health(_ config: Configuration, id: String) async -> Bool {
        guard let value = await request(config, path: "/v1/health", body: nil) else { return false }
        return value["schema_version"] as? Int == 1 && value["extension_id"] as? String == id
    }

    private static func request(_ config: Configuration, path: String, body: [String: Any]?) async -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:\(config.port)" + path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: body == nil ? 3 : 25)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer " + config.token, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let settings = URLSessionConfiguration.ephemeral
        settings.connectionProxyDictionary = [:]
        settings.httpCookieStorage = nil
        settings.urlCredentialStorage = nil
        let session = URLSession(configuration: settings, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  data.count <= 65536 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch { return nil }
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    /// Installs our bundled extension without replacing an existing installation.
    static func install(sourceURL: URL? = nil) -> String {
        if configuration() != nil { return "installed" }
        let fm = FileManager.default
        let target = extensionsRoot.appendingPathComponent("boring-notch-bridge")
        guard !fm.fileExists(atPath: target.path) else { return "failed" }
        guard let source = sourceURL ?? Bundle.main.resourceURL?.appendingPathComponent("workbuddy"),
              fm.fileExists(atPath: source.appendingPathComponent("extension.json").path) else { return "failed" }
        let staging = extensionsRoot.appendingPathComponent(".boring-notch-" + UUID().uuidString)
        do {
            try fm.createDirectory(at: extensionsRoot, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: staging)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                try? fm.removeItem(at: staging); return "failed"
            }
            let token = bytes.map { String(format: "%02x", $0) }.joined()
            let value = try JSONSerialization.data(withJSONObject: ["port": Int.random(in: 22000...49000), "token": token])
            let file = staging.appendingPathComponent("bridge-config.json")
            try value.write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try fm.moveItem(at: staging, to: target)
            return "installed"
        } catch { try? fm.removeItem(at: staging); return "failed" }
    }
}
