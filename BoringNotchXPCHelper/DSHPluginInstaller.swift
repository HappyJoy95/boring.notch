import Foundation


enum DSHPluginInstaller {
    static func install(packageURL: URL, scriptURL: URL?, appURL: URL?, isRunning: Bool) -> String {
        guard let appURL else { return "missing" }
        guard Bundle(url: appURL)?.bundleIdentifier == "io.dsh.desktop" else { return "unsupported" }
        guard let scriptURL else { return "unsupported" }
        let runtime = appURL.appendingPathComponent("Contents/Resources/app.asar.unpacked")
        let node = runtime.appendingPathComponent("node_modules/node/bin/node")
        let manager = runtime.appendingPathComponent("node_modules/dsh-desktop-market-installer/generations")
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: node.path),
              ["installer", "registry", "projection"].allSatisfy({ fm.fileExists(atPath: manager.appendingPathComponent($0 + ".mjs").path) }) else { return "unsupported" }
        let stage = fm.temporaryDirectory.appendingPathComponent("boring-dsh-install-" + UUID().uuidString)
        do {
            try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: stage) }
            let unpack = Process()
            unpack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unpack.arguments = ["-x", "-k", packageURL.path, stage.path]
            unpack.standardOutput = FileHandle.nullDevice
            unpack.standardError = FileHandle.nullDevice
            try unpack.run()
            unpack.waitUntilExit()
            guard unpack.terminationStatus == 0 else { return "failed" }
            let logURL = stage.appendingPathComponent("install-result.txt")
            fm.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let output = try FileHandle(forWritingTo: logURL)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = node
            let dshHome = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/dsh-desktop/harness", isDirectory: true)
            let webProfile = dshHome.appendingPathComponent("profiles/web/package.json")
            guard fm.fileExists(atPath: webProfile.path) else { return "not-initialized" }
            process.arguments = [scriptURL.path, runtime.path,
                stage.appendingPathComponent("boring-notch-dsh-0.3.0").path,
                dshHome.path,
                isRunning ? "running" : "stopped"]
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
            environment["CI"] = "true"
            environment["NO_COLOR"] = "1"
            environment["PATH"] = node.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            let result = (try String(contentsOf: logURL, encoding: .utf8)).split(separator: "\n").last.map(String.init) ?? "unknown"
            if process.terminationStatus == 0 && result == "installed" { return "installed" }
            return ["quit-required", "failed"].contains(result) ? result : "unknown"
        } catch { return "failed" }
    }
}
