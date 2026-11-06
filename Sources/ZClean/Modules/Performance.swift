import AppKit
import SwiftUI

// MARK: - Optimization

struct ProcessInfoRow: Identifiable, Hashable {
    let pid: Int32
    let name: String
    let cpu: Double
    let memory: Int64
    var id: Int32 { pid }
    var app: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }
}

enum ProcessList {
    static func top(limit: Int = 15) -> [ProcessInfoRow] {
        let out = Shell.run("/bin/ps", ["-Aceo", "pid=,pcpu=,rss=,comm="]).text
        let myPID = ProcessInfo.processInfo.processIdentifier
        return out.split(separator: "\n").compactMap { line -> ProcessInfoRow? in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let cpu = Double(parts[1]), let rss = Int64(parts[2]), pid != myPID else { return nil }
            return ProcessInfoRow(pid: pid, name: String(parts[3]), cpu: cpu, memory: rss * 1024)
        }
        .sorted { ($0.cpu * 50_000_000 + Double($0.memory)) > ($1.cpu * 50_000_000 + Double($1.memory)) }
        .prefix(limit).map { $0 }
    }
}

@MainActor
final class OptimizationModel: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var items: [LaunchItem] = []
    @Published var processes: [ProcessInfoRow] = []
    @Published var tab = 0
    @Published var busy: URL?
    private var timer: Timer?

    func scan() async {
        phase = .scanning
        async let launch = Task.detached { LaunchItems.scan() }.value
        async let procs = Task.detached { ProcessList.top() }.value
        items = await launch
        processes = await procs
        phase = .results
        startRefreshing()
    }

    func startRefreshing() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .results, self.tab == 1 else { return }
                self.processes = await Task.detached { ProcessList.top() }.value
            }
        }
    }

    func toggle(_ item: LaunchItem) async {
        busy = item.id
        let target = !item.disabled
        let ok = await Task.detached { LaunchItems.setEnabled(item, !target) }.value
        if ok, let i = items.firstIndex(of: item) { items[i].disabled = target }
        busy = nil
    }

    func remove(_ item: LaunchItem) async {
        busy = item.id
        if await Task.detached(operation: { LaunchItems.remove(item) }).value {
            items.removeAll { $0.id == item.id }
        }
        busy = nil
    }

    func quit(_ p: ProcessInfoRow, force: Bool = false) {
        if let app = p.app {
            _ = force ? app.forceTerminate() : app.terminate()
        } else {
            kill(p.pid, force ? SIGKILL : SIGTERM)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            Task { self.processes = await Task.detached { ProcessList.top() }.value }
        }
    }
}

struct OptimizationView: View {
    @ObservedObject var model: OptimizationModel

    var body: some View {
        switch model.phase {
        case .idle, .done:
            ModuleHero(module: .optimization, buttonTitle: "View") { Task { await model.scan() } }
        case .scanning, .working:
            ScanningView(module: .optimization, status: "Gathering startup items…")
        case .results:
            ResultsLayout(model: model)
        }
    }
}

private struct ResultsLayout: View {
    @ObservedObject var model: OptimizationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                GlowIcon(icon: Module.optimization.icon, colors: Module.optimization.colors, size: 46).frame(width: 60, height: 60)
                VStack(alignment: .leading) {
                    Text("Optimization").font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("\(model.items.filter { !$0.disabled }.count) startup items active").foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Picker("", selection: $model.tab) {
                    Text("Startup Items").tag(0)
                    Text("Heavy Consumers").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                Button { Task { await model.scan() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(GlassButtonStyle(compact: true))
            }
            if model.tab == 0 { startupList } else { processList }
        }
        .padding(24)
    }

    private var startupList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Background agents and daemons that launch automatically. Turning one off is reversible.")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button("Login Items in System Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                }
                .buttonStyle(GlassButtonStyle(compact: true))
            }
            GlassPanel(padding: 6) {
                List(model.items) { item in
                    HStack(spacing: 10) {
                        if let program = item.program, let app = program.range(of: ".app/") {
                            FileIcon(url: URL(fileURLWithPath: String(program[..<app.lowerBound]) + ".app"), size: 26)
                        } else {
                            Image(systemName: "gearshape.2.fill").frame(width: 26).foregroundStyle(.white.opacity(0.6))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.displayName).lineLimit(1)
                            Text("\(item.domain.rawValue) · \(item.signature.summary)\(item.programExists ? "" : " · program missing")")
                                .font(.caption).foregroundStyle(.white.opacity(0.5))
                        }
                        Spacer()
                        if model.busy == item.id { ProgressView().controlSize(.small) }
                        Toggle("", isOn: Binding(get: { !item.disabled }, set: { _ in Task { await model.toggle(item) } }))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                            .help(item.domain == .systemDaemon ? "Needs your administrator password" : "")
                        Menu {
                            Button("Show in Finder") { FileOps.reveal(item.plist) }
                            if let p = item.program { Button("Show Program") { FileOps.reveal(URL(fileURLWithPath: p)) } }
                            Divider()
                            Button("Remove…", role: .destructive) { Task { await model.remove(item) } }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).frame(width: 30)
                    }
                    .padding(.vertical, 3)
                }
                .scrollContentBackground(.hidden).listStyle(.plain)
            }
        }
    }

    private var processList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Apps and processes using the most CPU and memory right now. Updates every 3 seconds.")
                .font(.caption).foregroundStyle(.white.opacity(0.6))
            GlassPanel(padding: 6) {
                List(model.processes) { p in
                    HStack(spacing: 10) {
                        if let icon = p.app?.icon { Image(nsImage: icon).resizable().frame(width: 26, height: 26) }
                        else { Image(systemName: "terminal").frame(width: 26).foregroundStyle(.white.opacity(0.6)) }
                        Text(p.app?.localizedName ?? p.name).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.1f%% CPU", p.cpu)).font(.caption.monospacedDigit()).frame(width: 80, alignment: .trailing)
                        Text(formatBytes(p.memory)).font(.caption.monospacedDigit()).frame(width: 80, alignment: .trailing)
                        Button("Quit") { model.quit(p) }.buttonStyle(GlassButtonStyle(compact: true))
                            .contextMenu { Button("Force Quit") { model.quit(p, force: true) } }
                    }
                    .padding(.vertical, 2)
                }
                .scrollContentBackground(.hidden).listStyle(.plain)
            }
        }
    }
}

// MARK: - Maintenance

struct MaintenanceTask: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let admin: Bool
    let command: String
    var selected: Bool
    var state: State = .idle
    enum State: Equatable { case idle, running, done, failed(String) }
}

@MainActor
final class MaintenanceModel: ObservableObject {
    @Published var tasks: [MaintenanceTask] = MaintenanceModel.defaultTasks()
    @Published var running = false
    @AppStorage("lastMaintenance") var lastRun: Double = 0

    static func defaultTasks() -> [MaintenanceTask] {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        let mailIndex = "for d in ~/Library/Mail/V*/MailData; do [ -f \"$d/Envelope Index\" ] && /usr/bin/sqlite3 \"$d/Envelope Index\" vacuum; done"
        return [
            .init(id: "ram", title: "Free up RAM", detail: "Clears inactive memory so apps get more room.", icon: "memorychip", admin: true,
                  command: "/usr/sbin/purge", selected: true),
            .init(id: "dns", title: "Flush DNS cache", detail: "Fixes websites that won't load after network changes.", icon: "network", admin: true,
                  command: "dscacheutil -flushcache; killall -HUP mDNSResponder", selected: true),
            .init(id: "ql", title: "Clear Quick Look cache", detail: "Fixes stale or broken file previews.", icon: "eye", admin: false,
                  command: "qlmanage -r cache", selected: true),
            .init(id: "ls", title: "Rebuild Launch Services", detail: "Fixes duplicate entries in “Open With” and wrong default apps.",
                  icon: "square.stack.3d.up", admin: false,
                  command: "\(lsregister) -kill -r -domain local -domain system -domain user", selected: false),
            .init(id: "spotlight", title: "Reindex Spotlight", detail: "Rebuilds search when Spotlight misses files. Takes a while to finish in the background.",
                  icon: "magnifyingglass", admin: true, command: "mdutil -E /", selected: false),
            .init(id: "fonts", title: "Clear font caches", detail: "Fixes garbled or missing fonts.", icon: "textformat", admin: false,
                  command: "atsutil databases -removeUser", selected: false),
            .init(id: "snapshots", title: "Thin Time Machine snapshots", detail: "Frees space held by local backup snapshots.",
                  icon: "clock.arrow.circlepath", admin: true, command: "tmutil thinlocalsnapshots / 999999999999 4", selected: false),
            .init(id: "mail", title: "Speed up Mail", detail: "Compacts Mail's message index. Quit Mail first. Needs Full Disk Access.",
                  icon: "envelope", admin: false, command: mailIndex, selected: false),
            .init(id: "perms", title: "Repair home folder permissions", detail: "Resets ownership in your home folder. Can take several minutes.",
                  icon: "lock.rotation", admin: false, command: "diskutil resetUserPermissions / $(id -u)", selected: false),
            .init(id: "finder", title: "Restart Finder & Dock", detail: "Fixes a frozen Finder or Dock.", icon: "dock.rectangle", admin: false,
                  command: "killall Finder; killall Dock", selected: false),
        ]
    }

    func run() async {
        running = true
        for i in tasks.indices { if tasks[i].selected { tasks[i].state = .idle } }
        for i in tasks.indices where tasks[i].selected {
            if tasks[i].id == "mail", !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty {
                tasks[i].state = .failed("Quit Mail first")
                continue
            }
            tasks[i].state = .running
            let t = tasks[i]
            let out = await Task.detached { t.admin ? Shell.admin(t.command) : Shell.sh(t.command) }.value
            tasks[i].state = out.ok ? .done : .failed(out.text.split(separator: "\n").last.map(String.init) ?? "Failed")
        }
        lastRun = Date().timeIntervalSince1970
        running = false
    }
}

struct MaintenanceView: View {
    @ObservedObject var model: MaintenanceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                GlowIcon(icon: Module.maintenance.icon, colors: Module.maintenance.colors, size: 46).frame(width: 60, height: 60)
                VStack(alignment: .leading) {
                    Text("Maintenance").font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(model.lastRun == 0 ? "Never run" : "Last run \(relativeDate(Date(timeIntervalSince1970: model.lastRun)))")
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
            }
            GlassPanel(padding: 8) {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach($model.tasks) { $task in
                            HStack(spacing: 12) {
                                Toggle("", isOn: $task.selected).toggleStyle(.checkbox).labelsHidden().disabled(model.running)
                                Image(systemName: task.icon).frame(width: 26).font(.title3).foregroundStyle(.white.opacity(0.85))
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(task.title)
                                        if task.admin {
                                            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.white.opacity(0.5))
                                                .help("Asks for your administrator password")
                                        }
                                    }
                                    Text(task.detail).font(.caption).foregroundStyle(.white.opacity(0.55))
                                }
                                Spacer()
                                switch task.state {
                                case .idle: EmptyView()
                                case .running: ProgressView().controlSize(.small)
                                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                case .failed(let msg):
                                    Label(msg, systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(.orange).lineLimit(1).frame(maxWidth: 200)
                                }
                            }
                            .padding(8)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                BigButton(title: model.running ? "…" : "Run", colors: Module.maintenance.colors,
                          disabled: model.running || !model.tasks.contains(where: \.selected)) {
                    Task { await model.run() }
                }
                Spacer()
            }
        }
        .padding(24)
    }
}
