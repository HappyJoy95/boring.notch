import Foundation
import Darwin
import Security
import CryptoKit

/// Boring Notch's own pairing configuration, independent of MiMo account/model credentials.
enum MiMoBridgeClient {
    struct Configuration: Codable { let port: Int; let token: String }
    private static var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mimocode/boring-notch-bridge") }
    private static var pluginURL: URL { root.deletingLastPathComponent().appendingPathComponent("plugins/boring-notch.js") }
    private static func configuration() -> Configuration? {
        let file = root.appendingPathComponent("config.json")
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size <= 4096,
              let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(Configuration.self, from: data),
              (0...65535).contains(value.port), value.token.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return nil }
        return value
    }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private static func request(_ config: Configuration, path: String, body: [String: Any]? = nil) async -> [String: Any]? {
        guard config.port >= 1024, let url = URL(string: "http://127.0.0.1:\(config.port)" + path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: body == nil ? 2 : (path == "/v1/control" ? 20 : 8))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer " + config.token, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let settings = URLSessionConfiguration.ephemeral
        settings.connectionProxyDictionary = [:]; settings.httpCookieStorage = nil; settings.urlCredentialStorage = nil
        let session = URLSession(configuration: settings, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count <= 65536,
                  let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], value["schema_version"] as? Int == 1 else { return nil }
            return value
        } catch { return nil }
    }
    private static func health(_ config: Configuration) async -> Bool {
        guard let value = await request(config, path: "/v1/health") else { return false }
        return value["bridge"] as? String == "boring-notch-mimo" && value["version"] as? String == "0.1.0"
            && Set(value["capabilities"] as? [String] ?? []).isSuperset(of: ["send", "stop", "status"])
    }
    static func probe() async -> String {
        guard let config = configuration() else { return "missing" }
        return await health(config) ? "ready" : "unavailable"
    }
    static func statuses(_ contexts: [MiMoTasksReader.Context]) async -> [String: String] {
        guard !contexts.isEmpty, let config = configuration(), await health(config),
              let value = await request(config, path: "/v1/status", body: ["scope": contexts.map { ["id": $0.id, "directory": $0.directory] }]),
              let statuses = value["statuses"] as? [String: String] else { return [:] }
        let allowed = Set(contexts.map(\.id))
        return statuses.filter { allowed.contains($0.key) && ["idle", "running", "waiting", "completed", "interrupted"].contains($0.value) }
    }
    static func control(_ id: String, action: String, prompt: String?, requestID: String) async -> String {
        guard ["send", "stop"].contains(action), UUID(uuidString: requestID) != nil else { return "invalid" }
        let text = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard action != "send" || (!text.isEmpty && text.utf8.count <= 8192) else { return "invalid" }
        guard let config = configuration(), await health(config) else { return "unavailable" }
        // Recheck pins immediately before dispatch, including their directory and archive/child state.
        let contexts: [MiMoTasksReader.Context]
        do { contexts = try MiMoTasksReader.local.contexts() } catch { return "unavailable" }
        guard let context = contexts.first(where: { $0.id == id }) else { return "notPinned" }
        var body: [String: Any] = ["action": action, "request_id": requestID,
            "session": ["id": context.id, "directory": context.directory],
            "scope": contexts.map { ["id": $0.id, "directory": $0.directory] }]
        if action == "send" { body["prompt"] = text }
        guard let value = await request(config, path: "/v1/control", body: body),
              value["request_id"] as? String == requestID, let result = value["result"] as? String,
              ["submitted", "notPinned", "invalid", "busy", "unknown", "failed", "unavailable"].contains(result) else { return "unknown" }
        return result
    }

    /// Add only our global plugin. Unknown existing files are never overwritten.
    static func install(sourceURL: URL? = nil, destinationRoot: URL? = nil) -> String {
        let fm = FileManager.default, destination = destinationRoot ?? root
        let parent = destination.deletingLastPathComponent()
        let plugin = parent.appendingPathComponent("plugins/boring-notch.js")
        guard let source = sourceURL ?? Bundle.main.resourceURL?.appendingPathComponent("MiMoDesktop") else { return "failed" }
        func safeDirectory(_ url: URL) -> Bool {
            if !fm.fileExists(atPath: url.path) { return true }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false
        }
        guard safeDirectory(parent), safeDirectory(destination), safeDirectory(plugin.deletingLastPathComponent()) else { return "failed" }
        do {
            let runtimeURL = source.appendingPathComponent("runtime.mjs"), entryURL = source.appendingPathComponent("entry.js")
            for file in [runtimeURL, entryURL] {
                let info = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) < 512000 else { return "failed" }
            }
            let runtime = try Data(contentsOf: runtimeURL), entry = try Data(contentsOf: entryURL)
            let ownerURL = destination.appendingPathComponent("owner.json")
            if fm.fileExists(atPath: plugin.path) {
                let info = try plugin.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard info.isSymbolicLink != true, let owner = try? JSONSerialization.jsonObject(with: Data(contentsOf: ownerURL)) as? [String: String],
                      owner["id"] == "boring-notch-mimo", owner["entryHash"] == SHA256.hash(data: try Data(contentsOf: plugin)).map({ String(format: "%02x", $0) }).joined() else { return "conflict" }
            } else if fm.fileExists(atPath: destination.path), !fm.fileExists(atPath: ownerURL.path) { return "conflict" }
            try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)
            let configURL = destination.appendingPathComponent("config.json")
            if !fm.fileExists(atPath: configURL.path) {
                var bytes = [UInt8](repeating: 0, count: 32)
                guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return "failed" }
                let token = bytes.map { String(format: "%02x", $0) }.joined()
                try JSONEncoder().encode(Configuration(port: 0, token: token)).write(to: configURL, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            } else {
                var info = stat()
                guard lstat(configURL.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
                      info.st_mode & 0o077 == 0, info.st_size < 4096 else { return "failed" }
            }
            try runtime.write(to: destination.appendingPathComponent("runtime.mjs"), options: .atomic)
            let owner: [String: String] = ["id": "boring-notch-mimo", "version": "0.1.0",
                "entryHash": SHA256.hash(data: entry).map { String(format: "%02x", $0) }.joined()]
            try JSONSerialization.data(withJSONObject: owner).write(to: ownerURL, options: .atomic)
            try entry.write(to: plugin, options: .atomic)
            return "installed"
        } catch { return "failed" }
    }
}
