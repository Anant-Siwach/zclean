# ZClean

A CleanMyMac-style Mac cleaner and optimizer, written in Swift/SwiftUI. No subscription, no account, nothing leaves your Mac
except update checks.

## Build & run

```sh
./build.sh          # builds ZClean.app in this folder (signed with a stable local identity)
./build.sh --run    # builds, quits any running copy, launches it
```

Requires macOS 14+. For full results, turn on ZClean in System Settings › Privacy & Security › Full Disk Access.

## Modules

| Group | Module | What it does |
|---|---|---|
| | Smart Care | One scan for junk, Trash, threats, maintenance and updates; one click to run |
| Cleanup | System Junk | User/app caches, logs, Xcode junk, package-manager caches (npm, Homebrew, pip, Gradle, Cargo, JetBrains…), temp files, old installers, Mail attachments, iOS backups |
| | Trash Bins | Measure and empty the Trash |
| Protection | Security Check | Flags startup items that are known adware, unsigned/ad-hoc programs in odd places, or orphaned; shows SIP, Gatekeeper, FileVault, Firewall, XProtect; lists browser extensions |
| | Privacy | History, cookies, cache, autofill for Safari, Chrome, Brave, Edge, Arc, Vivaldi, Opera, Firefox; macOS recent items; shell history |
| Performance | Optimization | Enable/disable/remove LaunchAgents and LaunchDaemons (with code-signature info); live heavy-consumer list with Quit |
| | Maintenance | Free RAM, flush DNS, Quick Look cache, Launch Services rebuild, Spotlight reindex, font caches, Time Machine snapshot thinning, Mail index vacuum, home permissions, restart Finder/Dock |
| Applications | Uninstaller | Apps with size and last-used date; removes the app and its support files; Reset App; finds leftovers of removed apps |
| | Updater | App Store (iTunes lookup), Sparkle appcast feeds and Homebrew |
| Files | Space Lens | Folder-size map (squarified treemap) for home, the whole disk or any folder |
| | Large & Old Files | Big files filtered by type and last-opened age |
| | Duplicates | Size → partial hash → SHA-256; auto-selects all but one copy |
| | Shredder | Overwrites with random data, then deletes |

A menu bar monitor shows CPU, memory, disk, network speed, battery health/cycles and top apps, with Free Up RAM.

## Safety

- Everything that could be yours (apps, leftovers, large files, duplicates, installers, backups) goes to the **Trash**.
- Caches and logs are deleted (apps rebuild them), but only **strictly inside** an allowlist of folders per category,
  never a folder root, never your home folder. Settings can send junk to the Trash too.
- Caches of running apps, Playwright browsers and Gradle are left unchecked.
- Settings › Exclusions: paths ZClean never touches.
- Admin tasks use macOS's own password dialog; ZClean never sees your password.

The Security Check is heuristic (known adware identifiers + signature checks); it is not a signature-based antivirus.

## Licence

MIT (see `LICENSE`).
