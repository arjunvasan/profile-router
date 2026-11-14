import Foundation

public struct ProviderMatch: Codable, Equatable {
    public let host: String
    /// Regular expression tested against the URL path.
    public let path: String
}

/// A sign-in provider ("Sign in with ...") and the URLs where its sign-in starts.
public struct Provider: Codable, Equatable {
    public let id: String
    public let name: String
    /// The provider's own domains. A sign-in started from one of these is the
    /// provider talking to itself, not a site asking to sign in.
    public let own: [String]
    public let matches: [ProviderMatch]
}

public enum Providers {
    /// Kept identical to `extension/providers.json`; a test fails if they drift.
    public static let all: [Provider] = [
        Provider(id: "google", name: "Google", own: ["google.com", "youtube.com"], matches: [
            ProviderMatch(host: "accounts.google.com", path: "^/(o/oauth2/|signin/oauth|gsi/select)"),
        ]),
        Provider(id: "github", name: "GitHub", own: ["github.com"], matches: [
            ProviderMatch(host: "github.com", path: "^/login/(oauth/authorize|device)"),
        ]),
        Provider(id: "microsoft", name: "Microsoft", own: ["microsoftonline.com", "live.com", "microsoft.com", "office.com"], matches: [
            ProviderMatch(host: "login.microsoftonline.com", path: "^/[^/]+/oauth2/(v2\\.0/)?(authorize|devicecode)"),
            ProviderMatch(host: "login.live.com", path: "^/oauth20_authorize\\.srf"),
        ]),
        Provider(id: "apple", name: "Apple", own: ["apple.com", "icloud.com"], matches: [
            ProviderMatch(host: "appleid.apple.com", path: "^/auth/authorize"),
        ]),
        Provider(id: "gitlab", name: "GitLab", own: ["gitlab.com"], matches: [
            ProviderMatch(host: "gitlab.com", path: "^/oauth/authorize"),
        ]),
        Provider(id: "slack", name: "Slack", own: ["slack.com"], matches: [
            ProviderMatch(host: "slack.com", path: "^/(oauth/(v2/)?authorize|openid/connect/authorize)"),
        ]),
    ]

    public static func byId(_ id: String) -> Provider? {
        all.first { $0.id == id }
    }

    /// The provider whose sign-in page this URL is, if any.
    public static func match(_ url: URL) -> Provider? {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        for provider in all {
            for m in provider.matches where m.host == host {
                if path.range(of: m.path, options: .regularExpression) != nil { return provider }
            }
        }
        return nil
    }
}

public enum Sites {
    /// The site a URL belongs to: its host, lowercased, without a leading "www.".
    public static func site(of urlString: String?) -> String? {
        guard let urlString, let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    public static func belongs(_ site: String, to domains: [String]) -> Bool {
        domains.contains { site == $0 || site.hasSuffix("." + $0) }
    }
}

public enum ExtensionInfo {
    /// Derived from the `key` in `extension/manifest.json`; a test checks the two agree.
    public static let id = "cpjnaecmgjcmcfphjdbcbaoenlhdecdd"
    public static let nativeHostName = "com.profilerouter.host"
    public static let pairHost = "pair.profile-router.invalid"
    public static let version = "0.1.0"
}
