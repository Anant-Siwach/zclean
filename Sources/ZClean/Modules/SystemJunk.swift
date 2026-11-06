import AppKit
import SwiftUI

enum Phase: Equatable { case idle, scanning, results, working, done }

struct JunkItem: Identifiable, Hashable {
    let url: URL
    var name: String
    var size: Int64
    var selected: Bool
    var note: String?
    var id: URL { url }
}

struct JunkCategory: Identifiable {
    let id: String
    let title: String
    let icon: String
    let detail: String
    var items: [JunkItem]
    /// Deletion is only allowed strictly inside these folders.
    let roots: [URL]
    /// User files go to the Trash; regenerable junk is deleted.
    var toTrash = false

    var size: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedSize: Int64 { items.filter(\.selected).reduce(0) { $0 + $1.size } }
}

/// Finds regenerable junk. Read-only.
enum JunkScanner {
    static let devCacheNames: Set<String> = ["Homebrew", "pip", "Yarn", "CocoaPods", "go-build", "pnpm", "deno", "JetBrains"]
    /// Caches that hold state macOS or iCloud expects to keep.
    static let protectedCaches: Set<String> = [
        "com.apple.HomeKit", "CloudKit", "com.apple.akd", "FamilyCircle", "com.apple.ap.adprivacyd",
        "com.apple.containermanagerd", "com.apple.findmy.fmipcore", "com.apple.iCloudHelper", "com.apple.bird",
        "com.apple.amsengagementd", "com.apple.Safari.SafeBrowsing", "ZClean", "com.zclean.app",
    ]

    /// Cache folders whose names don't match their app's bundle ID.
    static let cacheOwners: [String: String] = [
        "Google": "com.google.", "Firefox": "org.mozilla.", "BraveSoftware": "com.brave.", "Microsoft Edge": "com.microsoft.edgemac",
        "Arc": "company.thebrowser.", "Vivaldi": "com.vivaldi.", "JetBrains": "com.jetbrains.", "Mozilla": "org.mozilla.",
        "Slack": "com.tinyspeck.", "Discord": "com.hnc.Discord", "Code": "com.microsoft.VSCode", "Cursor": "com.todesktop.",
    ]
    /// Things stored in Caches that don't come back on their own.
    static let keepByDefault: [String: String] = [
        "ms-playwright": "Playwright's browsers. Reinstall with “npx playwright install” after removing.",
        "Gradle cache": "Gradle re-downloads every dependency on the next build.",
    ]

    static func scan(fullDiskAccess: Bool, progress: @escaping (String) -> Void) -> [JunkCategory] {
        let home = FileOps.home
        let lib = home.appendingPathComponent("Library")
        let runningApps = NSWorkspace.shared.runningApplications
        let running = Set(runningApps.compactMap(\.bundleIdentifier))
        let runningNames = Set(runningApps.compactMap(\.localizedName))
        func isRunning(_ folder: String) -> Bool {
            if running.contains(folder) || runningNames.contains(folder) { return true }
            if let prefix = cacheOwners[folder] { return running.contains { $0.hasPrefix(prefix) } }
            return false
        }
        var cats: [JunkCategory] = []

        func items(in dir: URL, skip: Set<String> = [], olderThan days: Double? = nil, selected: Bool = true,
                   note: ((URL) -> String?)? = nil, filter: ((URL) -> Bool)? = nil) -> [JunkItem] {
            FileOps.children(of: dir).compactMap { url in
                let name = url.lastPathComponent
                guard !skip.contains(name), name != ".DS_Store", !FileOps.isExcluded(url) else { return nil }
                if let filter, !filter(url) { return nil }
                if let days, let mod = FileOps.modificationDate(url), Date().timeIntervalSince(mod) < days * 86400 { return nil }
                progress(FileOps.displayPath(url))
                let size = FileOps.allocatedSize(of: url)
                guard size > 0 else { return nil }
                let n = note?(url)
                return JunkItem(url: url, name: name, size: size, selected: selected && n == nil, note: n)
            }
        }

        // User caches (+ sandboxed app caches when we can see them).
        let caches = lib.appendingPathComponent("Caches")
        var cacheItems = items(in: caches, skip: devCacheNames.union(protectedCaches), note: { url in
            let name = url.lastPathComponent
            if let keep = keepByDefault[name] { return keep }
            return isRunning(name) ? "App is running. Quit it first to clean this safely." : nil
        })
        var cacheRoots = [caches]
        if fullDiskAccess {
            let containers = lib.appendingPathComponent("Containers")
            for c in FileOps.children(of: containers) where !c.lastPathComponent.hasPrefix("com.apple.") {
                let dir = c.appendingPathComponent("Data/Library/Caches")
                guard FileOps.exists(dir), !FileOps.isExcluded(dir) else { continue }
                progress(FileOps.displayPath(dir))
                let kids = FileOps.children(of: dir)
                let size = kids.reduce(Int64(0)) { $0 + FileOps.allocatedSize(of: $1) }
                guard size > 1_000_000 else { continue }
                let isRunning = running.contains(c.lastPathComponent)
                for k in kids {
                    let s = FileOps.allocatedSize(of: k)
                    guard s > 0 else { continue }
                    cacheItems.append(JunkItem(url: k, name: "\(appName(for: c.lastPathComponent)) › \(k.lastPathComponent)", size: s,
                                               selected: !isRunning, note: isRunning ? "App is running." : nil))
                }
                cacheRoots.append(dir)
            }
        }
        cats.append(JunkCategory(id: "caches", title: "User Cache Files", icon: "archivebox.fill",
                                 detail: "Temporary data apps store to load faster. Apps rebuild it as needed.",
                                 items: cacheItems.sorted { $0.size > $1.size }, roots: cacheRoots))

        let logs = lib.appendingPathComponent("Logs")
        cats.append(JunkCategory(id: "logs", title: "User Log Files", icon: "doc.text.fill",
                                 detail: "Activity and crash logs written by apps and macOS.",
                                 items: items(in: logs).sorted { $0.size > $1.size }, roots: [logs]))

        // Xcode
        let dev = lib.appendingPathComponent("Developer")
        var xcode: [JunkItem] = []
        var xcodeRoots: [URL] = []
        for (path, selected) in [("Xcode/DerivedData", true), ("Xcode/iOS DeviceSupport", true), ("Xcode/watchOS DeviceSupport", true),
                                 ("Xcode/tvOS DeviceSupport", true), ("CoreSimulator/Caches", true), ("Xcode/Archives", false)] {
            let dir = dev.appendingPathComponent(path)
            guard FileOps.exists(dir) else { continue }
            xcodeRoots.append(dir)
            xcode += items(in: dir, selected: selected).map { var i = $0; i.name = "\(path.components(separatedBy: "/").last!) › \(i.name)"; return i }
        }
        if !xcode.isEmpty {
            cats.append(JunkCategory(id: "xcode", title: "Xcode Junk", icon: "hammer.fill",
                                     detail: "Build data, device support files and simulator caches. Archives are left unchecked.",
                                     items: xcode.sorted { $0.size > $1.size }, roots: xcodeRoots))
        }

        // Package-manager caches.
        let devDirs: [(String, URL)] = [
            ("npm", home.appendingPathComponent(".npm/_cacache")),
            ("Yarn", caches.appendingPathComponent("Yarn")),
            ("pnpm", caches.appendingPathComponent("pnpm")),
            ("pip", caches.appendingPathComponent("pip")),
            ("Homebrew", caches.appendingPathComponent("Homebrew")),
            ("CocoaPods", caches.appendingPathComponent("CocoaPods")),
            ("Go build", caches.appendingPathComponent("go-build")),
            ("Deno", caches.appendingPathComponent("deno")),
            ("JetBrains", caches.appendingPathComponent("JetBrains")),
            ("Cargo registry", home.appendingPathComponent(".cargo/registry/cache")),
            ("Gradle", home.appendingPathComponent(".gradle/caches")),
            ("Bun", home.appendingPathComponent(".bun/install/cache")),
        ]
        var devItems: [JunkItem] = []
        for (name, url) in devDirs where FileOps.exists(url) && !FileOps.isExcluded(url) {
            progress(FileOps.displayPath(url))
            let size = FileOps.allocatedSize(of: url)
            let label = "\(name) cache"
            let note = keepByDefault[label] ?? (isRunning(name) ? "App is running." : nil)
            if size > 0 { devItems.append(JunkItem(url: url, name: label, size: size, selected: note == nil, note: note)) }
        }
        if !devItems.isEmpty {
            cats.append(JunkCategory(id: "dev", title: "Developer Caches", icon: "terminal.fill",
                                     detail: "Download caches from package managers. They're refetched when needed.",
                                     items: devItems.sorted { $0.size > $1.size },
                                     roots: devItems.map { $0.url.deletingLastPathComponent() }))
        }

        let tmp = FileManager.default.temporaryDirectory
        cats.append(JunkCategory(id: "temp", title: "Temporary Files", icon: "clock.arrow.circlepath",
                                 detail: "Temporary files older than three days.",
                                 items: items(in: tmp, olderThan: 3).sorted { $0.size > $1.size }, roots: [tmp]))

        let downloads = home.appendingPathComponent("Downloads")
        let installerExts: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso"]
        cats.append(JunkCategory(id: "installers", title: "Old Installers", icon: "shippingbox.fill",
                                 detail: "Disk images and installer packages in Downloads older than a week. These go to the Trash.",
                                 items: items(in: downloads, olderThan: 7, selected: false,
                                              filter: { installerExts.contains($0.pathExtension.lowercased()) }).sorted { $0.size > $1.size },
                                 roots: [downloads], toTrash: true))

        if fullDiskAccess {
            let mail = lib.appendingPathComponent("Containers/com.apple.mail/Data/Library/Mail Downloads")
            if FileOps.exists(mail) {
                cats.append(JunkCategory(id: "mail", title: "Mail Attachments", icon: "paperclip",
                                         detail: "Local copies of attachments you opened in Mail. They stay in your mailbox.",
                                         items: items(in: mail).sorted { $0.size > $1.size }, roots: [mail]))
            }
            let backups = lib.appendingPathComponent("Application Support/MobileSync/Backup")
            if FileOps.exists(backups) {
                cats.append(JunkCategory(id: "backups", title: "iOS Device Backups", icon: "iphone",
                                         detail: "Old iPhone and iPad backups. Unchecked by default; these go to the Trash.",
                                         items: items(in: backups, selected: false).sorted { $0.size > $1.size },
                                         roots: [backups], toTrash: true))
            }
        }
        return cats.filter { !$0.items.isEmpty }
    }

    static func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }
}

@MainActor
final class JunkModel: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var categories: [JunkCategory] = []
    @Published var selectedCategory: String?
    @Published var currentPath = ""
    @Published var freed: Int64 = 0
    @Published var failures = 0

    var selectedSize: Int64 { categories.reduce(0) { $0 + $1.selectedSize } }
    var totalSize: Int64 { categories.reduce(0) { $0 + $1.size } }

    func scan() async {
        phase = .scanning
        let fda = Permissions.hasFullDiskAccess
        let throttle = Throttle()
        let cats = await Task.detached(priority: .userInitiated) {
            JunkScanner.scan(fullDiskAccess: fda) { path in
                throttle.run { Task { @MainActor in self.currentPath = path } }
            }
        }.value
        categories = cats
        selectedCategory = cats.first?.id
        phase = .results
    }

    func clean() async {
        phase = .working
        let cats = categories
        let result = await Task.detached(priority: .userInitiated) { () -> FileOps.Result in
            var total = FileOps.Result()
            for cat in cats {
                let picked = cat.items.filter(\.selected).map { ($0.url, $0.size) }
                guard !picked.isEmpty else { continue }
                let r = cat.toTrash ? FileOps.trash(picked, roots: cat.roots) : FileOps.delete(picked, roots: cat.roots)
                total.freed += r.freed
                total.removed += r.removed
                total.failed += r.failed
            }
            return total
        }.value
        freed = result.freed
        failures = result.failed.count
        let removed = Set(result.removed)
        for i in categories.indices { categories[i].items.removeAll { removed.contains($0.url) } }
        categories.removeAll { $0.items.isEmpty }
        phase = .done
    }

    func setCategory(_ id: String, selected: Bool) {
        guard let i = categories.firstIndex(where: { $0.id == id }) else { return }
        for j in categories[i].items.indices { categories[i].items[j].selected = selected }
    }

    func reset() { phase = .idle; categories = [] }
}

/// Limits how often a closure runs (used for progress updates from scanners).
final class Throttle: @unchecked Sendable {
    private var last = Date.distantPast
    private let lock = NSLock()
    private let interval: TimeInterval
    init(_ interval: TimeInterval = 0.08) { self.interval = interval }
    func run(_ f: () -> Void) {
        lock.lock()
        let now = Date()
        let go = now.timeIntervalSince(last) > interval
        if go { last = now }
        lock.unlock()
        if go { f() }
    }
}

struct SystemJunkView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: JunkModel

    var body: some View {
        switch model.phase {
        case .idle:
            ModuleHero(module: .systemJunk) { Task { await model.scan() } } extra: {
                FullDiskAccessBanner().frame(maxWidth: 520)
            }
        case .scanning:
            ScanningView(module: .systemJunk, status: "Looking for junk…", detail: model.currentPath)
        case .working:
            ScanningView(module: .systemJunk, status: "Cleaning…")
        case .done:
            DoneView(module: .systemJunk, title: "\(formatBytes(model.freed)) cleaned",
                     detail: "Your Mac has a little more room to breathe.", failures: model.failures) { model.reset() }
        case .results:
            ResultsScaffold(module: .systemJunk, title: "\(formatBytes(model.totalSize)) of junk found",
                            subtitle: "\(formatBytes(model.selectedSize)) selected",
                            actionTitle: "Clean", actionEnabled: model.selectedSize > 0,
                            onBack: { model.reset() }, onAction: { Task { await model.clean() } }) {
                if model.categories.isEmpty {
                    EmptyResult(icon: "checkmark.seal.fill", title: "Squeaky clean", detail: "No junk found.")
                } else {
                    JunkResults(model: model)
                }
            }
        }
    }
}

private struct JunkResults: View {
    @ObservedObject var model: JunkModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            GlassPanel(padding: 8) {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.categories) { cat in
                            CategoryRow(icon: cat.icon, title: cat.title, size: formatBytes(cat.selectedSize),
                                        selected: model.selectedCategory == cat.id,
                                        checked: Binding(get: { cat.selectedSize > 0 },
                                                         set: { model.setCategory(cat.id, selected: $0) }))
                                .onTapGesture { model.selectedCategory = cat.id }
                        }
                    }
                }
            }
            .frame(width: 280)

            GlassPanel {
                if let i = model.categories.firstIndex(where: { $0.id == model.selectedCategory }) {
                    let cat = model.categories[i]
                    VStack(alignment: .leading, spacing: 8) {
                        Text(cat.title).font(.headline)
                        Text(cat.detail).font(.caption).foregroundStyle(.white.opacity(0.6))
                        Divider().overlay(.white.opacity(0.1))
                        List {
                            ForEach(cat.items.indices, id: \.self) { j in
                                let item = cat.items[j]
                                CheckRow(isOn: $model.categories[i].items[j].selected, title: item.name,
                                         subtitle: FileOps.displayPath(item.url), trailing: formatBytes(item.size),
                                         warning: item.note) {
                                    FileIcon(url: item.url)
                                }
                                .contextMenu { Button("Show in Finder") { FileOps.reveal(item.url) } }
                            }
                        }
                        .scrollContentBackground(.hidden)
                        .listStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Trash

@MainActor
final class TrashModel: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var size: Int64 = 0
    @Published var count = 0
    @Published var canSeeTrash = true
    @Published var freed: Int64 = 0
    @Published var error: String?

    nonisolated static let trashURL = FileOps.homePath(".Trash")

    func scan() async {
        phase = .scanning
        let (size, count, visible) = await Task.detached {
            guard let kids = try? FileManager.default.contentsOfDirectory(at: Self.trashURL, includingPropertiesForKeys: nil) else {
                return (Int64(0), 0, false)
            }
            let items = kids.filter { $0.lastPathComponent != ".DS_Store" }
            return (items.reduce(Int64(0)) { $0 + FileOps.allocatedSize(of: $1) }, items.count, true)
        }.value
        self.size = size
        self.count = count
        canSeeTrash = visible
        phase = .results
    }

    /// Size of the Trash without changing the screen (for Smart Care).
    nonisolated static func measure() -> Int64 {
        let kids = (try? FileManager.default.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil)) ?? []
        return kids.reduce(Int64(0)) { $0 + FileOps.allocatedSize(of: $1) }
    }

    func empty() async {
        phase = .working
        let visible = canSeeTrash
        let before = size
        let ok = await Task.detached { () -> Bool in
            if visible {
                for k in (try? FileManager.default.contentsOfDirectory(at: Self.trashURL, includingPropertiesForKeys: nil)) ?? [] {
                    if FileOps.isInside(k, roots: [Self.trashURL]) { try? FileManager.default.removeItem(at: k) }
                }
                return true
            }
            // Without Full Disk Access, ask Finder (macOS will ask to allow controlling Finder once).
            return Shell.run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"]).ok
        }.value
        freed = before
        error = ok ? nil : "Finder couldn't empty the Trash."
        phase = .done
    }
}

struct TrashView: View {
    @ObservedObject var model: TrashModel

    var body: some View {
        switch model.phase {
        case .idle:
            ModuleHero(module: .trash) { Task { await model.scan() } }
        case .scanning, .working:
            ScanningView(module: .trash, status: model.phase == .scanning ? "Measuring the Trash…" : "Emptying the Trash…")
        case .done:
            DoneView(module: .trash, title: model.error ?? (model.freed > 0 ? "\(formatBytes(model.freed)) freed" : "Trash emptied"),
                     detail: "The Trash is empty.") { model.phase = .idle }
        case .results:
            ModuleHero(module: .trash, buttonTitle: "Empty",
                       subtitle: model.canSeeTrash
                           ? (model.count == 0 ? "Your Trash is already empty." : "\(model.count) item\(model.count == 1 ? "" : "s") · \(formatBytes(model.size)). Emptying can't be undone.")
                           : "ZClean can't see inside the Trash without Full Disk Access, but Finder can still empty it.") {
                Task { await model.empty() }
            } extra: {
                FullDiskAccessBanner(reason: "Grant Full Disk Access to see what's in the Trash.").frame(maxWidth: 520)
            }
        }
    }
}
