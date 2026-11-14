import Foundation

/// A profile offered in a picker.
public struct Choice: Equatable {
    public let dir: String
    public let name: String
    public let accounts: [String]
}

/// Accounts known for a provider in each profile, best matches first.
func choices(for providerId: String?, profiles: [ChromeProfile], state: State) -> [Choice] {
    let all = profiles.map { profile -> Choice in
        var accounts: [String] = []
        if let providerId {
            if providerId == "google", let email = profile.googleEmail { accounts.append(email) }
            for account in state.profiles[profile.dir]?.accounts[providerId] ?? [] where !accounts.contains(account) {
                accounts.append(account)
            }
        }
        return Choice(dir: profile.dir, name: profile.name, accounts: accounts)
    }
    return all.filter { !$0.accounts.isEmpty } + all.filter { $0.accounts.isEmpty }
}

/// Answers the extension's messages. Every routing decision for sign-ins that
/// start inside Chrome is made here, so the extension only reports and obeys.
public final class HostService {
    /// How long a link the helper routed can still be corrected by re-opening it elsewhere.
    public static let switchWindow: Double = 120

    private let store: Store
    private let profiles: () -> [ChromeProfile]
    private let launcher: Launching
    private let now: () -> Double

    public init(store: Store,
                profiles: @escaping () -> [ChromeProfile],
                launcher: Launching,
                now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.store = store
        self.profiles = profiles
        self.launcher = launcher
        self.now = now
    }

    public func handle(_ message: [String: Any]) -> [String: Any] {
        switch message["type"] as? String {
        case "hello": return ["ok": true, "version": ExtensionInfo.version]
        case "pair": return pair(message)
        case "authStart": return authStart(message)
        case "choose": return choose(message)
        case "authDone": return learn(message, source: "learned")
        case "undo": return learn(message, source: "undo")
        case "accounts": return accounts(message)
        default: return ["error": "unknown message type"]
        }
    }

    static func key(provider: String, site: String) -> String {
        "\(provider)|site:\(site)"
    }

    private func pair(_ m: [String: Any]) -> [String: Any] {
        guard let dir = m["dir"] as? String, let token = m["token"] as? String,
              let profile = profiles().first(where: { $0.dir == dir }) else {
            return ["ok": false, "error": "unknown profile"]
        }
        let t = now()
        let ok = store.update { state -> Bool in
            guard let pairing = state.pairing, pairing.token == token, pairing.expiresAt > t else { return false }
            var info = state.profiles[dir] ?? ProfileInfo()
            info.paired = true
            info.pairedAt = t
            state.profiles[dir] = info
            return true
        }
        return ok ? ["ok": true, "dir": dir, "name": profile.name]
                  : ["ok": false, "error": "pairing code expired; run setup again"]
    }

    private func authStart(_ m: [String: Any]) -> [String: Any] {
        let stay: [String: Any] = ["action": "stay"]
        guard let profile = m["profile"] as? String,
              let providerId = m["provider"] as? String, let provider = Providers.byId(providerId),
              let authUrl = m["authUrl"] as? String else { return stay }
        let t = now()

        // A link the helper sent to a profile is already decided. Seeing it in a
        // different profile means it was moved by hand: remember that instead.
        let wasRouted = store.update { state -> Bool in
            guard let i = state.recent.lastIndex(where: { $0.url == authUrl && t - $0.at <= HostService.switchWindow }) else {
                return false
            }
            if state.recent[i].profile != profile {
                state.routes[state.recent[i].key] = Route(profile: profile, updatedAt: t, source: "switched")
                state.recent[i].profile = profile
            }
            return true
        }
        if wasRouted { return stay }

        // Which site is asking? The page that started the navigation, unless
        // that is the provider itself.
        let pageUrl = m["pageUrl"] as? String
        let site: String
        if let initiator = Sites.site(of: m["initiator"] as? String) {
            guard !Sites.belongs(initiator, to: provider.own) else { return stay }
            site = initiator
        } else if let page = Sites.site(of: pageUrl), !Sites.belongs(page, to: provider.own) {
            site = page
        } else {
            return stay
        }
        let reopen = Sites.site(of: pageUrl) == site ? pageUrl! : "https://\(site)/"
        var reply: [String: Any] = ["site": site, "pageUrl": reopen]

        let all = profiles()
        let state = store.read()
        if let route = state.routes[HostService.key(provider: provider.id, site: site)],
           let target = all.first(where: { $0.dir == route.profile }) {
            if target.dir == profile {
                reply["action"] = "stay"
            } else {
                launcher.open(reopen, profile: target.dir)
                reply["action"] = "move"
                reply["profile"] = target.dir
                reply["name"] = target.name
            }
            return reply
        }

        reply["action"] = "ask"
        reply["choices"] = choices(for: provider.id, profiles: all, state: state).map {
            ["dir": $0.dir, "name": $0.name, "accounts": $0.accounts, "current": $0.dir == profile] as [String: Any]
        }
        return reply
    }

    private func choose(_ m: [String: Any]) -> [String: Any] {
        guard let profile = m["profile"] as? String, let provider = m["provider"] as? String,
              let site = m["site"] as? String, let chosen = m["chosen"] as? String,
              let target = profiles().first(where: { $0.dir == chosen }) else {
            return ["action": "stay", "error": "unknown profile"]
        }
        let t = now()
        store.update { $0.routes[HostService.key(provider: provider, site: site)] = Route(profile: chosen, updatedAt: t, source: "picked") }
        guard chosen != profile else { return ["action": "stay"] }
        let pageUrl = m["pageUrl"] as? String
        launcher.open(Sites.site(of: pageUrl) == site ? pageUrl! : "https://\(site)/", profile: chosen)
        return ["action": "move", "profile": chosen, "name": target.name]
    }

    /// Latest wins: the profile where a sign-in finished, or where Undo was pressed.
    private func learn(_ m: [String: Any], source: String) -> [String: Any] {
        guard let profile = m["profile"] as? String, let provider = m["provider"] as? String,
              let site = m["site"] as? String else { return ["ok": false] }
        let t = now()
        store.update { $0.routes[HostService.key(provider: provider, site: site)] = Route(profile: profile, updatedAt: t, source: source) }
        return ["ok": true]
    }

    private func accounts(_ m: [String: Any]) -> [String: Any] {
        guard let profile = m["profile"] as? String, let provider = m["provider"] as? String,
              let list = m["accounts"] as? [String] else { return ["ok": false] }
        store.update { state in
            var info = state.profiles[profile] ?? ProfileInfo()
            info.accounts[provider] = list
            state.profiles[profile] = info
        }
        return ["ok": true]
    }
}

/// Chrome's native messaging framing: a 4-byte little-endian length, then JSON.
public enum NativeMessaging {
    public static func read(from handle: FileHandle) -> [String: Any]? {
        guard let header = readExactly(4, from: handle) else { return nil }
        let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard length > 0, length <= 1_048_576, let body = readExactly(length, from: handle) else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    public static func write(_ message: [String: Any], to handle: FileHandle) {
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        var length = UInt32(body.count).littleEndian
        var data = Data(bytes: &length, count: 4)
        data.append(body)
        handle.write(data)
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) -> Data? {
        var data = Data()
        while data.count < count {
            guard let chunk = try? handle.read(upToCount: count - data.count), !chunk.isEmpty else { return nil }
            data.append(chunk)
        }
        return data
    }
}
