import Foundation

public struct Route: Codable, Equatable {
    /// Marks "open in whichever profile was used last" for links from other apps.
    public static let lastUsed = "*"

    public var profile: String
    public var updatedAt: Double
    /// How the route was set: picked, learned, undo, switched.
    public var source: String

    public init(profile: String, updatedAt: Double, source: String) {
        self.profile = profile
        self.updatedAt = updatedAt
        self.source = source
    }
}

public struct ProfileInfo: Codable, Equatable {
    public var paired: Bool
    public var pairedAt: Double?
    /// Provider id -> account names the extension saw signed in.
    public var accounts: [String: [String]]

    public init(paired: Bool = false, pairedAt: Double? = nil, accounts: [String: [String]] = [:]) {
        self.paired = paired
        self.pairedAt = pairedAt
        self.accounts = accounts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paired = try c.decodeIfPresent(Bool.self, forKey: .paired) ?? false
        pairedAt = try c.decodeIfPresent(Double.self, forKey: .pairedAt)
        accounts = try c.decodeIfPresent([String: [String]].self, forKey: .accounts) ?? [:]
    }
}

public struct Pairing: Codable, Equatable {
    public var token: String
    public var expiresAt: Double

    public init(token: String, expiresAt: Double) {
        self.token = token
        self.expiresAt = expiresAt
    }
}

/// A link the helper recently sent to a profile, kept briefly so that
/// re-opening it in another profile can correct the route.
public struct RecentLink: Codable, Equatable {
    public var url: String
    public var key: String
    public var profile: String
    public var at: Double
}

public struct State: Codable, Equatable {
    public var version: Int
    public var profiles: [String: ProfileInfo]
    public var routes: [String: Route]
    public var pairing: Pairing?
    public var recent: [RecentLink]

    public init() {
        version = 1
        profiles = [:]
        routes = [:]
        pairing = nil
        recent = []
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        profiles = try c.decodeIfPresent([String: ProfileInfo].self, forKey: .profiles) ?? [:]
        routes = try c.decodeIfPresent([String: Route].self, forKey: .routes) ?? [:]
        pairing = try c.decodeIfPresent(Pairing.self, forKey: .pairing)
        recent = try c.decodeIfPresent([RecentLink].self, forKey: .recent) ?? []
    }
}

/// The shared memory: one JSON file that every profile's extension and the
/// helper app read and write. Writes take a file lock, because several
/// processes can run at once.
public final class Store {
    public let dir: URL
    private var stateFile: URL { dir.appendingPathComponent("state.json") }
    private var lockFile: URL { dir.appendingPathComponent("state.lock") }

    public static var defaultDir: URL {
        if let override = ProcessInfo.processInfo.environment["PROFILE_ROUTER_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ProfileRouter", isDirectory: true)
    }

    public init(dir: URL? = nil) {
        self.dir = dir ?? Store.defaultDir
    }

    public func read() -> State {
        guard let data = try? Data(contentsOf: stateFile) else { return State() }
        if let state = try? JSONDecoder().decode(State.self, from: data) { return state }
        // Unreadable file: keep it for inspection and start clean.
        let bad = dir.appendingPathComponent("state.bad.json")
        try? FileManager.default.removeItem(at: bad)
        try? FileManager.default.moveItem(at: stateFile, to: bad)
        return State()
    }

    @discardableResult
    public func update<T>(_ body: (inout State) -> T) -> T {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fd = open(lockFile.path, O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer {
            if fd >= 0 {
                flock(fd, LOCK_UN)
                close(fd)
            }
        }
        var state = read()
        let before = state
        let result = body(&state)
        if state != before {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(state) {
                try? data.write(to: stateFile, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFile.path)
            }
        }
        return result
    }
}
