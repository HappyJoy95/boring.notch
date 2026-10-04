import Foundation
import Darwin

/// Client for the user-installed DSH plugin bridge.
/// The helper never reads DSH's session files directly.
enum DSHTasksReader {
    private struct Configuration: Decodable {
        let port: Int
        let token: String
    }

    private static var configurationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Boring Notch/DSH/bridge-config.json")
    }

    private static func configuration() -> Configuration? {
        let url = configurationURL
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 4096,
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Configuration.self, from: data),
              (1024...65535).contains(value.port),
              value.token.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return nil }
        return value
    }

    static func readTasks() async -> Data? {
        guard let config = configuration() else { return Data("[]".utf8) }
        guard await health(config) else { return nil }
        return await request(config, path: "/v1/tasks")
    }

    static func readHistory(_ sessionID: String, cursor: String?) async -> Data? {
        guard validSessionID(sessionID), let config = configuration(), await health(config),
              var components = URLComponents(string: "/v1/history") else { return nil }
        components.queryItems = [URLQueryItem(name: "session_id", value: sessionID)]
        if let cursor { components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
        guard let path = components.string else { return nil }
        return await request(config, path: path)
    }

    static func control(_ sessionID: String, action: String, prompt: String?, requestID: String) async -> String {
        guard validSessionID(sessionID), validSessionID(requestID), ["send", "stop"].contains(action),
              action != "send" || (prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && (prompt?.utf8.count ?? 0) <= 8192) else { return "invalid" }
        guard let config = configuration(),
              let healthData = await request(config, path: "/v1/health"),
              let health = try? JSONSerialization.jsonObject(with: healthData) as? [String: Any],
              health["schema_version"] as? Int == 1,
              health["extension_id"] as? String == "boring-notch-dsh",
              let capabilities = health["capabilities"] as? [String: Bool], capabilities[action] == true else { return "unavailable" }
        var payload: [String: Any] = ["session_id": sessionID, "request_id": requestID]
        if let prompt { payload["prompt"] = prompt }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return "invalid" }
        guard let data = await request(config, path: "/v1/" + action, body: body),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = value["result"] as? String else { return "unknown" }
        return result
    }

    private static func validSessionID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && value.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil
    }

    private static func health(_ config: Configuration) async -> Bool {
        guard let data = await request(config, path: "/v1/health"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["schema_version"] as? Int == 1 && object["extension_id"] as? String == "boring-notch-dsh"
    }

    private static func request(_ config: Configuration, path: String, body: Data? = nil) async -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(config.port)\(path)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: body == nil ? 4 : 10)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("Bearer " + config.token, forHTTPHeaderField: "Authorization")
        let settings = URLSessionConfiguration.ephemeral
        settings.connectionProxyDictionary = [:]
        settings.httpCookieStorage = nil
        settings.urlCredentialStorage = nil
        let session = URLSession(configuration: settings, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  data.count <= 262_144 else { return nil }
            return data
        } catch { return nil }
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
