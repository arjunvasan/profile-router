import AppKit
import RouterCore

/// The default-browser role: receives links from other apps, sends each to a
/// Chrome profile, and quits. It keeps no window and no Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let router = LinkRouter(store: Store(), profiles: { Chrome().profiles() }, launcher: ChromeLauncher())
    private var quitTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        scheduleQuit()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        quitTimer?.invalidate()
        let forceAsk = NSEvent.modifierFlags.contains(.option)
        for url in urls {
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            handle(url, forceAsk: forceAsk)
        }
        scheduleQuit()
    }

    private func handle(_ url: URL, forceAsk: Bool) {
        switch router.decide(url, forceAsk: forceAsk) {
        case let .open(profile, key):
            router.open(url, key: key, profile: profile, remember: false)
        case let .ask(key, label, providerId):
            guard let answer = pick(label: label, host: url.host ?? "", choices: router.choices(providerId: providerId)) else { return }
            router.open(url, key: key, profile: answer.profile, remember: answer.remember)
        }
    }

    /// Asks which profile a sign-in belongs in. Returns nil if cancelled.
    private func pick(label: String, host: String, choices: [Choice]) -> (profile: String?, remember: Bool)? {
        let alert = NSAlert()
        alert.messageText = "Which Chrome profile should open this sign-in?"
        alert.informativeText = label == host ? host : "\(label) (\(host))"
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 28, width: 320, height: 26), pullsDown: false)
        for choice in choices {
            popup.addItem(withTitle: choice.accounts.isEmpty ? choice.name : "\(choice.name)  (\(choice.accounts.joined(separator: ", ")))")
        }
        popup.addItem(withTitle: "Last-used profile")
        let remember = NSButton(checkboxWithTitle: "Remember for next time", target: nil, action: nil)
        remember.state = .on
        remember.frame = NSRect(x: 0, y: 0, width: 320, height: 22)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        box.addSubview(popup)
        box.addSubview(remember)
        alert.accessoryView = box

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let index = popup.indexOfSelectedItem
        return (index < choices.count ? choices[index].dir : nil, remember.state == .on)
    }

    private func scheduleQuit() {
        quitTimer?.invalidate()
        quitTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in NSApp.terminate(nil) }
    }
}
