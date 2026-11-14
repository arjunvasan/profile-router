import AppKit
import RouterCore

enum CLI {
    static let help = """
    profile-router: send every sign-in to the right Chrome profile

      setup [--no-default-browser]   install the helper and pair the extension in each profile
      status                         show profiles, pairing, known accounts and remembered routes
      forget <text> | --all          forget routes whose site or key contains <text>
      route <url>                    show what would happen to a link opened from another app
      help
    """

    static func run(_ command: String, _ args: [String]) -> Int32 {
        switch command {
        case "setup": return Setup.run(defaultBrowser: !args.contains("--no-default-browser"))
        case "status": return status()
        case "forget": return forget(args)
        case "route": return route(args)
        case "help", "--help", "-h":
            print(help)
            return 0
        default:
            print("Unknown command: \(command)\n\n\(help)")
            return 2
        }
    }

    static var installedApp: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/ProfileRouter.app")
    }

    static func isDefaultBrowser() -> Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return false }
        return Bundle(url: handler)?.bundleIdentifier == "com.profilerouter.app"
    }

    private static func status() -> Int32 {
        let chrome = Chrome()
        let state = Store().read()
        let profiles = chrome.profiles()

        print("Helper installed:   \(FileManager.default.fileExists(atPath: installedApp.path) ? "yes" : "no")")
        print("Default browser:    \(isDefaultBrowser() ? "yes" : "no (links from other apps are not routed)")")
        print("Chrome can reach it: \(FileManager.default.fileExists(atPath: chrome.nativeHostManifest.path) ? "yes" : "no")")

        print("\nProfiles")
        for profile in profiles {
            let info = state.profiles[profile.dir]
            var accounts: [String] = []
            if let email = profile.googleEmail { accounts.append("google: \(email)") }
            for (provider, names) in (info?.accounts ?? [:]).sorted(by: { $0.key < $1.key }) where !names.isEmpty {
                accounts.append("\(provider): \(names.joined(separator: ", "))")
            }
            let paired = info?.paired == true ? "paired    " : "not paired"
            print("  \(profile.name.padding(toLength: 18, withPad: " ", startingAt: 0)) \(paired)  \(accounts.joined(separator: "; "))")
        }

        print("\nRemembered routes (\(state.routes.count))")
        let names = Dictionary(uniqueKeysWithValues: profiles.map { ($0.dir, $0.name) })
        for (key, route) in state.routes.sorted(by: { $0.key < $1.key }) {
            let target = route.profile == Route.lastUsed ? "last-used profile" : (names[route.profile] ?? "\(route.profile) (deleted)")
            print("  \(key.padding(toLength: 44, withPad: " ", startingAt: 0)) -> \(target)")
        }
        return 0
    }

    private static func forget(_ args: [String]) -> Int32 {
        guard let text = args.first else {
            print("Say which site to forget, or --all.")
            return 2
        }
        let removed = Store().update { state -> [String] in
            let keys = state.routes.keys.filter { text == "--all" || $0.contains(text) }
            keys.forEach { state.routes.removeValue(forKey: $0) }
            return keys.sorted()
        }
        print(removed.isEmpty ? "Nothing matched." : "Forgot:\n  " + removed.joined(separator: "\n  "))
        return 0
    }

    private static func route(_ args: [String]) -> Int32 {
        guard let text = args.first, let url = URL(string: text) else {
            print("Give a URL.")
            return 2
        }
        let chrome = Chrome()
        let router = LinkRouter(store: Store(), profiles: { chrome.profiles() }, launcher: ChromeLauncher())
        switch router.decide(url) {
        case .open(nil, _): print("Opens in the last-used profile.")
        case let .open(profile?, _):
            print("Opens in \(chrome.profiles().first { $0.dir == profile }?.name ?? profile).")
        case let .ask(key, label, _): print("Asks which profile (\(label)), then remembers it as \(key).")
        }
        return 0
    }
}
