import AppKit
import SwiftUI

struct InstalledApp: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleID: String?
    let version: String
    let build: String
    let isAppStore: Bool
    let isApple: Bool
    let feedURL: String?
    var size: Int64 = 0
    var lastUsed: Date?
    var id: URL { url }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
    var isRunning: Bool { bundleID.map { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty } ?? false }
}

struct Leftover: Identifiable, Hashable {
    let url: URL
    let size: Int64
    var selected = true
    var id: URL { url }
}

enum AppCatalog {
    static func load() -> [InstalledApp] {
        var urls: [URL] = []
        for dir in [URL(fileURLWithPath: "/Applications"), FileOps.homePath("Applications")] {
            for url in FileOps.children(of: dir, includeHidden: false) {
                if url.pathExtension == "app" { urls.append(url) }
                else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    urls += FileOps.children(of: url, includeHidden: false).filter { $0.pathExtension == "app" }
                }
            }
        }
        return urls.compactMap { url in
            guard let info = Bundle(url: url)?.infoDictionary else { return nil }
            let id = info["CFBundleIdentifier"] as? String
            var app = InstalledApp(
                url: url,
                name: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent,
                bundleID: id,
                version: info["CFBundleShortVersionString"] as? String ?? "",
                build: info["CFBundleVersion"] as? String ?? "",
                isAppStore: FileOps.exists(url.appendingPathComponent("Contents/_MASReceipt/receipt")),
                isApple: id?.hasPrefix("com.apple.") ?? false,
                feedURL: info["SUFeedURL"] as? String)
            if let item = MDItemCreateWithURL(nil, url as CFURL) {
                app.lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
            }
            return app
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static let leftoverDirs = [
        "Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Containers", "Library/Group Containers",
        "Library/Saved Application State", "Library/Logs", "Library/HTTPStorages", "Library/WebKit", "Library/Cookies",
        "Library/LaunchAgents", "Library/Application Scripts", "Library/Preferences/ByHost",
    ].map { FileOps.homePath($0) }

    /// Files an app keeps outside its bundle, matched by bundle ID (or exact app name).
    static func leftovers(for app: InstalledApp) -> [Leftover] {
        guard let id = app.bundleID?.lowercased(), !app.isApple else { return [] }
        let name = app.name.lowercased()
        var found: [Leftover] = []
        for dir in leftoverDirs {
            for url in FileOps.children(of: dir) {
                let n = url.lastPathComponent.lowercased()
                // Match whole identifier segments so "com.foo" never claims "com.foobar".
                let matchesID = n == id || n.hasPrefix(id + ".") || n.hasSuffix("." + id) || n.contains("." + id + ".")
                let matchesName = name.count >= 4 && (n == name || n == name + ".plist")
                guard (matchesID || matchesName), !FileOps.isExcluded(url) else { continue }
                found.append(Leftover(url: url, size: FileOps.allocatedSize(of: url)))
            }
        }
        return found.sorted { $0.size > $1.size }
    }

    /// Support files whose bundle ID doesn't belong to any installed app.
    static func orphans(installed: Set<String>) -> [Leftover] {
        let dirs = ["Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Containers", "Library/Saved Application State",
                    "Library/HTTPStorages", "Library/WebKit"].map { FileOps.homePath($0) }
        let prefixes = ["com.", "org.", "net.", "io.", "co.", "app.", "dev.", "me."]
        // Files from a developer whose app is still installed are usually its helpers, not leftovers.
        let vendors = Set(installed.map { $0.split(separator: ".").prefix(2).joined(separator: ".") })
        var result: [Leftover] = []
        for dir in dirs {
            for url in FileOps.children(of: dir) {
                var n = url.lastPathComponent
                if n.hasSuffix(".plist") { n = String(n.dropLast(6)) }
                if n.hasSuffix(".savedState") { n = String(n.dropLast(11)) }
                let lower = n.lowercased()
                guard prefixes.contains(where: lower.hasPrefix), lower.split(separator: ".").count >= 3,
                      !lower.hasPrefix("com.apple."), !installed.contains(lower),
                      !vendors.contains(lower.split(separator: ".").prefix(2).joined(separator: ".")),
                      !installed.contains(where: { lower.hasPrefix($0 + ".") }),
                      NSWorkspace.shared.urlForApplication(withBundleIdentifier: n) == nil,
                      !FileOps.isExcluded(url) else { continue }
                let size = FileOps.allocatedSize(of: url)
                guard size > 0 else { continue }
                result.append(Leftover(url: url, size: size, selected: false))
            }
        }
        return result.sorted { $0.size > $1.size }
    }
}

@MainActor
final class AppsModel: ObservableObject {
    enum Filter: String, CaseIterable { case all = "All", unused = "Unused", appStore = "App Store", large = "Large" }
    enum Sort: String, CaseIterable { case name = "Name", size = "Size", lastUsed = "Last Used" }

    @Published var phase: Phase = .idle
    @Published var apps: [InstalledApp] = []
    @Published var checked: Set<URL> = []
    @Published var focused: URL?
    @Published var leftovers: [Leftover] = []
    @Published var search = ""
    @Published var filter: Filter = .all
    @Published var sort: Sort = .name
    @Published var tab = 0
    @Published var orphans: [Leftover] = []
    @Published var orphansLoading = false
    @Published var message: String?

    var visible: [InstalledApp] {
        var list = apps
        if !search.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(search) } }
        switch filter {
        case .all: break
        case .unused: list = list.filter { ($0.lastUsed ?? .distantPast) < Date().addingTimeInterval(-180 * 86400) }
        case .appStore: list = list.filter(\.isAppStore)
        case .large: list = list.filter { $0.size > 500_000_000 }
        }
        switch sort {
        case .name: break
        case .size: list.sort { $0.size > $1.size }
        case .lastUsed: list.sort { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
        return list
    }

    func load() async {
        phase = .scanning
        apps = await Task.detached { AppCatalog.load() }.value
        phase = .results
        if focused == nil { focus(apps.first(where: { !$0.isApple })?.url) }
        // Fill in sizes progressively; bundles can be large.
        for app in apps {
            let size = await Task.detached { FileOps.allocatedSize(of: app.url) }.value
            if let i = apps.firstIndex(where: { $0.url == app.url }) { apps[i].size = size }
        }
    }

    func focus(_ url: URL?) {
        focused = url
        leftovers = []
        guard let url, let app = apps.first(where: { $0.url == url }) else { return }
        Task {
            let found = await Task.detached { AppCatalog.leftovers(for: app) }.value
            if focused == url { leftovers = found }
        }
    }

    var checkedSize: Int64 { apps.filter { checked.contains($0.url) }.reduce(0) { $0 + $1.size } }

    /// Quits each app, then moves it and its leftovers to the Trash.
    func uninstall(_ targets: [InstalledApp], focusedLeftovers: [Leftover]? = nil) async {
        phase = .working
        var removedApps = 0
        var freed: Int64 = 0
        for app in targets where !app.isApple {
            if let id = app.bundleID {
                for running in NSRunningApplication.runningApplications(withBundleIdentifier: id) { running.terminate() }
                try? await Task.sleep(for: .milliseconds(app.isRunning ? 1500 : 0))
            }
            let extras: [Leftover]
            if let focusedLeftovers, app.url == focused { extras = focusedLeftovers.filter(\.selected) }
            else { extras = await Task.detached { AppCatalog.leftovers(for: app) }.value }
            let moved = await recycle([app.url] + extras.map(\.url))
            if moved.contains(app.url) {
                removedApps += 1
                freed += app.size + extras.filter { moved.contains($0.url) }.reduce(0) { $0 + $1.size }
                apps.removeAll { $0.url == app.url }
                checked.remove(app.url)
            }
        }
        message = removedApps == 0 ? "Nothing was removed." : "Removed \(removedApps) app\(removedApps == 1 ? "" : "s") · \(formatBytes(freed)) moved to the Trash"
        focus(apps.first(where: { !$0.isApple })?.url)
        phase = .results
    }

    /// Removes an app's data but keeps the app (fresh start).
    func reset(_ app: InstalledApp) async {
        for running in app.bundleID.map(NSRunningApplication.runningApplications(withBundleIdentifier:)) ?? [] { running.terminate() }
        let moved = await recycle(leftovers.filter(\.selected).map(\.url))
        message = "Reset \(app.name): moved \(moved.count) item\(moved.count == 1 ? "" : "s") to the Trash"
        focus(app.url)
    }

    func loadOrphans() async {
        orphansLoading = true
        let ids = Set(apps.compactMap { $0.bundleID?.lowercased() })
        orphans = await Task.detached { AppCatalog.orphans(installed: ids) }.value
        orphansLoading = false
    }

    func removeOrphans() async {
        let moved = await recycle(orphans.filter(\.selected).map(\.url))
        orphans.removeAll { moved.contains($0.url) }
        message = "Moved \(moved.count) leftover item\(moved.count == 1 ? "" : "s") to the Trash"
    }

    private func recycle(_ urls: [URL]) async -> Set<URL> {
        await withCheckedContinuation { c in FileOps.recycle(urls) { c.resume(returning: $0) } }
    }
}

struct UninstallerView: View {
    @ObservedObject var model: AppsModel

    var body: some View {
        switch model.phase {
        case .idle:
            ModuleHero(module: .uninstaller, buttonTitle: "View Apps") { Task { await model.load() } }
        case .scanning:
            ScanningView(module: .uninstaller, status: "Finding your apps…")
        case .working:
            ScanningView(module: .uninstaller, status: "Uninstalling…")
        case .results, .done:
            VStack(spacing: 12) {
                HStack {
                    GlowIcon(icon: Module.uninstaller.icon, colors: Module.uninstaller.colors, size: 46).frame(width: 60, height: 60)
                    VStack(alignment: .leading) {
                        Text("Uninstaller").font(.system(size: 24, weight: .bold, design: .rounded))
                        Text("\(model.apps.count) apps · \(formatBytes(model.apps.reduce(0) { $0 + $1.size }))").foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    Picker("", selection: $model.tab) {
                        Text("Applications").tag(0)
                        Text("Leftovers").tag(1)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                }
                if let msg = model.message {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(msg).font(.callout)
                        Spacer()
                        Button { model.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                    .padding(10).background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
                if model.tab == 0 { AppsBrowser(model: model) } else { OrphansView(model: model) }
            }
            .padding(24)
        }
    }
}

private struct AppsBrowser: View {
    @ObservedObject var model: AppsModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            GlassPanel(padding: 8) {
                VStack(spacing: 8) {
                    HStack {
                        TextField("Search apps", text: $model.search).textFieldStyle(.roundedBorder)
                        Picker("", selection: $model.sort) { ForEach(AppsModel.Sort.allCases, id: \.self) { Text($0.rawValue) } }
                            .labelsHidden().frame(width: 110)
                    }
                    Picker("", selection: $model.filter) { ForEach(AppsModel.Filter.allCases, id: \.self) { Text($0.rawValue) } }
                        .pickerStyle(.segmented).labelsHidden()
                    List(model.visible) { app in
                        HStack(spacing: 10) {
                            Toggle("", isOn: $model.checked.contains(app.url))
                                .toggleStyle(.checkbox).labelsHidden().disabled(app.isApple)
                            Image(nsImage: app.icon).resizable().frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name).lineLimit(1)
                                Text(app.lastUsed.map { "Used \(relativeDate($0))" } ?? "Never opened")
                                    .font(.caption).foregroundStyle(.white.opacity(0.5))
                            }
                            Spacer()
                            Text(app.size > 0 ? formatBytes(app.size) : "…").font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 4)
                        .background(model.focused == app.url ? .white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                        .onTapGesture { model.focus(app.url) }
                    }
                    .scrollContentBackground(.hidden).listStyle(.plain)
                    if !model.checked.isEmpty {
                        Button("Uninstall \(model.checked.count) Selected · \(formatBytes(model.checkedSize))") {
                            Task { await model.uninstall(model.apps.filter { model.checked.contains($0.url) }) }
                        }
                        .buttonStyle(GlassButtonStyle())
                    }
                }
            }
            .frame(width: 360)

            GlassPanel {
                if let url = model.focused, let app = model.apps.first(where: { $0.url == url }) {
                    AppDetail(model: model, app: app)
                } else {
                    EmptyResult(icon: "app.dashed", title: "Pick an app", detail: "Select an app to see what it stores on your Mac.")
                }
            }
        }
    }
}

private struct AppDetail: View {
    @ObservedObject var model: AppsModel
    let app: InstalledApp

    var body: some View {
        let leftoverSize = model.leftovers.filter(\.selected).reduce(0) { $0 + $1.size }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(nsImage: app.icon).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.title2.bold())
                    Text("Version \(app.version)\(app.isAppStore ? " · App Store" : "")").foregroundStyle(.white.opacity(0.6))
                    Text(app.bundleID ?? "").font(.caption).foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
            }
            HStack(spacing: 24) {
                stat("App", app.size > 0 ? formatBytes(app.size) : "…")
                stat("Support files", formatBytes(model.leftovers.reduce(0) { $0 + $1.size }))
                stat("Last opened", relativeDate(app.lastUsed))
            }
            if app.isApple {
                Label("Apple apps are part of macOS and can't be removed.", systemImage: "lock.fill")
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
            } else {
                Text("Files this app keeps elsewhere").font(.headline)
                List {
                    ForEach($model.leftovers) { $l in
                        CheckRow(isOn: $l.selected, title: l.url.lastPathComponent, subtitle: FileOps.displayPath(l.url.deletingLastPathComponent()),
                                 trailing: formatBytes(l.size)) { FileIcon(url: l.url, size: 18) }
                            .contextMenu { Button("Show in Finder") { FileOps.reveal(l.url) } }
                    }
                }
                .scrollContentBackground(.hidden).listStyle(.plain)
                HStack {
                    Button("Reset App") { Task { await model.reset(app) } }
                        .buttonStyle(GlassButtonStyle())
                        .disabled(leftoverSize == 0)
                        .help("Removes the app's settings and data but keeps the app")
                    Spacer()
                    BigButton(title: "Uninstall", colors: Module.uninstaller.colors) {
                        Task { await model.uninstall([app], focusedLeftovers: model.leftovers) }
                    }
                    .scaleEffect(0.8)
                }
                Text("Everything goes to the Trash, so you can put it back.").font(.caption).foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.5))
            Text(value).font(.callout.bold())
        }
    }
}

private struct OrphansView: View {
    @ObservedObject var model: AppsModel

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text("Files left behind by apps that are no longer installed.").font(.headline)
                Text("Matched by app identifier. Some may belong to helpers or command-line tools you still use, so nothing is checked by default. Review before removing.")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
                if model.orphansLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.orphans.isEmpty {
                    EmptyResult(icon: "checkmark.seal", title: "No leftovers found", detail: "Click Scan to look again.")
                } else {
                    List {
                        ForEach($model.orphans) { $o in
                            CheckRow(isOn: $o.selected, title: o.url.lastPathComponent, subtitle: FileOps.displayPath(o.url.deletingLastPathComponent()),
                                     trailing: formatBytes(o.size)) { FileIcon(url: o.url, size: 18) }
                                .contextMenu { Button("Show in Finder") { FileOps.reveal(o.url) } }
                        }
                    }
                    .scrollContentBackground(.hidden).listStyle(.plain)
                }
                HStack {
                    Button("Scan") { Task { await model.loadOrphans() } }.buttonStyle(GlassButtonStyle())
                    Spacer()
                    let n = model.orphans.filter(\.selected).count
                    Button("Move \(n) to Trash") { Task { await model.removeOrphans() } }
                        .buttonStyle(GlassButtonStyle()).disabled(n == 0)
                }
            }
        }
        .task { if model.orphans.isEmpty { await model.loadOrphans() } }
    }
}

// MARK: - Updater

struct AppUpdate: Identifiable {
    enum Source: String { case appStore = "App Store", developer = "Developer", homebrew = "Homebrew" }
    let id = UUID()
    let name: String
    let icon: NSImage?
    let current: String
    let latest: String
    let source: Source
    let appURL: URL?
    let storeURL: URL?
    let downloadURL: URL?
    var brewName: String?
    var updating = false
}

enum UpdateChecker {
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } }
        let x = parts(a), y = parts(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    static func check(_ app: InstalledApp) async -> AppUpdate? {
        if app.isAppStore, let id = app.bundleID { return await appStore(app, id) }
        if let feed = app.feedURL, let url = URL(string: feed) { return await sparkle(app, url) }
        return nil
    }

    private static func appStore(_ app: InstalledApp, _ id: String) async -> AppUpdate? {
        var comps = URLComponents(string: "https://itunes.apple.com/lookup")!
        comps.queryItems = [.init(name: "bundleId", value: id), .init(name: "entity", value: "desktopSoftware")]
        guard let (data, _) = try? await URLSession.shared.data(from: comps.url!),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = (json["results"] as? [[String: Any]])?.first,
              let latest = result["version"] as? String, isNewer(latest, than: app.version) else { return nil }
        let store = (result["trackId"] as? Int).flatMap { URL(string: "macappstore://apps.apple.com/app/id\($0)") }
        return AppUpdate(name: app.name, icon: app.icon, current: app.version, latest: latest, source: .appStore,
                         appURL: app.url, storeURL: store, downloadURL: nil)
    }

    private static func sparkle(_ app: InstalledApp, _ feed: URL) async -> AppUpdate? {
        var req = URLRequest(url: feed, timeoutInterval: 15)
        req.setValue("ZClean/1.0 Sparkle", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        let parser = AppcastParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        // Prefer marketing versions; fall back to build numbers.
        let best = parser.items.max { a, b in
            isNewer(b.short ?? b.build ?? "", than: a.short ?? a.build ?? "")
        }
        guard let best else { return nil }
        let newer: Bool
        if let short = best.short { newer = isNewer(short, than: app.version) }
        else if let build = best.build { newer = isNewer(build, than: app.build) }
        else { newer = false }
        guard newer else { return nil }
        return AppUpdate(name: app.name, icon: app.icon, current: app.version, latest: best.short ?? best.build ?? "?",
                         source: .developer, appURL: app.url, storeURL: nil, downloadURL: best.url.flatMap(URL.init(string:)))
    }

    static func homebrew() -> [AppUpdate] {
        let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let brew else { return [] }
        let out = Shell.run(brew, ["outdated", "--json=v2"]).text
        guard let data = out.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var result: [AppUpdate] = []
        for key in ["formulae", "casks"] {
            for item in json[key] as? [[String: Any]] ?? [] {
                guard let name = item["name"] as? String else { continue }
                let current = (item["installed_versions"] as? [String])?.last ?? item["installed_versions"] as? String ?? "?"
                let latest = item["current_version"] as? String ?? "?"
                var u = AppUpdate(name: name, icon: nil, current: current, latest: latest, source: .homebrew,
                                  appURL: nil, storeURL: nil, downloadURL: nil)
                u.brewName = (key == "casks" ? "--cask " : "") + name
                result.append(u)
            }
        }
        return result
    }
}

private final class AppcastParser: NSObject, XMLParserDelegate {
    struct Item { var short: String?; var build: String?; var url: String? }
    var items: [Item] = []
    private var current: Item?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName q: String?, attributes: [String: String]) {
        text = ""
        if name == "item" { current = Item() }
        if name == "enclosure", var item = current {
            item.short = item.short ?? attributes["sparkle:shortVersionString"]
            item.build = item.build ?? attributes["sparkle:version"]
            item.url = attributes["url"]
            current = item
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName q: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "sparkle:shortVersionString": if !value.isEmpty { current?.short = value }
        case "sparkle:version": if !value.isEmpty { current?.build = value }
        case "item": if let c = current { items.append(c) }; current = nil
        default: break
        }
    }
}

@MainActor
final class UpdaterModel: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var updates: [AppUpdate] = []
    @Published var checked = 0
    @Published var total = 0
    @Published var lastCheck: Date?

    func scan() async {
        phase = .scanning
        let apps = await Task.detached { AppCatalog.load() }.value.filter { $0.isAppStore || $0.feedURL != nil }
        total = apps.count
        checked = 0
        var found: [AppUpdate] = []
        await withTaskGroup(of: AppUpdate?.self) { group in
            for app in apps { group.addTask { await UpdateChecker.check(app) } }
            for await u in group {
                checked += 1
                if let u { found.append(u) }
            }
        }
        found += await Task.detached { UpdateChecker.homebrew() }.value
        updates = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        lastCheck = Date()
        phase = .results
    }

    /// Count only (for Smart Care), without changing this module's screen.
    nonisolated static func count() async -> Int {
        let apps = AppCatalog.load().filter { $0.isAppStore || $0.feedURL != nil }
        return await withTaskGroup(of: Bool.self) { group in
            for app in apps { group.addTask { await UpdateChecker.check(app) != nil } }
            var n = 0
            for await ok in group where ok { n += 1 }
            return n
        }
    }

    func update(_ u: AppUpdate) async {
        switch u.source {
        case .appStore:
            if let s = u.storeURL { NSWorkspace.shared.open(s) }
        case .developer:
            // Opening the app lets its built-in updater (Sparkle) install the update.
            if let a = u.appURL { NSWorkspace.shared.openApplication(at: a, configuration: .init(), completionHandler: nil) }
        case .homebrew:
            guard let name = u.brewName, let i = updates.firstIndex(where: { $0.id == u.id }) else { return }
            updates[i].updating = true
            let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "brew"
            let ok = await Task.detached { Shell.sh("\(brew) upgrade \(name)").ok }.value
            if ok { updates.removeAll { $0.id == u.id } } else if let j = updates.firstIndex(where: { $0.id == u.id }) { updates[j].updating = false }
        }
    }
}

struct UpdaterView: View {
    @ObservedObject var model: UpdaterModel

    var body: some View {
        switch model.phase {
        case .idle, .done, .working:
            ModuleHero(module: .updater, buttonTitle: "Check") { Task { await model.scan() } } extra: {
                Text("Asks the App Store, each app's own update feed and Homebrew for newer versions.")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
            }
        case .scanning:
            ScanningView(module: .updater, status: "Checking for updates…", detail: "\(model.checked) of \(model.total) apps",
                         progress: model.total > 0 ? Double(model.checked) / Double(model.total) : nil)
        case .results:
            ResultsScaffold(module: .updater,
                            title: model.updates.isEmpty ? "Everything's up to date" : "\(model.updates.count) update\(model.updates.count == 1 ? "" : "s") available",
                            subtitle: "Checked \(relativeDate(model.lastCheck))", actionTitle: "Check",
                            onBack: { model.phase = .idle }, onAction: { Task { await model.scan() } }) {
                GlassPanel(padding: 6) {
                    if model.updates.isEmpty {
                        EmptyResult(icon: "checkmark.circle.fill", title: "Up to date", detail: "No newer versions were found.")
                    } else {
                        List(model.updates) { u in
                            HStack(spacing: 12) {
                                if let icon = u.icon { Image(nsImage: icon).resizable().frame(width: 32, height: 32) }
                                else { Image(systemName: "mug.fill").font(.title2).frame(width: 32) }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(u.name)
                                    Text("\(u.current) → \(u.latest) · \(u.source.rawValue)").font(.caption).foregroundStyle(.white.opacity(0.55))
                                }
                                Spacer()
                                if let d = u.downloadURL {
                                    Button { NSWorkspace.shared.open(d) } label: { Image(systemName: "arrow.down.circle") }
                                        .buttonStyle(.borderless).help("Download the new version directly")
                                }
                                if u.updating { ProgressView().controlSize(.small) }
                                Button(u.source == .appStore ? "Open in App Store" : u.source == .homebrew ? "Upgrade" : "Update") {
                                    Task { await model.update(u) }
                                }
                                .buttonStyle(GlassButtonStyle(compact: true)).disabled(u.updating)
                            }
                            .padding(.vertical, 3)
                        }
                        .scrollContentBackground(.hidden).listStyle(.plain)
                    }
                }
            }
        }
    }
}
