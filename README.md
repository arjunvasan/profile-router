# Profile Router

Sends every sign-in to the Chrome profile that holds the right account.

- **Inside Chrome:** click "Sign in with Google/GitHub/…" in the wrong profile and the site reopens in the profile you used for it before. The first time a site is seen, a small picker asks which profile.
- **From other apps:** sign-in links opened by the terminal (`gh`, `gcloud`, Claude), Slack or mail go to the remembered profile instead of whichever one was used last. Every other link opens as before.

Mac only. Nothing leaves the machine; the memory is one file, `~/Library/Application Support/ProfileRouter/state.json`.

## Set up

You need macOS 13 or later, Google Chrome, and Swift (install Xcode, or run `xcode-select --install`).

```bash
git clone https://github.com/arjunvasan/profile-router.git
```

```bash
cd profile-router
```

```bash
bin/profile-router setup
```

Setup builds and installs `~/Applications/ProfileRouter.app`, connects it to Chrome, asks macOS to make it the default browser (you confirm), then checks each Chrome profile. For each profile that lacks the extension it opens that profile's Extensions page; you click **Load unpacked** once per profile (the folder path is on your clipboard). Chrome offers no way to script that step.

Run it again after adding a Chrome profile or pulling changes.

## Use

```bash
bin/profile-router status          # profiles, pairing, accounts, remembered routes
bin/profile-router forget <site>   # forget a route (or --all)
bin/profile-router route <url>     # what would happen to a link from another app
```

- A wrong move shows a notification with **Undo**, which also corrects the memory.
- Signing in to a site from a different profile than the remembered one updates the memory; the latest wins.
- Hold **Option** while a link opens from another app to be asked again.

## How it works

| Part | Where | Role |
| --- | --- | --- |
| Helper app | `Sources/ProfileRouter` | Default browser for links from other apps, native messaging host for the extension, and the command line. |
| Decisions and memory | `Sources/RouterCore` | Every routing decision, the provider table, the locked state file. |
| Extension | `extension/` | One copy per profile. Reports sign-ins starting, obeys the helper (stay, move, ask). |

An extension cannot open another profile or see other profiles, so the helper does both: it holds the shared memory and starts Chrome with `--profile-directory`.

When a sign-in moves, the **site's page** is reopened in the other profile, not the provider's page: the half-started sign-in is tied to cookies in the profile it began in.

Add a provider in `extension/providers.json`, `Sources/RouterCore/Providers.swift` and the manifest's `host_permissions`; a test fails if the three disagree.

## Limits

- Moving reloads the site in the other profile, so text typed into a form is lost.
- Google One Tap and Chrome's built-in account chooser are not page navigations and are not intercepted.
- If a provider signs you in instantly with no screen, the move can lose the race and the sign-in completes where it started.
- Chrome will mention it is no longer the default browser. Leave it that way.

## Uninstall

1. In System Settings, Desktop & Dock, set the default web browser back to Chrome.
2. In each Chrome profile, remove Profile Router at `chrome://extensions`.
3. Delete the helper, its link to Chrome, and its memory:

```bash
rm -rf ~/Applications/ProfileRouter.app ~/Library/Application\ Support/ProfileRouter ~/Library/Application\ Support/Google/Chrome/NativeMessagingHosts/com.profilerouter.host.json
```

## Status

Early. So far it has run on one Mac with five profiles. The helper's decisions are covered by tests; the extension's behavior in the browser is not yet. Issues and pull requests are welcome.

## Test

```bash
swift test
```

```bash
npm test
```

## License

MIT. See [LICENSE](LICENSE).
