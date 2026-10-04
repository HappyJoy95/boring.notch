import Darwin
import Foundation

enum CodexQuotaReader {
    private static let responseTimeout: TimeInterval = 5

    static func read() throws -> Data {
        let process = Process()
        process.executableURL = try codexExecutable()
        process.arguments = ["app-server"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }

        try write([
            "method": "initialize",
            "id": 1,
            "params": [
                "clientInfo": ["name": "boring-notch", "title": "Boring Notch", "version": "0.1.0"],
                "capabilities": [:] as [String: String],
            ],
        ], to: input.fileHandleForWriting)
        _ = try readResponse(id: 1, from: output.fileHandleForReading)

        try write(["method": "initialized", "params": [:] as [String: String]], to: input.fileHandleForWriting)
        try write([
            "method": "account/rateLimits/read",
            "id": 2,
            "params": [:] as [String: String],
        ], to: input.fileHandleForWriting)
        let response = try readResponse(id: 2, from: output.fileHandleForReading)
        guard
            let result = response["result"] as? [String: Any],
            let limits = result["rateLimitsByLimitId"] as? [String: Any],
            let codex = limits["codex"]
        else {
            throw ReaderError.invalidResponse
        }

        // Return only Codex quota windows; account identifiers and unrelated account data stay in the helper.
        return try JSONSerialization.data(withJSONObject: ["rateLimitsByLimitId": ["codex": codex]])
    }

    private static func codexExecutable() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let knownPaths = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex").path,
        ]
        if let path = knownPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if let path = searchPath.split(separator: ":")
            .map({ URL(fileURLWithPath: String($0)).appendingPathComponent("codex").path })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        throw ReaderError.codexNotFound
    }

    private static func write(_ object: [String: Any], to handle: FileHandle) throws {
        var line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        line.append(0x0A)
        try handle.write(contentsOf: line)
    }

    private static func readResponse(id expectedID: Int, from handle: FileHandle) throws -> [String: Any] {
        let descriptor = handle.fileDescriptor
        var buffer = Data()
        let deadline = Date().addingTimeInterval(responseTimeout)

        while Date() < deadline {
            let remainingMilliseconds = max(1, Int32(deadline.timeIntervalSinceNow * 1_000))
            var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let pollResult = Darwin.poll(&readiness, 1, remainingMilliseconds)
            if pollResult == 0 { throw ReaderError.timedOut }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw ReaderError.invalidResponse
            }

            var bytes = [UInt8](repeating: 0, count: 4_096)
            let readCount = bytes.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            guard readCount > 0 else { throw ReaderError.invalidResponse }
            buffer.append(contentsOf: bytes.prefix(readCount))

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard
                    let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                    (message["id"] as? NSNumber)?.intValue == expectedID
                else { continue }
                if message["error"] != nil { throw ReaderError.serverRejected }
                return message
            }
        }
        throw ReaderError.timedOut
    }

    private enum ReaderError: Error {
        case codexNotFound
        case timedOut
        case invalidResponse
        case serverRejected
    }
}
