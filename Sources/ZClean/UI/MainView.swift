import ServiceManagement
import SwiftUI

struct MainView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 230)
            ZStack {
                LinearGradient(colors: app.module.background, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
                RadialGradient(colors: [app.module.colors[0].opacity(0.25), .clear], center: .topTrailing, startRadius: 0, endRadius: 600)
                    .ignoresSafeArea()
                moduleView
                    .id(app.module)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.35), value: app.module)
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.refreshPermissions()
        }
    }

    @ViewBuilder private var moduleView: some View {
        switch app.module {
        case .smartCare: SmartCareView(model: app.smartCare)
        case .systemJunk: SystemJunkView(model: app.junk)
        case .trash: TrashView(model: app.trash)
        case .malware: MalwareView(model: app.malware)
        case .privacy: PrivacyView(model: app.privacy)
        case .optimization: OptimizationView(model: app.optimization)
        case .maintenance: MaintenanceView(model: app.maintenance)
        case .uninstaller: UninstallerView(model: app.apps)
        case .updater: UpdaterView(model: app.updater)
        case .spaceLens: SpaceLensView(model: app.spaceLens)
        case .largeFiles: LargeFilesView(model: app.largeFiles)
        case .duplicates: DuplicatesView(model: app.duplicates)
        case .shredder: ShredderView(model: app.shredder)
        }
    }
}

private struct Sidebar: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openSettings) private var openSettings
    @State private var disk = FileOps.diskSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(LinearGradient(colors: Module.smartCare.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("ZClean").font(.system(size: 20, weight: .bold, design: .rounded))
            }
            .padding(.horizontal, 18)
            .padding(.top, 38)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(ModuleGroup.allCases, id: \.self) { group in
                        if !group.rawValue.isEmpty {
                            Text(group.rawValue.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.horizontal, 18)
                                .padding(.top, 14)
                                .padding(.bottom, 4)
                        }
                        ForEach(group.modules) { m in
                            SidebarItem(module: m, selected: app.module == m) { app.module = m }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "internaldrive")
                    Text("Macintosh HD").font(.caption.bold())
                    Spacer()
                    Button { openSettings() } label: { Image(systemName: "gearshape") }.buttonStyle(.borderless).help("Settings")
                }
                SizeBar(fraction: 1 - Double(disk.free) / Double(max(disk.total, 1)), colors: Module.smartCare.colors)
                Text("\(formatBytes(disk.free)) free of \(formatBytes(disk.total))").font(.caption2).foregroundStyle(.white.opacity(0.5))
                if !app.hasFullDiskAccess {
                    Button { Permissions.openFullDiskAccessSettings() } label: {
                        Label("Grant Full Disk Access", systemImage: "lock.shield").font(.caption)
                    }
                    .buttonStyle(.borderless).foregroundStyle(.yellow)
                }
            }
            .padding(16)
        }
        .background(.black.opacity(0.35))
        .background(.ultraThinMaterial)
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in disk = FileOps.diskSpace }
    }
}

private struct SidebarItem: View {
    let module: Module
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: module.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(LinearGradient(colors: selected ? module.colors : [.white.opacity(0.08), .white.opacity(0.04)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                Text(module.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? .white.opacity(0.12) : (hover ? .white.opacity(0.06) : .clear), in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Settings

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ExclusionsSettings().tabItem { Label("Exclusions", systemImage: "nosign") }
            PermissionsSettings().tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 520, height: 380)
        .padding()
    }
}

private struct GeneralSettings: View {
    @AppStorage("junkToTrash") private var junkToTrash = false
    @AppStorage("showMenuBar") private var showMenuBar = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                }
            Toggle("Show system monitor in the menu bar", isOn: $showMenuBar)
            Toggle("Move junk to the Trash instead of deleting it", isOn: $junkToTrash)
            Text("By default caches and logs are deleted right away (apps rebuild them). Your own files, such as apps, duplicates, large files and installers, always go to the Trash.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct ExclusionsSettings: View {
    @State private var paths: [String] = UserDefaults.standard.stringArray(forKey: "exclusions") ?? []

    var body: some View {
        VStack(alignment: .leading) {
            Text("ZClean never scans or removes anything in these locations.").font(.callout)
            List {
                ForEach(paths, id: \.self) { p in
                    HStack {
                        Image(systemName: "folder")
                        Text(p.replacingOccurrences(of: FileOps.home.path, with: "~"))
                    }
                }
                .onDelete { paths.remove(atOffsets: $0); save() }
            }
            HStack {
                Button("Add…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = true
                    if panel.runModal() == .OK {
                        paths += panel.urls.map { $0.standardizedFileURL.path }.filter { !paths.contains($0) }
                        save()
                    }
                }
                Button("Remove Last") { if !paths.isEmpty { paths.removeLast(); save() } }.disabled(paths.isEmpty)
            }
        }
        .padding()
    }

    private func save() { UserDefaults.standard.set(paths, forKey: "exclusions") }
}

private struct PermissionsSettings: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Form {
            LabeledContent("Full Disk Access") {
                HStack {
                    Image(systemName: app.hasFullDiskAccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(app.hasFullDiskAccess ? .green : .orange)
                    Text(app.hasFullDiskAccess ? "Granted" : "Not granted")
                }
            }
            Text("Full Disk Access lets ZClean look inside Mail, Safari, the Trash and app containers. Turn on ZClean in System Settings › Privacy & Security › Full Disk Access, then reopen ZClean.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Open System Settings") { Permissions.openFullDiskAccessSettings() }
                Button("Check Again") { app.refreshPermissions() }
            }
        }
        .formStyle(.grouped)
    }
}
