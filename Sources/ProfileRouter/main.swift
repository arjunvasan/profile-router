import AppKit
import RouterCore

// One binary, three roles, chosen by how it was started:
//   by Chrome with the extension's origin  -> native messaging host
//   with a command (setup, status, ...)    -> command line
//   by macOS to open a link                -> default-browser helper

let arguments = Array(CommandLine.arguments.dropFirst())

if let first = arguments.first, first.hasPrefix("chrome-extension://") {
    let host = HostService(store: Store(), profiles: { Chrome().profiles() }, launcher: ChromeLauncher())
    let input = FileHandle.standardInput
    while let message = NativeMessaging.read(from: input) {
        NativeMessaging.write(host.handle(message), to: FileHandle.standardOutput)
    }
    exit(0)
}

if let command = arguments.first, !command.hasPrefix("-psn") {
    exit(CLI.run(command, Array(arguments.dropFirst())))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
