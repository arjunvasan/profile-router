import AppKit
import RouterCore

/// Installs the helper and pairs the extension in every Chrome profile.
/// Safe to run again: it only redoes what is missing.
enum Setup {
    static func run(defaultBrowser: Bool) -> Int32 {
        let fm = FileManager.default
        let chrome = Chrome()
        let store = Store()
        let app = CLI.installedApp

        // 1. The app itself.
        let running = Bundle.main.bundleURL
        guard running.pathExtension == "app" else {
            print("Run setup through bin/profile-router so the app is built first.")
            return 1
        }
        if running.standardizedFileURL != app.standardizedFileURL {
            try? fm.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: app)
            do { try fm.copyItem(at: running, to: app) } catch {
                print("Could not install to \(app.path): \(error.localizedDescription)")
                return 1
            }
        }
        shell("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", app.path])
        print("Installed \(app.path)")

        // 2. The extension, at a path that does not depend on this checkout.
        let extensionDir = store.dir.appendingPathComponent("extension")
        try? fm.createDirectory(at: store.dir, withIntermediateDirectories: true)
        try? fm.removeItem(at: extensionDir)
        do { try fm.copyItem(at: app.appendingPathComponent("Contents/Resources/extension"), to: extensionDir) } catch {
            print("Could not copy the extension: \(error.localizedDescription)")
            return 1
        }

        // 3. Let Chrome's extension start the helper.
        let manifest: [String: Any] = [
            "name": ExtensionInfo.nativeHostName,
            "description": "Profile Router helper",
            "path": app.appendingPathComponent("Contents/MacOS/ProfileRouter").path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(ExtensionInfo.id)/"],
        ]
        try? fm.createDirectory(at: chrome.nativeHostManifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: chrome.nativeHostManifest)
        }
        print("Connected the helper to Chrome")

        // 4. Default browser, so links from other apps pass through the helper.
        if defaultBrowser && !CLI.isDefaultBrowser() {
            print("Asking macOS to make Profile Router the default browser. Choose \"Use Profile Router\" in the dialog.")
            var done = false
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in done = true }
            let deadline = Date().addingTimeInterval(90)
            while !done && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
            print(CLI.isDefaultBrowser() ? "Profile Router is the default browser"
                                         : "Not the default browser: links from other apps will not be routed. Run setup again to retry.")
        }

        // 5. Pair every profile.
        let profiles = chrome.profiles()
        guard !profiles.isEmpty else {
            print("No Chrome profiles found.")
            return 1
        }
        let token = UUID().uuidString
        store.update { state in
            state.pairing = Pairing(token: token, expiresAt: Date().timeIntervalSince1970 + 1800)
            for dir in state.profiles.keys { state.profiles[dir]?.paired = false }
        }
        let launcher = ChromeLauncher()
        func pairURL(_ profile: ChromeProfile) -> String {
            var c = URLComponents()
            c.scheme = "https"
            c.host = ExtensionInfo.pairHost
            c.path = "/"
            c.queryItems = [URLQueryItem(name: "dir", value: profile.dir), URLQueryItem(name: "token", value: token)]
            return c.url!.absoluteString
        }
        func isPaired(_ profile: ChromeProfile) -> Bool { store.read().profiles[profile.dir]?.paired == true }
        func waitForPairing(_ profile: ChromeProfile, seconds: Double) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if isPaired(profile) { return true }
                Thread.sleep(forTimeInterval: 0.25)
            }
            return isPaired(profile)
        }

        print("\nChecking \(profiles.count) Chrome profiles (a tab opens briefly in each)...")
        for profile in profiles {
            launcher.open(pairURL(profile), profile: profile.dir)
            Thread.sleep(forTimeInterval: 0.6)
        }
        for profile in profiles { _ = waitForPairing(profile, seconds: profile == profiles.first ? 8 : 1) }

        let missing = profiles.filter { !isPaired($0) }
        if !missing.isEmpty {
            print("""

            \(missing.count) profile(s) need the extension. Chrome only allows this by hand, once per profile:
              1. In the Extensions page that opens, turn on "Developer mode" (top right).
              2. Click "Load unpacked".
              3. Press Cmd+Shift+G, paste (the folder path is on your clipboard), press Return, then "Select".
              You can close the "can't reach this page" tab left over from the check.
            """)
            for profile in missing {
                copyToClipboard(extensionDir.path)
                launcher.open("chrome://extensions", profile: profile.dir)
                while true {
                    print("\n\(profile.name): load the extension, then press Return (or type s to skip): ", terminator: "")
                    if readLine()?.lowercased().hasPrefix("s") == true { break }
                    launcher.open(pairURL(profile), profile: profile.dir)
                    if waitForPairing(profile, seconds: 8) {
                        print("  \(profile.name) is paired")
                        break
                    }
                    print("  No answer from the extension in \(profile.name). If the Extensions page did not open, go to chrome://extensions in that profile.")
                }
            }
        }

        store.update { $0.pairing = nil }
        let paired = profiles.filter(isPaired)
        print("\n\(paired.count) of \(profiles.count) profiles paired.")
        for profile in profiles where !isPaired(profile) { print("  not paired: \(profile.name)") }
        return 0
    }

    @discardableResult
    private static func shell(_ path: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
