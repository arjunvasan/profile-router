import Foundation

/// What to do with a link another app (terminal, Slack, mail) asked to open.
public enum LinkDecision: Equatable {
    /// Open it; `profile` nil means whichever profile was used last.
    case open(profile: String?, key: String?)
    /// A sign-in with no memory yet: ask which profile.
    case ask(key: String, label: String, providerId: String?)
}

public final class LinkRouter {
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

    private static let signInWords: Set<String> = [
        "oauth", "oauth2", "authorize", "auth", "login", "signin", "sign-in", "sign_in",
        "sso", "device", "activate", "magic-link", "verify",
    ]
    private static let signInParams: Set<String> = [
        "client_id", "redirect_uri", "code_challenge", "user_code", "device_code", "response_type",
    ]

    /// A memory key for links that are sign-ins; nil for every other link.
    public func classify(_ url: URL) -> (key: String, label: String, providerId: String?)? {
        guard let site = Sites.site(of: url.absoluteString) else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        if let provider = Providers.match(url) {
            // A command-line tool's sign-in: one app (client) signs in to one account.
            if let client = items.first(where: { $0.name == "client_id" })?.value, !client.isEmpty {
                return ("\(provider.id)|client:\(client)", "\(provider.name) sign-in", provider.id)
            }
            return ("\(provider.id)|path:\(url.path)", "\(provider.name) sign-in", provider.id)
        }

        let words = url.path.lowercased().split(separator: "/").map(String.init)
        let looksLikeSignIn = words.contains { LinkRouter.signInWords.contains($0) }
            || items.contains { LinkRouter.signInParams.contains($0.name) }
        return looksLikeSignIn ? ("link|site:\(site)", site, nil) : nil
    }

    public func decide(_ url: URL, forceAsk: Bool = false) -> LinkDecision {
        guard let kind = classify(url) else { return .open(profile: nil, key: nil) }
        let ask = LinkDecision.ask(key: kind.key, label: kind.label, providerId: kind.providerId)
        if forceAsk { return ask }
        guard let route = store.read().routes[kind.key] else { return ask }
        if route.profile == Route.lastUsed { return .open(profile: nil, key: kind.key) }
        guard profiles().contains(where: { $0.dir == route.profile }) else { return ask }
        return .open(profile: route.profile, key: kind.key)
    }

    public func choices(providerId: String?) -> [Choice] {
        RouterCore.choices(for: providerId, profiles: profiles(), state: store.read())
    }

    /// Opens the link and, when asked, remembers the profile for its key.
    public func open(_ url: URL, key: String?, profile: String?, remember: Bool) {
        let t = now()
        if let key {
            store.update { state in
                if remember {
                    state.routes[key] = Route(profile: profile ?? Route.lastUsed, updatedAt: t, source: "picked")
                }
                if let profile {
                    state.recent.append(RecentLink(url: url.absoluteString, key: key, profile: profile, at: t))
                    state.recent = Array(state.recent.suffix(20))
                }
            }
        }
        launcher.open(url.absoluteString, profile: profile)
    }
}
