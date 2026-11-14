import CryptoKit
import XCTest
@testable import RouterCore

final class MockLauncher: Launching {
    var opened: [(url: String, profile: String?)] = []
    func open(_ url: String, profile: String?) { opened.append((url, profile)) }
}

let testProfiles = [
    ChromeProfile(dir: "Default", name: "Personal", googleEmail: "me@example.com"),
    ChromeProfile(dir: "Profile 1", name: "Work", googleEmail: "me@work.example"),
    ChromeProfile(dir: "Profile 2", name: "Test", googleEmail: nil),
]

func tempStore() -> Store {
    Store(dir: FileManager.default.temporaryDirectory.appendingPathComponent("profile-router-" + UUID().uuidString))
}

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

final class ProvidersTests: XCTestCase {
    func testMatchesSignInPages() {
        func id(_ s: String) -> String? { Providers.match(URL(string: s)!)?.id }
        XCTAssertEqual(id("https://accounts.google.com/o/oauth2/v2/auth?client_id=x"), "google")
        XCTAssertEqual(id("https://accounts.google.com/gsi/select?client_id=x"), "google")
        XCTAssertEqual(id("https://github.com/login/oauth/authorize?client_id=x"), "github")
        XCTAssertEqual(id("https://github.com/login/device"), "github")
        XCTAssertEqual(id("https://login.microsoftonline.com/common/oauth2/v2.0/authorize?x=1"), "microsoft")
        XCTAssertEqual(id("https://appleid.apple.com/auth/authorize"), "apple")
        XCTAssertEqual(id("https://gitlab.com/oauth/authorize"), "gitlab")
        XCTAssertEqual(id("https://slack.com/oauth/v2/authorize"), "slack")
    }

    func testIgnoresOtherPages() {
        func id(_ s: String) -> String? { Providers.match(URL(string: s)!)?.id }
        XCTAssertNil(id("https://github.com/login"))
        XCTAssertNil(id("https://github.com/anthropics/claude-code"))
        XCTAssertNil(id("https://accounts.google.com/ServiceLogin"))
        XCTAssertNil(id("http://github.com/login/oauth/authorize"))
        XCTAssertNil(id("https://evil.example/login/oauth/authorize"))
    }

    func testSwiftTableMatchesExtensionFile() throws {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("extension/providers.json"))
        XCTAssertEqual(try JSONDecoder().decode([Provider].self, from: data), Providers.all)
    }

    func testManifestAgreesWithHelper() throws {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("extension/manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // The extension ID Chrome derives from the manifest key is the one the native host allows.
        let key = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(manifest["key"] as? String)))
        let letters = Array("abcdefghijklmnop")
        let id = SHA256.hash(data: key).prefix(16).map { "\(letters[Int($0 >> 4)])\(letters[Int($0 & 15)])" }.joined()
        XCTAssertEqual(id, ExtensionInfo.id)

        // The extension can only watch providers it has host access to.
        let hosts = try XCTUnwrap(manifest["host_permissions"] as? [String])
        for match in Providers.all.flatMap(\.matches) {
            XCTAssertTrue(hosts.contains("https://\(match.host)/*"), "manifest lacks \(match.host)")
        }
        XCTAssertEqual(manifest["version"] as? String, ExtensionInfo.version)
    }
}

final class StoreTests: XCTestCase {
    func testConcurrentWritersLoseNothing() {
        let dir = tempStore().dir
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            Store(dir: dir).update { $0.routes["k\(i)"] = Route(profile: "Default", updatedAt: Double(i), source: "picked") }
        }
        XCTAssertEqual(Store(dir: dir).read().routes.count, 40)
    }

    func testUnreadableFileStartsClean() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(at: store.dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.dir.appendingPathComponent("state.json"))
        XCTAssertEqual(store.read(), State())
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.dir.appendingPathComponent("state.bad.json").path))
    }
}

final class HostServiceTests: XCTestCase {
    var store: Store!
    var launcher: MockLauncher!
    var clock: Double = 1000
    var host: HostService!

    override func setUp() {
        store = tempStore()
        launcher = MockLauncher()
        clock = 1000
        host = HostService(store: store, profiles: { testProfiles }, launcher: launcher, now: { [unowned self] in self.clock })
    }

    func start(in profile: String, page: String? = "https://app.example.com/login", initiator: String? = "https://app.example.com",
               auth: String = "https://github.com/login/oauth/authorize?client_id=abc", provider: String = "github") -> [String: Any] {
        var m: [String: Any] = ["type": "authStart", "profile": profile, "provider": provider, "authUrl": auth]
        if let page { m["pageUrl"] = page }
        if let initiator { m["initiator"] = initiator }
        return host.handle(m)
    }

    func testUnknownSiteAsksAndListsProfiles() {
        store.update { $0.profiles["Profile 1"] = ProfileInfo(paired: true, accounts: ["github": ["octocat"]]) }
        let reply = start(in: "Default")
        XCTAssertEqual(reply["action"] as? String, "ask")
        XCTAssertEqual(reply["site"] as? String, "app.example.com")
        let choices = reply["choices"] as! [[String: Any]]
        XCTAssertEqual(choices.map { $0["dir"] as! String }, ["Profile 1", "Default", "Profile 2"])
        XCTAssertEqual(choices[0]["accounts"] as? [String], ["octocat"])
        XCTAssertEqual(choices[1]["current"] as? Bool, true)
        XCTAssertTrue(launcher.opened.isEmpty)
    }

    func testChoosingAnotherProfileMovesAndRemembers() {
        let reply = host.handle(["type": "choose", "profile": "Default", "provider": "github", "site": "app.example.com",
                                 "pageUrl": "https://app.example.com/login", "chosen": "Profile 1"])
        XCTAssertEqual(reply["action"] as? String, "move")
        XCTAssertEqual(reply["name"] as? String, "Work")
        XCTAssertEqual(launcher.opened.first?.url, "https://app.example.com/login")
        XCTAssertEqual(launcher.opened.first?.profile, "Profile 1")

        // Next time: moved from the wrong profile, left alone in the right one.
        let wrong = start(in: "Default")
        XCTAssertEqual(wrong["action"] as? String, "move")
        XCTAssertEqual(wrong["profile"] as? String, "Profile 1")
        XCTAssertEqual(launcher.opened.count, 2)
        XCTAssertEqual(start(in: "Profile 1")["action"] as? String, "stay")
        XCTAssertEqual(launcher.opened.count, 2)
    }

    func testChoosingThisProfileStays() {
        let reply = host.handle(["type": "choose", "profile": "Default", "provider": "github", "site": "app.example.com", "chosen": "Default"])
        XCTAssertEqual(reply["action"] as? String, "stay")
        XCTAssertTrue(launcher.opened.isEmpty)
        XCTAssertEqual(start(in: "Default")["action"] as? String, "stay")
    }

    func testLatestSignInWins() {
        _ = host.handle(["type": "authDone", "profile": "Default", "provider": "github", "site": "app.example.com"])
        XCTAssertEqual(start(in: "Profile 1")["profile"] as? String, "Default")
        clock += 10
        _ = host.handle(["type": "authDone", "profile": "Profile 1", "provider": "github", "site": "app.example.com"])
        XCTAssertEqual(start(in: "Profile 1")["action"] as? String, "stay")
        XCTAssertEqual(start(in: "Default")["profile"] as? String, "Profile 1")
    }

    func testUndoSendsFutureSignInsBack() {
        _ = host.handle(["type": "authDone", "profile": "Profile 1", "provider": "github", "site": "app.example.com"])
        XCTAssertEqual(start(in: "Default")["action"] as? String, "move")
        _ = host.handle(["type": "undo", "profile": "Default", "provider": "github", "site": "app.example.com"])
        XCTAssertEqual(start(in: "Default")["action"] as? String, "stay")
        XCTAssertEqual(store.read().routes["github|site:app.example.com"]?.source, "undo")
    }

    func testRoutesAreKeptPerProvider() {
        _ = host.handle(["type": "authDone", "profile": "Profile 1", "provider": "github", "site": "app.example.com"])
        let reply = start(in: "Default", auth: "https://accounts.google.com/o/oauth2/v2/auth?client_id=1", provider: "google")
        XCTAssertEqual(reply["action"] as? String, "ask")
        let choices = reply["choices"] as! [[String: Any]]
        XCTAssertEqual(choices[0]["accounts"] as? [String], ["me@example.com"])
    }

    func testProviderTalkingToItselfIsIgnored() {
        XCTAssertNil(start(in: "Default", page: "https://github.com/login", initiator: "https://github.com")["site"])
        // The provider's own page started it, even though an older site page is on record.
        XCTAssertNil(start(in: "Default", initiator: "https://github.com")["site"])
        XCTAssertNil(start(in: "Default", page: nil, initiator: nil)["site"])
        XCTAssertNil(start(in: "Default", page: "https://mail.google.com/", initiator: nil,
                           auth: "https://accounts.google.com/o/oauth2/auth", provider: "google")["site"])
    }

    func testOneProviderCanSignInToAnother() {
        let reply = start(in: "Default", page: "https://gitlab.com/users/sign_in", initiator: "https://gitlab.com",
                          auth: "https://accounts.google.com/o/oauth2/auth", provider: "google")
        XCTAssertEqual(reply["site"] as? String, "gitlab.com")
    }

    func testFallsBackToThePageWhenInitiatorIsHidden() {
        let reply = start(in: "Default", page: "https://www.example.com/pricing?x=1", initiator: nil)
        XCTAssertEqual(reply["site"] as? String, "example.com")
        XCTAssertEqual(reply["pageUrl"] as? String, "https://www.example.com/pricing?x=1")
    }

    func testReopensSiteRootWhenPageIsElsewhere() {
        let reply = start(in: "Default", page: "https://other.example/x", initiator: "https://app.example.com")
        XCTAssertEqual(reply["pageUrl"] as? String, "https://app.example.com/")
    }

    func testRouteToDeletedProfileAsksAgain() {
        store.update { $0.routes["github|site:app.example.com"] = Route(profile: "Profile 9", updatedAt: 1, source: "picked") }
        XCTAssertEqual(start(in: "Default")["action"] as? String, "ask")
    }

    func testPairingNeedsTheSetupToken() {
        store.update { $0.pairing = Pairing(token: "secret", expiresAt: 2000) }
        XCTAssertEqual(host.handle(["type": "pair", "dir": "Profile 1", "token": "wrong"])["ok"] as? Bool, false)
        XCTAssertEqual(host.handle(["type": "pair", "dir": "Profile 7", "token": "secret"])["ok"] as? Bool, false)
        let ok = host.handle(["type": "pair", "dir": "Profile 1", "token": "secret"])
        XCTAssertEqual(ok["ok"] as? Bool, true)
        XCTAssertEqual(ok["name"] as? String, "Work")
        XCTAssertEqual(store.read().profiles["Profile 1"]?.paired, true)
        clock = 3000
        XCTAssertEqual(host.handle(["type": "pair", "dir": "Default", "token": "secret"])["ok"] as? Bool, false)
    }

    func testAccountsAreStoredPerProfile() {
        _ = host.handle(["type": "accounts", "profile": "Profile 2", "provider": "github", "accounts": ["octocat"]])
        XCTAssertEqual(store.read().profiles["Profile 2"]?.accounts["github"], ["octocat"])
    }

    func testLinkReopenedInAnotherProfileCorrectsTheRoute() {
        let links = LinkRouter(store: store, profiles: { testProfiles }, launcher: launcher, now: { [unowned self] in self.clock })
        let url = URL(string: "https://github.com/login/oauth/authorize?client_id=cli")!
        links.open(url, key: "github|client:cli", profile: "Default", remember: true)

        // Seen where the helper sent it: nothing changes, and no picker.
        XCTAssertNil(start(in: "Default", page: nil, initiator: nil, auth: url.absoluteString)["site"])
        XCTAssertEqual(store.read().routes["github|client:cli"]?.profile, "Default")

        clock += 30
        XCTAssertEqual(start(in: "Profile 1", page: nil, initiator: nil, auth: url.absoluteString)["action"] as? String, "stay")
        XCTAssertEqual(store.read().routes["github|client:cli"]?.profile, "Profile 1")
        XCTAssertEqual(links.decide(url), .open(profile: "Profile 1", key: "github|client:cli"))
    }

    func testOldLinksAreNotCorrected() {
        let links = LinkRouter(store: store, profiles: { testProfiles }, launcher: launcher, now: { [unowned self] in self.clock })
        let url = URL(string: "https://github.com/login/device")!
        links.open(url, key: "github|path:/login/device", profile: "Default", remember: true)
        clock += 500
        _ = start(in: "Profile 1", page: nil, initiator: nil, auth: url.absoluteString)
        XCTAssertEqual(store.read().routes["github|path:/login/device"]?.profile, "Default")
    }
}

final class LinkRouterTests: XCTestCase {
    var store: Store!
    var launcher: MockLauncher!
    var links: LinkRouter!

    override func setUp() {
        store = tempStore()
        launcher = MockLauncher()
        links = LinkRouter(store: store, profiles: { testProfiles }, launcher: launcher, now: { 1000 })
    }

    func testPlainLinksPassThrough() {
        for s in ["https://example.com", "https://github.com/anthropics/claude-code", "https://news.ycombinator.com/item?id=1"] {
            XCTAssertEqual(links.decide(URL(string: s)!), .open(profile: nil, key: nil), s)
        }
    }

    func testSignInLinksAreKeyed() {
        XCTAssertEqual(links.classify(URL(string: "https://accounts.google.com/o/oauth2/auth?client_id=gcloud&redirect_uri=http://localhost:8085")!)?.key,
                       "google|client:gcloud")
        XCTAssertEqual(links.classify(URL(string: "https://github.com/login/device")!)?.key, "github|path:/login/device")
        XCTAssertEqual(links.classify(URL(string: "https://claude.ai/oauth/authorize?code_challenge=x")!)?.key, "link|site:claude.ai")
        XCTAssertEqual(links.classify(URL(string: "https://www.vercel.com/api/x?user_code=ABCD")!)?.key, "link|site:vercel.com")
    }

    func testAsksOnceThenRemembers() {
        let url = URL(string: "https://github.com/login/device")!
        XCTAssertEqual(links.decide(url), .ask(key: "github|path:/login/device", label: "GitHub sign-in", providerId: "github"))
        links.open(url, key: "github|path:/login/device", profile: "Profile 1", remember: true)
        XCTAssertEqual(launcher.opened.last?.profile, "Profile 1")
        XCTAssertEqual(links.decide(url), .open(profile: "Profile 1", key: "github|path:/login/device"))
        // Holding Option asks again.
        XCTAssertEqual(links.decide(url, forceAsk: true), .ask(key: "github|path:/login/device", label: "GitHub sign-in", providerId: "github"))
    }

    func testRememberingLastUsedProfile() {
        let url = URL(string: "https://claude.ai/oauth/authorize")!
        links.open(url, key: "link|site:claude.ai", profile: nil, remember: true)
        XCTAssertNil(launcher.opened.last?.profile)
        XCTAssertEqual(links.decide(url), .open(profile: nil, key: "link|site:claude.ai"))
        XCTAssertTrue(store.read().recent.isEmpty)
    }

    func testOpeningOnceDoesNotRemember() {
        let url = URL(string: "https://claude.ai/oauth/authorize")!
        links.open(url, key: "link|site:claude.ai", profile: "Default", remember: false)
        XCTAssertNil(store.read().routes["link|site:claude.ai"])
    }
}
