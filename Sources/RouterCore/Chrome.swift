import Foundation

public struct ChromeProfile: Equatable {
    public let dir: String
    public let name: String
    /// The Google account Chrome itself is signed in to, if any.
    public let googleEmail: String?

    public init(dir: String, name: String, googleEmail: String? = nil) {
        self.dir = dir
        self.name = name
        self.googleEmail = googleEmail
    }
}

public struct Chrome {
    public let dataDir: URL

    public init(dataDir: URL? = nil) {
        if let dataDir {
            self.dataDir = dataDir
        } else if let override = ProcessInfo.processInfo.environment["PROFILE_ROUTER_CHROME_DIR"], !override.isEmpty {
            self.dataDir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            self.dataDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        }
    }

    /// Profiles as Chrome lists them in its `Local State` file.
    public func profiles() -> [ChromeProfile] {
        guard let data = try? Data(contentsOf: dataDir.appendingPathComponent("Local State")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [] }
        let list = cache.compactMap { dir, value -> ChromeProfile? in
            guard let info = value as? [String: Any] else { return nil }
            let email = (info["user_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ChromeProfile(dir: dir, name: (info["name"] as? String) ?? dir, googleEmail: email)
        }
        return list.sorted { Chrome.order($0.dir) < Chrome.order($1.dir) }
    }

    private static func order(_ dir: String) -> Int {
        if dir == "Default" { return -1 }
        return Int(dir.replacingOccurrences(of: "Profile ", with: "")) ?? Int.max
    }

    public var nativeHostManifest: URL {
        dataDir.appendingPathComponent("NativeMessagingHosts/\(ExtensionInfo.nativeHostName).json")
    }
}

public protocol Launching {
    /// Opens a URL in a Chrome profile; `nil` means whichever profile was used last.
    func open(_ url: String, profile: String?)
}

public struct ChromeLauncher: Launching {
    public init() {}

    public static var binary: URL? {
        let candidates = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            NSHomeDirectory() + "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public func open(_ url: String, profile: String?) {
        var args: [String] = []
        if let profile { args.append("--profile-directory=\(profile)") }
        args.append(url)

        // For tests: write what would be launched instead of launching it.
        if let log = ProcessInfo.processInfo.environment["PROFILE_ROUTER_DRY_RUN"], !log.isEmpty {
            let line = args.joined(separator: " ") + "\n"
            if let handle = FileHandle(forWritingAtPath: log) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: URL(fileURLWithPath: log))
            }
            return
        }

        guard let binary = ChromeLauncher.binary else { return }
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        // The native host's stdout is its message channel to Chrome; never share it.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
