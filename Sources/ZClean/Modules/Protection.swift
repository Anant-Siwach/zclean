import AppKit
import SwiftUI

// MARK: - Security check

struct Threat: Identifiable, Hashable {
    enum Severity: Int, Comparable { case low = 0, medium, high
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
        var title: String { ["Review", "Suspicious", "Known adware"][rawValue] }
        var color: Color { [Color.yellow, .orange, .red][rawValue] }
    }
    let id = UUID()
    let title: String
    let path: URL
    let reason: String
    let severity: Severity
    var launchItem: LaunchItem?
    var selected: Bool
}

struct SecurityStatus: Identifiable {
    let id = UUID()
    let title: String
    let ok: Bool?
    let detail: String
}

struct BrowserExtension: Identifiable {
    let id = UUID()
    let browser: String
    let name: String
    let path: URL
}

enum SecurityScanner {
    /// Identifiers and folder names used by well-known adware and PUP families.
    static let adwareMarkers = [
        "mackeeper", "zeobit", "com.pcv.", "advancedmaccleaner", "macpurifier", "genieo", "installmac", "vsearch",
        "conduit", "crossrider", "spigot", "installcore", "bundlore", "pirrit", "mughthesec", "searchmine",
        "myshopcoupon", "shopperhelper", "macsearch", "searchbaron", "safefinder", "mytransitguide", "weknow",
        "chumsearch", "trovi", "amc.", "com.mcp.", "com.adsearch", "smartsearch", "maccleanup.pro",
    ]
    static let suspiciousDirs = ["/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/", "/Users/Shared/"]

    static func knownAdware(_ s: String) -> Bool {
        let l = s.lowercased()
        return adwareMarkers.contains { l.contains($0) }
    }

    static func scan(progress: @escaping (String) -> Void) -> [Threat] {
        var threats: [Threat] = []
        progress("Startup items")
        for item in LaunchItems.scan() {
            let program = item.program ?? ""
            if knownAdware(item.label) || knownAdware(program) {
                threats.append(Threat(title: item.displayName, path: item.plist, reason: "Matches a known adware family.",
                                      severity: .high, launchItem: item, selected: true))
            } else if !item.programExists, item.program != nil {
                threats.append(Threat(title: item.displayName, path: item.plist,
                                      reason: "Starts a program that no longer exists (leftover from a removed app).",
                                      severity: .low, launchItem: item, selected: false))
            } else if item.programExists, !item.signature.trustworthy {
                let hidden = program.split(separator: "/").contains { $0.hasPrefix(".") }
                let odd = suspiciousDirs.contains { program.hasPrefix($0) } || hidden
                threats.append(Threat(title: item.displayName, path: item.plist,
                                      reason: odd ? "\(item.signature.summary) program running from a hidden or temporary location."
                                                  : "\(item.signature.summary) program starts automatically. Fine if you installed it yourself.",
                                      severity: odd ? .medium : .low, launchItem: item, selected: odd))
            }
        }
        progress("Applications and support folders")
        let places = ["/Applications", FileOps.homePath("Applications").path, FileOps.homePath("Library/Application Support").path,
                      "/Library/Application Support"]
        for place in places {
            for url in FileOps.children(of: URL(fileURLWithPath: place)) where knownAdware(url.lastPathComponent) {
                progress(FileOps.displayPath(url))
                threats.append(Threat(title: url.deletingPathExtension().lastPathComponent, path: url,
                                      reason: "Matches a known adware or unwanted-software family.", severity: .high, selected: true))
            }
        }
        return threats.sorted { $0.severity > $1.severity }
    }

    static func status() -> [SecurityStatus] {
        let sip = Shell.run("/usr/bin/csrutil", ["status"]).text
        let gk = Shell.run("/usr/sbin/spctl", ["--status"]).text
        let fv = Shell.run("/usr/bin/fdesetup", ["status"]).text
        let fw = Shell.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]).text
        let xprotect = NSDictionary(contentsOfFile: "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist")
        let xpVersion = xprotect?["CFBundleShortVersionString"] as? String ?? "unknown"
        let xpDate = (try? URL(fileURLWithPath: "/Library/Apple/System/Library/CoreServices/XProtect.bundle")
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        return [
            SecurityStatus(title: "System Integrity Protection", ok: sip.contains("enabled"), detail: sip.contains("enabled") ? "On" : "Off"),
            SecurityStatus(title: "Gatekeeper", ok: gk.contains("enabled"), detail: gk.contains("enabled") ? "Only trusted apps can open" : "Off"),
            SecurityStatus(title: "FileVault disk encryption", ok: fv.contains("On"), detail: fv.contains("On") ? "On" : "Off"),
            SecurityStatus(title: "Firewall", ok: fw.contains("enabled") || fw.contains("State = 1"),
                           detail: fw.contains("enabled") || fw.contains("State = 1") ? "On" : "Off"),
            SecurityStatus(title: "XProtect malware definitions", ok: nil, detail: "Version \(xpVersion), updated \(relativeDate(xpDate))"),
        ]
    }

    static func extensions() -> [BrowserExtension] {
        var result: [BrowserExtension] = []
        for browser in Browser.all where browser.kind == .chromium {
            for profile in browser.profiles {
                let dir = profile.appendingPathComponent("Extensions")
                for ext in FileOps.children(of: dir, includeHidden: false) {
                    guard let version = FileOps.children(of: ext, includeHidden: false).first,
                          let data = try? Data(contentsOf: version.appendingPathComponent("manifest.json")),
                          let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          var name = manifest["name"] as? String else { continue }
                    if name.hasPrefix("__MSG_") { name = localized(name, in: version) ?? ext.lastPathComponent }
                    if manifest["theme"] != nil { continue }
                    result.append(BrowserExtension(browser: browser.name, name: name, path: ext))
                }
            }
        }
        // Safari web extensions are app extensions registered with pluginkit.
        let out = Shell.run("/usr/bin/pluginkit", ["-mAv", "-p", "com.apple.Safari.web-extension"]).text
        for line in out.split(separator: "\n") {
            guard let path = line.split(separator: "\t").last.map(String.init), path.hasPrefix("/") else { continue }
            let appex = URL(fileURLWithPath: path)
            let name = appex.deletingPathExtension().lastPathComponent
            result.append(BrowserExtension(browser: "Safari", name: name, path: appex))
        }
        return result
    }

    private static func localized(_ key: String, in dir: URL) -> String? {
        let k = String(key.dropFirst(6).dropLast(2))
        for locale in ["en", "en_US", "en_GB"] {
            let url = dir.appendingPathComponent("_locales/\(locale)/messages.json")
            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
                if let entry = json.first(where: { $0.key.lowercased() == k.lowercased() })?.value, let msg = entry["message"] as? String {
                    return msg
                }
            }
        }
        return nil
    }
}

@MainActor
final class MalwareModel: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var threats: [Threat] = []
    @Published var status: [SecurityStatus] = []
    @Published var extensions: [BrowserExtension] = []
    @Published var currentStep = ""
    @Published var removed = 0
    @Published var failures = 0
    @Published var lastScan: Date?

    func scan() async {
        phase = .scanning
        let throttle = Throttle()
        let (threats, status, exts) = await Task.detached(priority: .userInitiated) {
            let t = SecurityScanner.scan { step in throttle.run { Task { @MainActor in self.currentStep = step } } }
            return (t, SecurityScanner.status(), SecurityScanner.extensions())
        }.value
        self.threats = threats
        self.status = status
        self.extensions = exts
        lastScan = Date()
        phase = .results
    }

    func removeSelected() async {
        phase = .working
        let picked = threats.filter(\.selected)
        var removedIDs = Set<UUID>()
        var failed = 0
        for t in picked {
            let ok: Bool
            if let item = t.launchItem {
                ok = await Task.detached { LaunchItems.remove(item) }.value
            } else {
                ok = await withCheckedContinuation { c in FileOps.recycle([t.path]) { c.resume(returning: !$0.isEmpty) } }
            }
            if ok { removedIDs.insert(t.id) } else { failed += 1 }
        }
        threats.removeAll { removedIDs.contains($0.id) }
        removed = removedIDs.count
        failures = failed
        phase = .done
    }
}

struct MalwareView: View {
    @ObservedObject var model: MalwareModel

    var body: some View {
        switch model.phase {
        case .idle:
            ModuleHero(module: .malware) { Task { await model.scan() } } extra: {
                Text("Checks startup items, app folders and known adware locations, plus your Mac's built-in protections.")
                    .font(.caption).foregroundStyle(.white.opacity(0.5)).frame(maxWidth: 420).multilineTextAlignment(.center)
            }
        case .scanning:
            ScanningView(module: .malware, status: "Checking your Mac…", detail: model.currentStep)
        case .working:
            ScanningView(module: .malware, status: "Removing…")
        case .done:
            DoneView(module: .malware, title: "\(model.removed) item\(model.removed == 1 ? "" : "s") removed",
                     detail: "Removed items are in the Trash.", failures: model.failures) { model.phase = .results }
        case .results:
            let selected = model.threats.filter(\.selected).count
            let serious = model.threats.filter { $0.severity > .low }.count
            ResultsScaffold(module: .malware,
                            title: serious == 0 ? "No threats found" : "\(serious) item\(serious == 1 ? "" : "s") need attention",
                            subtitle: "\(model.threats.count) startup items to review · scanned \(relativeDate(model.lastScan))",
                            actionTitle: "Remove", actionEnabled: selected > 0,
                            onBack: { model.phase = .idle }, onAction: { Task { await model.removeSelected() } }) {
                HStack(alignment: .top, spacing: 14) {
                    GlassPanel {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Findings").font(.headline)
                            if model.threats.isEmpty {
                                EmptyResult(icon: "checkmark.shield.fill", title: "All clear",
                                            detail: "No adware or suspicious startup items were found.")
                            } else {
                                List {
                                    ForEach($model.threats) { $t in
                                        HStack(spacing: 10) {
                                            Toggle("", isOn: $t.selected).toggleStyle(.checkbox).labelsHidden()
                                            Text(t.severity.title)
                                                .font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                                .background(t.severity.color.opacity(0.3), in: Capsule())
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(t.title).lineLimit(1)
                                                Text(t.reason).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
                                            }
                                            Spacer()
                                            Button { FileOps.reveal(t.path) } label: { Image(systemName: "magnifyingglass") }
                                                .buttonStyle(.borderless).help(FileOps.displayPath(t.path))
                                        }
                                        .padding(.vertical, 3)
                                    }
                                }
                                .scrollContentBackground(.hidden).listStyle(.plain)
                            }
                        }
                    }
                    VStack(spacing: 14) {
                        GlassPanel {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Built-in protection").font(.headline)
                                ForEach(model.status) { s in
                                    HStack {
                                        Image(systemName: s.ok == nil ? "info.circle.fill" : (s.ok! ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                                            .foregroundStyle(s.ok == nil ? .white.opacity(0.6) : (s.ok! ? .green : .orange))
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(s.title).font(.callout)
                                            Text(s.detail).font(.caption).foregroundStyle(.white.opacity(0.55))
                                        }
                                        Spacer()
                                    }
                                }
                            }
                        }
                        GlassPanel {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Browser extensions (\(model.extensions.count))").font(.headline)
                                Text("Review these. Remove any you don't recognize from the browser's extensions page.")
                                    .font(.caption).foregroundStyle(.white.opacity(0.55))
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(model.extensions) { e in
                                            HStack {
                                                Text(e.name).lineLimit(1)
                                                Spacer()
                                                Text(e.browser).font(.caption).foregroundStyle(.white.opacity(0.5))
                                            }
                                            .font(.callout)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: 320)
                }
            }
        }
    }
}

// MARK: - Privacy

struct Browser: Identifiable {
    enum Kind { case safari, chromium, firefox }
    let name: String
    let bundleID: String
    let kind: Kind
    let base: URL
    let cache: URL?

    var id: String { bundleID }
    var installed: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    var icon: NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    var profiles: [URL] {
        switch kind {
        case .chromium:
            return FileOps.children(of: base, includeHidden: false).filter {
                ($0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile "))
                    && FileOps.exists($0.appendingPathComponent("Preferences"))
            }
        case .firefox:
            return FileOps.children(of: base.appendingPathComponent("Profiles"), includeHidden: false)
        case .safari:
            return [base]
        }
    }

    static let all: [Browser] = {
        let lib = FileOps.homePath("Library")
        let support = lib.appendingPathComponent("Application Support")
        let caches = lib.appendingPathComponent("Caches")
        return [
            Browser(name: "Safari", bundleID: "com.apple.Safari", kind: .safari, base: lib.appendingPathComponent("Safari"), cache: nil),
            Browser(name: "Google Chrome", bundleID: "com.google.Chrome", kind: .chromium,
                    base: support.appendingPathComponent("Google/Chrome"), cache: caches.appendingPathComponent("Google/Chrome")),
            Browser(name: "Brave", bundleID: "com.brave.Browser", kind: .chromium,
                    base: support.appendingPathComponent("BraveSoftware/Brave-Browser"), cache: caches.appendingPathComponent("BraveSoftware/Brave-Browser")),
            Browser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", kind: .chromium,
                    base: support.appendingPathComponent("Microsoft Edge"), cache: caches.appendingPathComponent("Microsoft Edge")),
            Browser(name: "Arc", bundleID: "company.thebrowser.Browser", kind: .chromium,
                    base: support.appendingPathComponent("Arc/User Data"), cache: caches.appendingPathComponent("Arc")),
            Browser(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", kind: .chromium,
                    base: support.appendingPathComponent("Vivaldi"), cache: caches.appendingPathComponent("Vivaldi")),
            Browser(name: "Opera", bundleID: "com.operasoftware.Opera", kind: .chromium,
                    base: support.appendingPathComponent("com.operasoftware.Opera"), cache: caches.appendingPathComponent("com.operasoftware.Opera")),
            Browser(name: "Firefox", bundleID: "org.mozilla.firefox", kind: .firefox,
                    base: support.appendingPathComponent("Firefox"), cache: caches.appendingPathComponent("Firefox")),
        ]
    }()
}

struct PrivacyItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let files: [URL]
    let size: Int64
    var selected: Bool
    var warning: String?
}

struct PrivacySource: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    let systemIcon: String?
    let bundleID: String?
    var items: [PrivacyItem]
    let roots: [URL]
    var afterClean: String?
}

enum PrivacyScanner {
    static func scan() -> [PrivacySource] {
        var sources: [PrivacySource] = []
        for b in Browser.all where b.installed && FileOps.exists(b.base) {
            var items: [PrivacyItem] = []
            func add(_ id: String, _ title: String, _ detail: String, _ files: [URL], selected: Bool = true, warning: String? = nil) {
                let existing = files.filter { FileOps.exists($0) }
                guard !existing.isEmpty else { return }
                let size = existing.reduce(Int64(0)) { $0 + FileOps.allocatedSize(of: $1) }
                items.append(PrivacyItem(id: "\(b.bundleID).\(id)", title: title, detail: detail, files: existing, size: size,
                                         selected: selected, warning: warning))
            }
            switch b.kind {
            case .chromium:
                let profiles = b.profiles
                func files(_ names: [String]) -> [URL] { profiles.flatMap { p in names.map { p.appendingPathComponent($0) } } }
                add("history", "Browsing history", "Visited pages, downloads list, top sites and typed URLs.",
                    files(["History", "History-journal", "Visited Links", "Top Sites", "Top Sites-journal", "Shortcuts", "Shortcuts-journal", "Network Action Predictor"]))
                add("cookies", "Cookies", "Keeps you signed in to websites. You'll be signed out.",
                    files(["Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal"]), selected: false,
                    warning: "You'll be signed out of websites.")
                add("cache", "Cache", "Downloaded copies of web pages and images.",
                    (b.cache.map { [$0] } ?? []) + files(["Code Cache", "GPUCache", "Service Worker/CacheStorage"]))
                add("autofill", "Autofill form data", "Saved addresses and things you've typed into forms. Passwords are never touched.",
                    files(["Web Data", "Web Data-journal"]), selected: false, warning: "Removes saved addresses and form entries.")
            case .safari:
                let container = FileOps.homePath("Library/Containers/com.apple.Safari/Data/Library")
                add("history", "Browsing history", "Visited pages, last session and recently closed tabs.",
                    ["History.db", "History.db-wal", "History.db-shm", "History.db-lock", "LastSession.plist", "RecentlyClosedTabs.plist"]
                        .map { b.base.appendingPathComponent($0) })
                add("cookies", "Cookies", "Keeps you signed in to websites.",
                    [container.appendingPathComponent("Cookies/Cookies.binarycookies"), FileOps.homePath("Library/Cookies/Cookies.binarycookies")],
                    selected: false, warning: "You'll be signed out of websites.")
                add("cache", "Cache", "Downloaded copies of web pages and images.",
                    [container.appendingPathComponent("Caches/com.apple.Safari")])
            case .firefox:
                let profiles = b.profiles
                add("cookies", "Cookies", "Keeps you signed in to websites.",
                    profiles.flatMap { [$0.appendingPathComponent("cookies.sqlite"), $0.appendingPathComponent("cookies.sqlite-wal")] },
                    selected: false, warning: "You'll be signed out of websites.")
                add("forms", "Form history", "Things you've typed into forms.",
                    profiles.map { $0.appendingPathComponent("formhistory.sqlite") })
                add("cache", "Cache", "Downloaded copies of web pages and images.", b.cache.map { [$0.appendingPathComponent("Profiles")] } ?? [])
            }
            guard !items.isEmpty else { continue }
            var roots = [b.base]
            if let c = b.cache { roots.append(c.deletingLastPathComponent()) }
            if b.kind == .safari { roots += [FileOps.homePath("Library/Containers/com.apple.Safari/Data/Library"), FileOps.homePath("Library/Cookies")] }
            sources.append(PrivacySource(id: b.bundleID, name: b.name, icon: b.icon, systemIcon: nil, bundleID: b.bundleID, items: items, roots: roots))
        }

        // macOS recent items.
        let sfl = FileOps.homePath("Library/Application Support/com.apple.sharedfilelist")
        let recents = FileOps.children(of: sfl).filter { $0.lastPathComponent.contains("Recent") && $0.pathExtension.hasPrefix("sfl") }
        let perApp = FileOps.children(of: sfl.appendingPathComponent("com.apple.LSSharedFileList.ApplicationRecentDocuments"))
        var mac: [PrivacyItem] = []
        if !(recents + perApp).isEmpty {
            mac.append(PrivacyItem(id: "recents", title: "Recent items", detail: "Recently opened documents, apps and servers, system-wide and per app.",
                                   files: recents + perApp, size: (recents + perApp).reduce(0) { $0 + FileOps.allocatedSize(of: $1) }, selected: true))
        }
        let shellHistory = [".zsh_history", ".bash_history", ".python_history", ".node_repl_history"]
            .map { FileOps.home.appendingPathComponent($0) }.filter { FileOps.exists($0) }
        if !shellHistory.isEmpty {
            mac.append(PrivacyItem(id: "shell", title: "Terminal command history", detail: "Commands you've typed in Terminal shells and REPLs.",
                                   files: shellHistory, size: shellHistory.reduce(0) { $0 + FileOps.allocatedSize(of: $1) }, selected: false))
        }
        if !mac.isEmpty {
            sources.append(PrivacySource(id: "macos", name: "macOS", icon: nil, systemIcon: "apple.logo", bundleID: nil, items: mac,
                                         roots: [sfl, FileOps.home], afterClean: "killall sharedfilelistd"))
        }
        return sources
    }
}

@MainActor
final class PrivacyModel: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var sources: [PrivacySource] = []
    @Published var selectedSource: String?
    @Published var confirm = false
    @Published var removedCount = 0
    @Published var skipped: [String] = []

    var selectedCount: Int { sources.reduce(0) { $0 + $1.items.filter(\.selected).count } }

    func scan() async {
        phase = .scanning
        sources = await Task.detached(priority: .userInitiated) { PrivacyScanner.scan() }.value
        selectedSource = sources.first?.id
        phase = .results
    }

    func clean() async {
        phase = .working
        var skipped: [String] = []
        var count = 0
        for src in sources {
            let picked = src.items.filter(\.selected)
            guard !picked.isEmpty else { continue }
            if let id = src.bundleID, !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
                skipped.append(src.name)
                continue
            }
            let files = picked.flatMap(\.files)
            let roots = src.roots
            // Privacy data is deleted, not trashed (a copy in the Trash would defeat the point).
            let r = await Task.detached { () -> FileOps.Result in
                var res = FileOps.Result()
                for f in files where FileOps.isInside(f, roots: roots) && !FileOps.isExcluded(f) {
                    if (try? FileManager.default.removeItem(at: f)) != nil { res.removed.append(f) } else { res.failed.append(f) }
                }
                return res
            }.value
            count += r.removed.count
            if let cmd = src.afterClean { _ = Shell.sh(cmd) }
        }
        self.skipped = skipped
        removedCount = count
        phase = .done
    }

    func quit(_ bundleID: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.objectWillChange.send() }
    }
}

struct PrivacyView: View {
    @ObservedObject var model: PrivacyModel

    var body: some View {
        switch model.phase {
        case .idle:
            ModuleHero(module: .privacy) { Task { await model.scan() } } extra: {
                FullDiskAccessBanner(reason: "Safari's history and cookies are only visible with Full Disk Access.").frame(maxWidth: 520)
            }
        case .scanning:
            ScanningView(module: .privacy, status: "Looking for privacy traces…")
        case .working:
            ScanningView(module: .privacy, status: "Removing…")
        case .done:
            DoneView(module: .privacy, title: "Privacy traces removed",
                     detail: model.skipped.isEmpty ? "\(model.removedCount) files deleted."
                         : "Skipped \(model.skipped.joined(separator: ", ")) because it was open.") { model.phase = .idle }
        case .results:
            ResultsScaffold(module: .privacy, title: "\(model.sources.count) source\(model.sources.count == 1 ? "" : "s") with private data",
                            subtitle: "\(model.selectedCount) item\(model.selectedCount == 1 ? "" : "s") selected",
                            actionTitle: "Remove", actionEnabled: model.selectedCount > 0,
                            onBack: { model.phase = .idle }, onAction: { model.confirm = true }) {
                PrivacyResults(model: model)
            }
            .confirmationDialog("Remove the selected privacy data?", isPresented: $model.confirm) {
                Button("Remove Permanently", role: .destructive) { Task { await model.clean() } }
            } message: {
                Text("This deletes the data immediately; it doesn't go to the Trash. Close the browsers first.")
            }
        }
    }
}

private struct PrivacyResults: View {
    @ObservedObject var model: PrivacyModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            GlassPanel(padding: 8) {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.sources) { src in
                            HStack(spacing: 10) {
                                if let icon = src.icon { Image(nsImage: icon).resizable().frame(width: 24, height: 24) }
                                else { Image(systemName: src.systemIcon ?? "app").frame(width: 24) }
                                Text(src.name)
                                Spacer()
                                Text("\(src.items.filter(\.selected).count)/\(src.items.count)").font(.caption).foregroundStyle(.white.opacity(0.6))
                            }
                            .padding(10)
                            .background(model.selectedSource == src.id ? .white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectedSource = src.id }
                        }
                    }
                }
            }
            .frame(width: 260)

            GlassPanel {
                if let i = model.sources.firstIndex(where: { $0.id == model.selectedSource }) {
                    let src = model.sources[i]
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(src.name).font(.headline)
                            Spacer()
                            if let id = src.bundleID, !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
                                Label("Open, so it will be skipped", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                                Button("Quit \(src.name)") { model.quit(id) }.buttonStyle(GlassButtonStyle(compact: true))
                            }
                        }
                        ForEach(src.items.indices, id: \.self) { j in
                            let item = src.items[j]
                            CheckRow(isOn: $model.sources[i].items[j].selected, title: item.title, subtitle: item.detail,
                                     trailing: formatBytes(item.size), warning: item.warning) { EmptyView() }
                        }
                        Spacer()
                    }
                }
            }
        }
    }
}
